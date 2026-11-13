import Foundation

enum RouteRequestFailure: Error, Equatable {
    /// No two-wheeler route here; car routing is never substituted.
    case noTwoWheelerRoute
    case noRoute
    case network
    case throttled
    case quotaExceeded
    case keyNotAuthorized
    case locationUnavailable
    case cancelled
    /// Took longer than the 30-second limit for one route calculation.
    case timedOut
    case other(String)

    var message: String {
        switch self {
        case .noTwoWheelerRoute: "No two-wheeler route found. Two-wheeler routing may be unavailable here; car routing is not used instead."
        case .noRoute: "No route found to this destination."
        case .network: "Network error. Try again when you have signal."
        case .throttled: "Too many route requests in a short time. Wait a minute and try again."
        case .quotaExceeded: "Google quota exceeded. Navigation stays off to avoid charges."
        case .keyNotAuthorized: "The Google API key is not authorised for the Navigation SDK."
        case .locationUnavailable: "Current location unavailable. Check Location permission and GPS signal."
        case .cancelled: "Route request cancelled."
        case .timedOut: "Finding a route took too long. Try again."
        case .other(let detail): "Route failed (\(detail))."
        }
    }
}
