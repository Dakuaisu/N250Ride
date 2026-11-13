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
/// Two independent clocks decide when to submit:
/// - freshness: a newer measurement's stale date is submitted at most every
///   `renewalInterval` (inside the five-second evidence lifetime), even when the
///   text is unchanged or a text change is still being held back;
/// - text: changes are throttled to `minimumInterval` (longer in energy saving);
///   warnings and symbol changes go out at once. A held change that becomes equal
///   to what is shown again is dropped.
@MainActor
final class RideLiveActivity {
    private typealias State = RideActivityAttributes.ContentState

    private var activityID: String?
    private var shownState: State?
    private var shownStaleDate: Date?
    private var lastSubmit = Date.distantPast
    private var lastTextChange = Date.distantPast
    private var pendingText: State?
    private var latestStaleDate: Date?
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
        shownState = initial
        shownStaleDate = nil
        latestStaleDate = nil
        lastSubmit = now()
        lastTextChange = lastSubmit
    }

    /// `staleDate` is when the current position stops being evidence.
    func update(_ snapshot: NavigationSnapshot, health: RideHealth, linkReady: Bool, staleDate: Date?) {
        guard activityID != nil, let shown = shownState else { return }
        let state = Self.state(for: snapshot, health: health, linkReady: linkReady)
        let time = now()
        if let staleDate, latestStaleDate.map({ staleDate > $0 }) ?? true { latestStaleDate = staleDate }
        if staleDate == nil { latestStaleDate = nil }
        if state == shown {
            pendingText = nil
        } else if state.symbol != shown.symbol || state.warning != shown.warning {
            pendingText = nil
            return submit(state, at: time)
        } else {
            pendingText = state
        }
        reconcile(at: time)
    }

    func end() {
        flush?.cancel()
        flush = nil
        pendingText = nil
        guard let id = activityID else { return }
        activityID = nil
        shownState = nil
        shownStaleDate = nil
        latestStaleDate = nil
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

    private var needsRenewal: Bool {
        guard let latestStaleDate else { return false }
        return shownStaleDate.map { latestStaleDate > $0 } ?? true
    }

    /// Submits whatever is due now and schedules one wake for the next due item.
    private func reconcile(at time: Date) {
        flush?.cancel()
        flush = nil
        guard activityID != nil, let shown = shownState else { return }
        let textDue = pendingText.map { _ in lastTextChange.addingTimeInterval(minimumInterval) }
        let renewalDue = needsRenewal ? lastSubmit.addingTimeInterval(Self.renewalInterval) : nil
        if let pending = pendingText, let textDue, time >= textDue {
            pendingText = nil
            return submit(pending, at: time)
        }
        if let renewalDue, time >= renewalDue {
            return submit(shown, at: time, textChanged: false)
        }
        guard let due = [textDue, renewalDue].compactMap({ $0 }).min() else { return }
        let delay = max(due.timeIntervalSince(time), 0)
        flush = timers.schedule(after: .milliseconds(Int((delay * 1_000).rounded(.up)))) { [weak self] in
            guard let self else { return }
            self.flush = nil
            self.reconcile(at: self.now())
        }
    }

    private func submit(_ state: State, at time: Date, textChanged: Bool = true) {
        guard let id = activityID else { return }
        let staleDate = latestStaleDate
        shownState = state
        shownStaleDate = staleDate
        lastSubmit = time
        if textChanged { lastTextChange = time }
        updates += 1
        enqueue { [sink] in await sink.update(id, state: state, staleDate: staleDate) }
        if pendingText != nil { reconcile(at: time) }
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
