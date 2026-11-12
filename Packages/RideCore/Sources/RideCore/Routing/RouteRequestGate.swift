import Foundation

/// Local, conservative limits on explicit destination submissions. They do not
/// guarantee zero Google charges: they reset on reinstall and cannot see other
/// usage on the same billing account.
public struct RouteRequestLimits: Sendable, Equatable {
    public var perDay: Int
    public var perMonth: Int

    public init(perDay: Int = 20, perMonth: Int = 600) {
        self.perDay = perDay
        self.perMonth = perMonth
    }
}

public enum RouteRequestPolicy: Sendable, Equatable {
    /// Live requests are not authorised (no key, GATE-1/GATE-2 open, terms not accepted).
    case disabled(reason: String)
    /// Billable provider: every destination counts before dispatch.
    case metered(RouteRequestLimits)
    /// Non-billed provider (Apple fallback): still serialised and debounced, not counted.
    case unmetered
}

public struct UsageCounters: Codable, Sendable, Equatable {
    public var dayKey: String
    public var dayCount: Int
    public var monthKey: String
    public var monthCount: Int

    public init(dayKey: String, dayCount: Int, monthKey: String, monthCount: Int) {
        self.dayKey = dayKey
        self.dayCount = dayCount
        self.monthKey = monthKey
        self.monthCount = monthCount
    }
}

public protocol UsageCounterStore: AnyObject {
    func load() -> UsageCounters?
    func save(_ counters: UsageCounters)
}

public final class InMemoryUsageCounterStore: UsageCounterStore {
    public private(set) var saved: UsageCounters?

    public init(_ initial: UsageCounters? = nil) {
        saved = initial
    }

    public func load() -> UsageCounters? { saved }
    public func save(_ counters: UsageCounters) { saved = counters }
}

public enum RouteRequestDenial: Error, Sendable, Equatable {
    case providerDisabled(String)
    /// A request is already being dispatched; repeated taps coalesce into it.
    case requestInFlight
    case tooSoon
    case invalidDestinationCount
    case dailyLimitReached(limit: Int)
    case monthlyLimitReached(limit: Int)
}

public struct RouteTicket: Sendable, Hashable {
    public let id: UUID
    public let destinationCount: Int
}

public struct RouteUsage: Sendable, Equatable {
    public var dayCount: Int
    public var monthCount: Int
    public var limits: RouteRequestLimits?
    public var dayResetsAt: Date
    public var monthResetsAt: Date
}

/// The only path to a route request. Counts destinations before dispatch, allows a
/// single request in flight, debounces repeats, and never retries on its own.
/// Lifecycle events (background/foreground, Bluetooth reconnect) have no access to it.
public final class RouteRequestGate {
    public private(set) var policy: RouteRequestPolicy
    public private(set) var inFlight: RouteTicket?

    private let store: UsageCounterStore
    private let clock: RideClock
    private let calendar: Calendar
    private let debounce: Duration
    private var lastAuthorizedAt: MonotonicInstant?

    public init(
        policy: RouteRequestPolicy,
        store: UsageCounterStore,
        clock: RideClock,
        timeZone: TimeZone = .current,
        debounce: Duration = .seconds(2)
    ) {
        self.policy = policy
        self.store = store
        self.clock = clock
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.debounce = debounce
    }

    public func update(policy: RouteRequestPolicy) {
        self.policy = policy
    }

    /// Call immediately before dispatching. Success means the destinations are
    /// already counted and persisted; the caller must dispatch exactly once.
    public func authorize(destinationCount: Int) -> Result<RouteTicket, RouteRequestDenial> {
        if case .disabled(let reason) = policy { return .failure(.providerDisabled(reason)) }
        guard destinationCount >= 1 else { return .failure(.invalidDestinationCount) }
        guard inFlight == nil else { return .failure(.requestInFlight) }
        if let last = lastAuthorizedAt, clock.now.duration(since: last) < debounce {
            return .failure(.tooSoon)
        }

        if case .metered(let limits) = policy {
            var counters = currentCounters()
            guard counters.dayCount + destinationCount <= limits.perDay else {
                return .failure(.dailyLimitReached(limit: limits.perDay))
            }
            guard counters.monthCount + destinationCount <= limits.perMonth else {
                return .failure(.monthlyLimitReached(limit: limits.perMonth))
            }
            counters.dayCount += destinationCount
            counters.monthCount += destinationCount
            store.save(counters)
        }

        let ticket = RouteTicket(id: UUID(), destinationCount: destinationCount)
        inFlight = ticket
        lastAuthorizedAt = clock.now
        return .success(ticket)
    }

    /// The provider answered (route, error or cancellation). Failures are not
    /// refunded and not retried; the rider decides whether to try again.
    public func finish(_ ticket: RouteTicket) {
        if inFlight == ticket { inFlight = nil }
    }

    public var usage: RouteUsage {
        let counters = currentCounters()
        let now = clock.wallNow
        let startOfDay = calendar.startOfDay(for: now)
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? startOfDay
        let limits: RouteRequestLimits? = if case .metered(let l) = policy { l } else { nil }
        return RouteUsage(
            dayCount: counters.dayCount,
            monthCount: counters.monthCount,
            limits: limits,
            dayResetsAt: calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now,
            monthResetsAt: calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? now
        )
    }

    private func currentCounters() -> UsageCounters {
        let now = clock.wallNow
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        let monthKey = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        let dayKey = monthKey + String(format: "-%02d", c.day ?? 0)
        var counters = store.load() ?? UsageCounters(dayKey: dayKey, dayCount: 0, monthKey: monthKey, monthCount: 0)
        if counters.monthKey != monthKey {
            counters.monthKey = monthKey
            counters.monthCount = 0
        }
        if counters.dayKey != dayKey {
            counters.dayKey = dayKey
            counters.dayCount = 0
        }
        return counters
    }
}
