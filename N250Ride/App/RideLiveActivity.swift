import ActivityKit
import Foundation
import RideCore

/// Starts, updates and ends the ride's Live Activity. Updates are sent only when
/// the visible text changes (and at most every 2 s) to stay within iOS budgets.
@MainActor
final class RideLiveActivity {
    /// Only the ID is kept; the activity is looked up where it is updated, so no
    /// non-Sendable object crosses actors.
    private var activityID: String?
    private var lastState: RideActivityAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    func start(destination: String) {
        end()
        // UI tests pass -disableLiveActivity YES: the simulator's activity renderer is
        // too heavy for repeated automated rides.
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              !UserDefaults.standard.bool(forKey: "disableLiveActivity") else { return }
        let initial = RideActivityAttributes.ContentState(symbol: "location.north.line", headline: "Starting…",
                                                          detail: destination, arrival: nil, remaining: "", warning: false)
        activityID = (try? Activity.request(attributes: RideActivityAttributes(destination: destination),
                                            content: ActivityContent(state: initial, staleDate: nil)))?.id
        lastState = initial
    }

    func update(_ snapshot: NavigationSnapshot, linkReady: Bool) {
        guard let id = activityID else { return }
        let state = Self.state(for: snapshot, linkReady: linkReady)
        let now = Date()
        guard state != lastState, now.timeIntervalSince(lastUpdate) >= 2 || state.symbol != lastState?.symbol else { return }
        lastState = state
        lastUpdate = now
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(60))
        Task.detached {
            await Activity<RideActivityAttributes>.activities.first { $0.id == id }?.update(content)
        }
    }

    func end() {
        guard let id = activityID else { return }
        activityID = nil
        lastState = nil
        Task.detached {
            await Activity<RideActivityAttributes>.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func state(for snapshot: NavigationSnapshot, linkReady: Bool) -> RideActivityAttributes.ContentState {
        let arrival = snapshot.remainingSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }
        let remaining = [snapshot.remainingMetres.map { Format.distance(Double($0)) },
                         snapshot.remainingSeconds.map { Format.duration(Double($0)) }]
            .compactMap { $0 }.joined(separator: " · ")
        switch snapshot.state {
        case .arrived:
            return .init(symbol: "flag.checkered", headline: "Arrived", detail: "", arrival: nil, remaining: "", warning: false)
        case .rerouting:
            return .init(symbol: "arrow.triangle.branch", headline: "Rerouting…", detail: "Finding a new route",
                         arrival: nil, remaining: "", warning: true)
        case .noLocation:
            return .init(symbol: "location.slash", headline: "No GPS", detail: "Waiting for location",
                         arrival: nil, remaining: "", warning: true)
        default:
            let step = snapshot.step
            return .init(symbol: TurnCard.symbol(for: step?.maneuver),
                         headline: step.map { Format.distance(Double($0.distanceMetres)) } ?? "Follow the route",
                         detail: linkReady ? (step?.roadText ?? "") : "Bike not connected",
                         arrival: arrival, remaining: remaining, warning: !linkReady)
        }
    }
}
