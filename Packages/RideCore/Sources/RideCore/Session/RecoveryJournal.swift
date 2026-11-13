import Foundation

/// A journey that was confirmed and started. Holds intent only: never a route,
/// instructions, a session or a position.
public struct RideIntent: Sendable, Equatable, Codable {
    public var context: RideContext
    public var startedAt: Date
    public var checkpointAt: Date

    public init(context: RideContext, startedAt: Date, checkpointAt: Date) {
        self.context = context
        self.startedAt = startedAt
        self.checkpointAt = checkpointAt
    }
}

/// A start the rider confirmed but that may not have completed (the app can stop
/// between the request and the commit). Never evidence that navigation started.
public struct PendingStart: Sendable, Equatable, Codable {
    public var context: RideContext
    public var reason: String
    public var recordedAt: Date

    public init(context: RideContext, reason: String, recordedAt: Date) {
        self.context = context
        self.reason = reason
        self.recordedAt = recordedAt
    }
}

public struct RecoveryJournal: Sendable, Equatable, Codable {
    public static let schemaVersion = 1

    public var lastCommitted: RideIntent?
    public var pendingStart: PendingStart?

    public init(lastCommitted: RideIntent? = nil, pendingStart: PendingStart? = nil) {
        self.lastCommitted = lastCommitted
        self.pendingStart = pendingStart
    }

    public var isEmpty: Bool { lastCommitted == nil && pendingStart == nil }
}

/// What the app may offer after a restart. Offering never requests a route.
public enum RecoveryOffer: Sendable, Equatable {
    case resume(RideIntent)
    /// A confirmed start of unknown outcome, optionally with the ride before it.
    case unfinishedStart(PendingStart, previous: RideIntent?)

    public var rideID: RideID {
        switch self {
        case .resume(let intent): intent.context.id
        case .unfinishedStart(let pending, _): pending.context.id
        }
    }
}

public enum RecoveryPolicy {
    public static let lifetime: TimeInterval = 24 * 60 * 60
    /// Records dated further ahead than this are treated as corrupt.
    public static let futureTolerance: TimeInterval = 5 * 60

    /// The offer for a journal read at launch, or nil. Expired or future-dated
    /// records and rides already finished (`suppressed`) are never offered.
    public static func offer(for journal: RecoveryJournal, now: Date, suppressed: Set<RideID>) -> RecoveryOffer? {
        let committed = journal.lastCommitted.flatMap { intent in
            isCurrent(intent.checkpointAt, now: now) && !suppressed.contains(intent.context.id) ? intent : nil
        }
        if let pending = journal.pendingStart, isCurrent(pending.recordedAt, now: now),
           !suppressed.contains(pending.context.id) {
            return .unfinishedStart(pending, previous: committed)
        }
        return committed.map { .resume($0) }
    }

    static func isCurrent(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age < lifetime && age > -futureTolerance
    }
}
