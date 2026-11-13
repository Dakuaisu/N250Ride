import Foundation

public struct SessionID: Sendable, Hashable, CustomStringConvertible {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }

    public var description: String { raw.uuidString }
}

/// Increments whenever the route is replaced (new destination, explicit restart),
/// so callbacks from an older route can never update the dashboard.
public struct RouteGeneration: Sendable, Hashable, Comparable {
    public let value: Int

    public init(_ value: Int) {
        self.value = value
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public var next: RouteGeneration { RouteGeneration(value + 1) }
}

public enum NavigationFailure: Sendable, Equatable {
    case locationPermissionDenied
    /// Two-wheeler routing not available here; never silently replaced by car routing.
    case travelModeUnsupported
    case routeUnavailable(String)
    /// Live provider disabled (no key, gate closed, terms not accepted).
    case providerDisabled(String)
}

public enum NavigationState: Sendable, Equatable {
    case idle
    case preview
    case active
    case rerouting
    case noLocation
    case arrived
    case stopped
    case failed(NavigationFailure)

    /// States in which the dashboard may show an arrow.
    var allowsGuidance: Bool {
        self == .active || self == .arrived
    }
}

public struct GuidanceStep: Sendable, Equatable {
    public var maneuver: Maneuver
    public var roundaboutExit: Int?
    /// Direction of the roundabout exit relative to the entry, when the provider knows it.
    public var roundaboutDirection: RoundaboutDirection?
    public var distanceMetres: Int
    /// Ephemeral road/instruction text; never persisted or logged.
    public var roadText: String?
    /// Position of this maneuver in its route, when the source knows it. Tells two
    /// identical turns in a row apart.
    public var sequence: Int?

    public init(maneuver: Maneuver, roundaboutExit: Int? = nil, roundaboutDirection: RoundaboutDirection? = nil,
                distanceMetres: Int, roadText: String? = nil, sequence: Int? = nil) {
        self.maneuver = maneuver
        self.roundaboutExit = roundaboutExit
        self.roundaboutDirection = roundaboutDirection
        self.distanceMetres = distanceMetres
        self.roadText = roadText
        self.sequence = sequence
    }
}

/// Provider-independent navigation observation. SDK enum values never cross the
/// adapter boundary; only these typed fields do.
public struct NavigationSnapshot: Sendable, Equatable {
    public var session: SessionID
    public var generation: RouteGeneration
    /// When this snapshot was published; orders callbacks.
    public var observedAt: MonotonicInstant
    /// When the position behind it was measured. A refresh re-stamps `observedAt`
    /// but never this, so freshness follows the sensor, not the publisher.
    public var measurementAt: MonotonicInstant?
    public var state: NavigationState
    public var step: GuidanceStep?
    public var remainingMetres: Int?
    public var remainingSeconds: Int?
    public var destinationETA: Date?

    public init(
        session: SessionID,
        generation: RouteGeneration,
        observedAt: MonotonicInstant,
        state: NavigationState,
        step: GuidanceStep? = nil,
        remainingMetres: Int? = nil,
        remainingSeconds: Int? = nil,
        destinationETA: Date? = nil,
        measurementAt: MonotonicInstant? = nil
    ) {
        self.session = session
        self.generation = generation
        self.observedAt = observedAt
        self.measurementAt = measurementAt
        self.state = state
        self.step = step
        self.remainingMetres = remainingMetres
        self.remainingSeconds = remainingSeconds
        self.destinationETA = destinationETA
    }
}

public enum SnapshotRejection: Error, Sendable, Equatable {
    case noActiveSession
    case wrongSession
    case obsoleteGeneration
    /// A newer route the owner has not committed yet.
    case uncommittedGeneration
    case outOfOrder
    case sessionAlreadyStopped
}

/// Tracks the current session and decides which observations are admissible.
/// Only the exact committed generation is accepted: older routes and speculative
/// newer ones alike are rejected until the owner commits them. Out-of-order
/// callbacks are rejected, and `stopped` is terminal for a session.
public struct NavigationStateMachine: Sendable {
    public private(set) var session: SessionID?
    public private(set) var generation = RouteGeneration(0)
    public private(set) var latest: NavigationSnapshot?

    public init() {}

    public var state: NavigationState { latest?.state ?? (session == nil ? .idle : .preview) }

    public mutating func begin(_ session: SessionID, generation: RouteGeneration = RouteGeneration(0)) {
        self.session = session
        self.generation = generation
        latest = nil
    }

    /// Starts a replacement route inside the same session; returns its generation.
    public mutating func advanceGeneration() -> RouteGeneration {
        generation = generation.next
        latest = nil
        return generation
    }

    public mutating func end() {
        session = nil
        latest = nil
    }

    public mutating func accept(_ snapshot: NavigationSnapshot) -> Result<NavigationSnapshot, SnapshotRejection> {
        guard let session else { return .failure(.noActiveSession) }
        guard snapshot.session == session else { return .failure(.wrongSession) }
        guard snapshot.generation <= generation else { return .failure(.uncommittedGeneration) }
        guard snapshot.generation == generation else { return .failure(.obsoleteGeneration) }
        if let latest {
            if latest.state == .stopped, snapshot.generation == latest.generation {
                return .failure(.sessionAlreadyStopped)
            }
            if snapshot.generation == latest.generation, snapshot.observedAt < latest.observedAt {
                return .failure(.outOfOrder)
            }
        }
        latest = snapshot
        return .success(snapshot)
    }
}
