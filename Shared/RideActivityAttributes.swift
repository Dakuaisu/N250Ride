import ActivityKit
import Foundation

/// Lock Screen / Dynamic Island content for an active ride. Shared by the app and
/// the widget extension; carries display text only, never coordinates.
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// SF Symbol name for the next maneuver.
        var symbol: String
        /// Large text: distance to the turn, or a status such as "Rerouting…".
        var headline: String
        /// Road name or a short instruction.
        var detail: String
        var arrival: Date?
        var remaining: String
        var warning: Bool

        /// Shown once the position behind the content has expired: never a direction.
        static let stale = ContentState(symbol: "exclamationmark.triangle", headline: "Guidance paused",
                                        detail: "Open N250 Ride", arrival: nil, remaining: "", warning: true)
    }

    var destination: String
}
