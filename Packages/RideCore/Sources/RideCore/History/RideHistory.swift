import Foundation

/// One ride, summarised. Deliberately small: no positions, no track, no route or
/// place text from map providers. The title is generic unless the rider writes one.
public struct RideSummary: Sendable, Equatable, Codable, Identifiable {
    public enum Outcome: String, Sendable, Codable {
        case completed, endedByRider, interrupted

        public var isTerminal: Bool { self != .interrupted }
    }

    public var id: RideID
    public var title: String
    public var startedAt: Date
    public var lastObservedAt: Date
    public var activeSeconds: Double
    /// Estimated from filtered GPS displacement; not odometer-accurate.
    public var estimatedMetres: Double
    public var outcome: Outcome
    public var revision: Int
    /// Consent epoch the ride was recorded under.
    public var consentEpoch: UUID

    public init(id: RideID, title: String = "Ride", startedAt: Date, lastObservedAt: Date, activeSeconds: Double,
                estimatedMetres: Double, outcome: Outcome, revision: Int, consentEpoch: UUID) {
        self.id = id
        self.title = String(title.prefix(RideDestination.maxLabelLength))
        self.startedAt = startedAt
        self.lastObservedAt = lastObservedAt
        self.activeSeconds = activeSeconds
        self.estimatedMetres = estimatedMetres
        self.outcome = outcome
        self.revision = revision
        self.consentEpoch = consentEpoch
    }
}

/// Accumulates active time and an estimated travelled distance from accepted,
/// genuinely new fixes. Keeps only the previous anchor in memory, never a track.
///
/// Distance filter: accuracy <= 25 m; gap <= 120 s; implied speed <= 45 m/s; a step
/// counts only when it exceeds max(5 m, sum of both accuracy radii), otherwise the
/// anchor is kept until movement is distinguishable from noise.
public struct RideAccumulator: Sendable, Equatable {
    public static let maxAccuracy = 25.0
    public static let maxGap: Duration = .seconds(120)
    public static let maxSpeed = 45.0
    public static let minStep = 5.0

    public private(set) var activeSeconds: Double
    public private(set) var estimatedMetres: Double
    private var anchor: (coordinate: Coordinate, accuracy: Double, at: MonotonicInstant)?
    private var segmentStart: MonotonicInstant?
    private var lastSeen: MonotonicInstant?

    public static func == (a: Self, b: Self) -> Bool {
        a.activeSeconds == b.activeSeconds && a.estimatedMetres == b.estimatedMetres
    }

    /// Starts from a committed baseline (zero for a new ride, saved totals on resume).
    public init(baselineSeconds: Double = 0, baselineMetres: Double = 0) {
        activeSeconds = baselineSeconds
        estimatedMetres = baselineMetres
    }

    public mutating func add(_ fix: LocationFix) {
        let at = fix.observedAt
        if let lastSeen {
            guard at > lastSeen else { return }
            let gap = at.duration(since: lastSeen)
            if gap <= Self.maxGap { activeSeconds += gap.seconds }
        }
        lastSeen = at
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxAccuracy else { return }
        guard let anchor else {
            self.anchor = (fix.coordinate, fix.horizontalAccuracy, at)
            return
        }
        let elapsed = at.duration(since: anchor.at)
        guard elapsed <= Self.maxGap else {
            self.anchor = (fix.coordinate, fix.horizontalAccuracy, at)
            return
        }
        let step = fix.coordinate.distance(to: anchor.coordinate)
        guard step > max(Self.minStep, fix.horizontalAccuracy + anchor.accuracy) else { return }
        guard elapsed.seconds > 0, step / elapsed.seconds <= Self.maxSpeed else {
            self.anchor = (fix.coordinate, fix.horizontalAccuracy, at)
            return
        }
        estimatedMetres += step
        self.anchor = (fix.coordinate, fix.horizontalAccuracy, at)
    }

    /// A gap that must not be bridged: stop, leg change, reroute, restart.
    public mutating func breakSegment() {
        anchor = nil
        lastSeen = nil
    }
}

/// Bounded local history and its retention rules.
public enum RideHistoryPolicy {
    public static let maxRides = 100
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// Newest first, one row per ride (highest revision wins), within retention.
    public static func pruned(_ rides: [RideSummary], now: Date) -> [RideSummary] {
        var best: [RideID: RideSummary] = [:]
        for ride in rides where now.timeIntervalSince(ride.lastObservedAt) < maxAge {
            if let existing = best[ride.id], existing.revision >= ride.revision { continue }
            best[ride.id] = ride
        }
        return Array(best.values.sorted { $0.startedAt > $1.startedAt }.prefix(maxRides))
    }
}
