import Foundation

/// A location sample as Core Location delivers it, before any trust is placed in it.
public struct LocationSample: Sendable, Equatable {
    public var coordinate: Coordinate
    /// Metres; negative means invalid (Core Location convention).
    public var horizontalAccuracy: Double
    /// When the sensor measured it (`CLLocation.timestamp`).
    public var timestamp: Date

    public init(coordinate: Coordinate, horizontalAccuracy: Double, timestamp: Date) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }
}

/// A sample accepted as genuine, current evidence of the rider's position.
public struct AdmittedFix: Sendable, Equatable {
    public var sample: LocationSample
    /// The measurement time on the monotonic timeline.
    public var measuredAt: MonotonicInstant
    /// Evidence is stale from this instant on (strictly: `now >= expiresAt` is stale).
    public var expiresAt: MonotonicInstant

    public init(sample: LocationSample, measuredAt: MonotonicInstant, expiresAt: MonotonicInstant) {
        self.sample = sample
        self.measuredAt = measuredAt
        self.expiresAt = expiresAt
    }

    public var fix: LocationFix {
        LocationFix(coordinate: sample.coordinate, horizontalAccuracy: sample.horizontalAccuracy, observedAt: measuredAt)
    }
}

/// Turns Core Location callbacks into trusted fixes. Cached replays, samples from
/// the future, duplicates and out-of-order samples never advance guidance.
///
/// One paired clock reading `(receiptWall, receiptMonotonic)` is taken per callback:
/// `rawAge = receiptWall - timestamp`; samples aged `< -1 s` or `>= maxAge` are
/// rejected; `measuredAt = receiptMonotonic - max(rawAge, 0)` and
/// `expiresAt = measuredAt + maxAge`, so later wall-clock changes cannot extend it.
public struct LocationAdmission: Sendable {
    public static let maxAge: Duration = .seconds(5)
    public static let futureTolerance: TimeInterval = 1

    public enum Rejection: Error, Sendable, Equatable {
        case invalidAccuracy
        case tooOld
        case fromTheFuture
        case notNewer
    }

    private(set) var lastAccepted: Date?

    public init() {}

    public mutating func admit(_ sample: LocationSample, receiptWall: Date,
                               receiptMonotonic: MonotonicInstant) -> Result<AdmittedFix, Rejection> {
        guard sample.horizontalAccuracy >= 0 else { return .failure(.invalidAccuracy) }
        let rawAge = receiptWall.timeIntervalSince(sample.timestamp)
        guard rawAge >= -Self.futureTolerance else { return .failure(.fromTheFuture) }
        guard rawAge < Self.maxAge.seconds else { return .failure(.tooOld) }
        if let lastAccepted, sample.timestamp <= lastAccepted { return .failure(.notNewer) }
        lastAccepted = sample.timestamp
        let measuredAt = receiptMonotonic + .seconds(-max(rawAge, 0))
        return .success(AdmittedFix(sample: sample, measuredAt: measuredAt, expiresAt: measuredAt + Self.maxAge))
    }

    /// A new journey: an older sample may be valid again for a different consumer.
    public mutating func reset() {
        lastAccepted = nil
    }
}

/// How current and precise a position must be before a route is requested from it.
public struct FixRequirement: Sendable, Equatable {
    public var maxAge: TimeInterval
    public var maxAccuracy: Double
    /// The sample must be measured after this moment (e.g. after the rider tapped Resume).
    public var measuredAfter: Date?

    public init(maxAge: TimeInterval, maxAccuracy: Double, measuredAfter: Date? = nil) {
        self.maxAge = maxAge
        self.maxAccuracy = maxAccuracy
        self.measuredAfter = measuredAfter
    }

    /// First route of a new ride: a recent, roughly placed origin is enough.
    public static let initial = FixRequirement(maxAge: 30, maxAccuracy: 100)
    /// Reroute, recovery, next leg and Start: the guidance standard.
    public static let current = FixRequirement(maxAge: 5, maxAccuracy: 50)

    public func accepts(_ sample: LocationSample, now: Date) -> Bool {
        sample.horizontalAccuracy >= 0 && sample.horizontalAccuracy <= maxAccuracy
            && now.timeIntervalSince(sample.timestamp) < maxAge
            && now.timeIntervalSince(sample.timestamp) >= -LocationAdmission.futureTolerance
            && measuredAfter.map { sample.timestamp >= $0 } ?? true
    }
}

extension Duration {
    /// Whole and fractional seconds as a Double.
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
