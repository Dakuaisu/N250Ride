import ActivityKit
import Foundation
import RideCore

/// Where Live Activity requests go: ActivityKit in the app, a recorder in tests.
@MainActor
protocol ActivitySink: AnyObject {
    func start(destination: String, state: RideActivityAttributes.ContentState) -> String?
    func update(_ id: String, state: RideActivityAttributes.ContentState, staleDate: Date?) async
    func end(_ id: String) async
    func endAll() async
}

@MainActor
final class ActivityKitSink: ActivitySink {
    func start(destination: String, state: RideActivityAttributes.ContentState) -> String? {
        // UI tests pass -disableLiveActivity YES: the simulator's activity renderer is
        // too heavy for repeated automated rides.
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              !UserDefaults.standard.bool(forKey: "disableLiveActivity") else { return nil }
        return (try? Activity.request(attributes: RideActivityAttributes(destination: destination),
                                      content: ActivityContent(state: state, staleDate: nil)))?.id
    }

    func update(_ id: String, state: RideActivityAttributes.ContentState, staleDate: Date?) async {
        await Self.update(id, state: state, staleDate: staleDate)
    }

    func end(_ id: String) async {
        await Self.end(id)
    }

    func endAll() async {
        await Self.endAll()
    }

    // ActivityKit objects are not Sendable: they are found and used off the main actor only.
    nonisolated private static func update(_ id: String, state: RideActivityAttributes.ContentState,
                                           staleDate: Date?) async {
        await Activity<RideActivityAttributes>.activities.first { $0.id == id }?
            .update(ActivityContent(state: state, staleDate: staleDate))
    }

    nonisolated private static func end(_ id: String) async {
        await Activity<RideActivityAttributes>.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate)
    }

    nonisolated private static func endAll() async {
        for activity in Activity<RideActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// Starts, updates and ends the ride's Live Activity. All requests run one after
/// another on a single chain, so a late update can never overwrite End. Content is
/// derived from ride health: no direction is shown unless guidance is current.
///
/// The stale date is part of what is submitted. A newer measurement renews it even
/// when the visible text is unchanged, at most every `renewalInterval` (inside the
/// five-second evidence lifetime). The display throttle (longer in energy saving)
/// only delays text changes, and a delayed change or renewal is still delivered.
@MainActor
final class RideLiveActivity {
    private typealias State = RideActivityAttributes.ContentState

    private var activityID: String?
    private var lastState: State?
    private var lastStaleDate: Date?
    private var lastUpdate = Date.distantPast
    private var deferred: (state: State, staleDate: Date?)?
    private var flush: TimerToken?
    private var chain: Task<Void, Never>?
    private let enabled: Bool
    private let sink: ActivitySink
    private let timers: RideTimers
    private let now: () -> Date
    private(set) var updates = 0
    var minimumInterval: TimeInterval = 2
    static let renewalInterval: TimeInterval = 2

    init(enabled: Bool, sink: ActivitySink, timers: RideTimers, now: @escaping () -> Date) {
        self.enabled = enabled
        self.sink = sink
        self.timers = timers
        self.now = now
    }

    func start(destination: String) {
        end()
        guard enabled else { return }
        let initial = State(symbol: "location.north.line", headline: "Starting…", detail: destination, arrival: nil,
                            remaining: "", warning: false)
        activityID = sink.start(destination: destination, state: initial)
        lastState = initial
        lastStaleDate = nil
        lastUpdate = now()
    }

    /// `staleDate` is when the current position stops being evidence.
    func update(_ snapshot: NavigationSnapshot, health: RideHealth, linkReady: Bool, staleDate: Date?) {
        guard activityID != nil, let shown = lastState else { return }
        let state = Self.state(for: snapshot, health: health, linkReady: linkReady)
        let time = now()
        let since = time.timeIntervalSince(lastUpdate)
        let renews = staleDate.map { new in lastStaleDate.map { new > $0 } ?? true } ?? false
        if state != shown {
            let urgent = state.symbol != shown.symbol || state.warning != shown.warning
            if urgent || since >= minimumInterval {
                return submit(state, staleDate: staleDate, at: time)
            }
            // Text change throttled: keep it for later, but never let freshness lapse meanwhile.
            schedule(state, staleDate: staleDate, at: lastUpdate.addingTimeInterval(minimumInterval), from: time)
            if renews, since >= Self.renewalInterval { renew(shown, staleDate: staleDate, at: time) }
            return
        }
        guard renews else { return }
        if since >= Self.renewalInterval {
            submit(state, staleDate: staleDate, at: time)
        } else {
            schedule(state, staleDate: staleDate, at: lastUpdate.addingTimeInterval(Self.renewalInterval), from: time)
        }
    }

    func end() {
        flush?.cancel()
        flush = nil
        deferred = nil
        guard let id = activityID else { return }
        activityID = nil
        lastState = nil
        lastStaleDate = nil
        enqueue { [sink] in await sink.end(id) }
    }

    /// At launch: an activity left by a stopped app shows nothing current.
    func endOrphans() {
        guard enabled else { return }
        enqueue { [sink] in await sink.endAll() }
    }

    /// Lets tests wait until every queued request reached the sink.
    func settle() async {
        await chain?.value
    }

    private func submit(_ state: State, staleDate: Date?, at time: Date) {
        flush?.cancel()
        flush = nil
        deferred = nil
        renew(state, staleDate: staleDate, at: time)
    }

    private func renew(_ state: State, staleDate: Date?, at time: Date) {
        guard let id = activityID else { return }
        lastState = state
        lastStaleDate = staleDate
        lastUpdate = time
        updates += 1
        enqueue { [sink] in await sink.update(id, state: state, staleDate: staleDate) }
    }

    private func schedule(_ state: State, staleDate: Date?, at due: Date, from time: Date) {
        deferred = (state, staleDate)
        guard flush == nil else { return }
        let delay = max(due.timeIntervalSince(time), 0)
        flush = timers.schedule(after: .milliseconds(Int((delay * 1_000).rounded(.up)))) { [weak self] in
            guard let self else { return }
            self.flush = nil
            guard let deferred = self.deferred else { return }
            self.submit(deferred.state, staleDate: deferred.staleDate, at: self.now())
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    static func state(for snapshot: NavigationSnapshot, health: RideHealth,
                      linkReady: Bool) -> RideActivityAttributes.ContentState {
        if snapshot.state == .arrived {
            return .init(symbol: "flag.checkered", headline: "Arrived", detail: "", arrival: nil, remaining: "", warning: false)
        }
        guard health.directionEligible else {
            let headline = switch snapshot.state {
            case .rerouting: "Rerouting…"
            case .noLocation: "No GPS"
            default: "Paused"
            }
            return .init(symbol: snapshot.state == .rerouting ? "arrow.triangle.branch" : "exclamationmark.triangle",
                         headline: headline, detail: health.primary.message, arrival: nil, remaining: "", warning: true)
        }
        let arrival = snapshot.remainingSeconds.map { minute(Date().addingTimeInterval(TimeInterval($0))) }
        let remaining = [snapshot.remainingMetres.map { Format.distance(Double($0)) },
                         snapshot.remainingSeconds.map { Format.duration(Double($0)) }]
            .compactMap { $0 }.joined(separator: " · ")
        let step = snapshot.step
        return .init(symbol: TurnCard.symbol(for: step?.maneuver),
                     headline: step.map { Format.distance(Double($0.distanceMetres)) } ?? "Follow the route",
                     detail: linkReady ? (step?.roadText ?? "") : "Bike not connected",
                     arrival: arrival, remaining: remaining, warning: !linkReady)
    }

    /// Arrival to the minute, so a moving ETA does not produce an update every second.
    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }
}
