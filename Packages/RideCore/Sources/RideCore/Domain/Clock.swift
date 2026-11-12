import Foundation

/// A point on a monotonic timeline. Freshness and timeouts use this; only the
/// displayed ETA uses wall-clock time.
public struct MonotonicInstant: Sendable, Hashable, Comparable {
    public var offset: Duration

    public init(offset: Duration) {
        self.offset = offset
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }

    public static func + (lhs: Self, rhs: Duration) -> Self { Self(offset: lhs.offset + rhs) }

    public func duration(since earlier: Self) -> Duration { offset - earlier.offset }
}

/// Injectable time source so session rules are tested on a virtual clock.
public protocol RideClock: AnyObject {
    var now: MonotonicInstant { get }
    var wallNow: Date { get }
}

public final class SystemRideClock: RideClock {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: MonotonicInstant { MonotonicInstant(offset: origin.duration(to: .now)) }
    public var wallNow: Date { Date() }
}

/// Virtual clock for tests and the no-key simulation replay.
public final class ManualClock: RideClock {
    public private(set) var now: MonotonicInstant
    public private(set) var wallNow: Date

    public init(wallNow: Date = Date(timeIntervalSince1970: 1_793_000_000)) {
        self.now = MonotonicInstant(offset: .zero)
        self.wallNow = wallNow
    }

    public func advance(by duration: Duration) {
        now = now + duration
        let c = duration.components
        wallNow += Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
