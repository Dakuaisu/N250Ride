import RideCore
import SwiftUI
import UIKit

/// One candidate route returned by a single request; choosing between them sends
/// no further requests.
struct RouteOption: Identifiable, Equatable, Sendable {
    let id: Int
    var name: String
    var distanceMetres: Double
    var expectedSeconds: Double
    var hasTolls: Bool
    var hasHighways: Bool
}

/// Rider choices applied to every route request and reroute.
struct RoutePreferences: Equatable, Codable, Sendable {
    var avoidTolls = false
    var avoidHighways = false
}

/// A live guidance source chosen at build time (Apple MapKit now, Google later).
/// Providers dispatch only requests the app has already authorised through
/// `RouteRequestGate`, and never retry on their own.
@MainActor
protocol LiveNavigationProvider: AnyObject {
    var onSnapshot: ((NavigationSnapshot) -> Void)? { get set }
    var onLongPress: ((Coordinate) -> Void)? { get set }
    /// The rider left the route and the provider cannot reroute by itself (throttled).
    var onRerouteNeeded: (() -> Void)? { get set }
    var routePreferences: RoutePreferences { get set }

    var name: String { get }
    /// Shown on the route preview, e.g. which vehicle profile the route uses.
    var routingLabel: String { get }
    var termsNotice: String { get }
    var termsAccepted: Bool { get }
    var sdkVersion: String? { get }
    /// One long-lived map view, never recreated by SwiftUI.
    var mapHostView: UIView { get }

    func requestTerms(completion: @escaping @MainActor (Bool) -> Void)
    /// Returns the candidate routes (fastest first); the first is selected.
    func requestRoute(to destination: Coordinate, title: String, session: SessionID, generation: RouteGeneration,
                      completion: @escaping @MainActor (Result<[RouteOption], RouteRequestFailure>) -> Void)
    /// Switches the selected candidate before guidance starts. No network request.
    func selectRoute(_ id: RouteOption.ID) -> Bool
    /// Follow the rider, or show the whole route before guidance starts.
    func recenter()
    /// New route from the current location to the current destination. The new route
    /// produces no snapshot until a later location update, after the completion ran.
    func reroute(session: SessionID, generation: RouteGeneration,
                 completion: @escaping @MainActor (Result<Void, RouteRequestFailure>) -> Void)
    func startGuidance()
    func stop()
}

struct ProviderMapHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
