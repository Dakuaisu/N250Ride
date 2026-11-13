import ActivityKit
import Foundation
import RideCore

/// Starts, updates and ends the ride's Live Activity. All requests run one after
/// another on a single chain, so a late update can never overwrite End. Content is
/// derived from ride health: no direction is shown unless guidance is current, and
/// the activity is marked stale when the position behind it expires.
@MainActor
final class RideLiveActivity {
    /// Only the ID is kept; the activity is looked up where it is updated, so no
    /// non-Sendable object crosses actors.
    private var activityID: String?
    private var lastState: RideActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast
    private var chain: Task<Void, Never>?
    private let enabled: Bool
    private(set) var updates = 0
    var minimumInterval: TimeInterval = 2

    init(enabled: Bool) {
        self.enabled = enabled
    }

    func start(destination: String) {
        end()
        // UI tests pass -disableLiveActivity YES: the simulator's activity renderer is
        // too heavy for repeated automated rides.
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled,
              !UserDefaults.standard.bool(forKey: "disableLiveActivity") else { return }
        let initial = RideActivityAttributes.ContentState(symbol: "location.north.line", headline: "Starting…",
                                                          detail: destination, arrival: nil, remaining: "", warning: false)
        activityID = (try? Activity.request(attributes: RideActivityAttributes(destination: destination),
                                            content: ActivityContent(state: initial, staleDate: nil)))?.id
        lastState = initial
    }

    /// `staleDate` is when the current position stops being evidence.
    func update(_ snapshot: NavigationSnapshot, health: RideHealth, linkReady: Bool, staleDate: Date?) {
        guard let id = activityID else { return }
        let state = Self.state(for: snapshot, health: health, linkReady: linkReady)
        let now = Date()
        let urgent = state.symbol != lastState?.symbol || state.warning != lastState?.warning
        guard state != lastState, urgent || now.timeIntervalSince(lastUpdate) >= minimumInterval else { return }
        lastState = state
        lastUpdate = now
        updates += 1
        let content = ActivityContent(state: state, staleDate: staleDate)
        enqueue { await Activity<RideActivityAttributes>.activities.first { $0.id == id }?.update(content) }
    }

    func end() {
        guard let id = activityID else { return }
        activityID = nil
        lastState = nil
        enqueue {
            await Activity<RideActivityAttributes>.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// At launch: an activity left by a stopped app shows nothing current.
    func endOrphans() {
        guard enabled else { return }
        enqueue {
            for activity in Activity<RideActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = chain
        chain = Task {
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
