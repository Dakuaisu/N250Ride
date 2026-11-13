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

/// Why a route is being calculated. Every reason goes through the same gate and
/// the same prepare/commit path.
enum RouteReason: String, Sendable, Equatable {
    case initial, manual, offRoute, recovery, nextLeg, replacement

    var keepsSession: Bool { self == .manual || self == .offRoute }
}

/// One explicitly authorised calculation. `session`/`generation` are provisional:
/// they gain authority only when the owner commits the prepared route.
struct NavigationRouteRequest: Sendable {
    let operationID: UUID
    let session: SessionID
    let generation: RouteGeneration
    let target: Coordinate
    let title: String
    let preferences: RoutePreferences
    let reason: RouteReason
    let alternatives: Bool
    let fix: FixRequirement
}

/// Process-local token for a calculated but inactive route. Deliberately not Codable.
struct PreparedRouteHandle: Hashable, Sendable {
    let id: UUID
}

struct PreparedRoute: Sendable {
    let handle: PreparedRouteHandle
    let options: [RouteOption]
    let origin: Coordinate
}

/// Whether the rider is still where a prepared route starts.
enum StartCheck: Equatable, Sendable {
    case ready
    case noCurrentFix
    case movedFromOrigin(metres: Int)

    static let maxDisplacementMetres = 100.0
}

/// A live guidance source chosen at build time (Apple MapKit now, Google later).
/// Providers dispatch only requests the app has already authorised through
/// `RouteRequestGate`, and never retry on their own.
///
/// Preparation never touches the active route: a prepared route becomes active only
/// through `commitPreparedRoute`, which emits no snapshot, so the owner can switch
/// its session/generation before the first callback of the new route arrives.
@MainActor
protocol LiveNavigationProvider: AnyObject {
    var onSnapshot: ((NavigationSnapshot) -> Void)? { get set }
    var onLongPress: ((Coordinate) -> Void)? { get set }
    /// The rider left the route; the owner decides whether to request a new one.
    var onRerouteNeeded: (() -> Void)? { get set }
    /// Every accepted, genuinely new position while guiding.
    var onFix: ((AdmittedFix) -> Void)? { get set }

    var name: String { get }
    /// Shown on the route preview, e.g. which vehicle profile the route uses.
    var routingLabel: String { get }
    var termsNotice: String { get }
    var termsAccepted: Bool { get }
    var sdkVersion: String? { get }
    /// One long-lived map view, never recreated by SwiftUI.
    var mapHostView: UIView { get }
    /// False when preparing a route would disturb the active one (then the owner
    /// refuses replacements while guiding).
    var supportsTransactionalReplacement: Bool { get }
    /// The newest accepted position, for ride health.
    var lastFix: AdmittedFix? { get }

    func requestTerms(completion: @escaping @MainActor (Bool) -> Void)
    func prepareRoute(_ request: NavigationRouteRequest,
                      completion: @escaping @MainActor (Result<PreparedRoute, RouteRequestFailure>) -> Void)
    /// Shows a prepared candidate on the map before guidance. No network request.
    func previewPrepared(_ handle: PreparedRouteHandle, option: RouteOption.ID) -> Bool
    /// Waits briefly for a current position and compares it with the route's start.
    func checkStart(_ handle: PreparedRouteHandle, completion: @escaping @MainActor (StartCheck) -> Void)
    /// Makes a prepared route the active one. Synchronous and silent.
    func commitPreparedRoute(_ handle: PreparedRouteHandle, option: RouteOption.ID) -> Bool
    /// Abandons an in-flight calculation; its answer, if it still comes, is ignored.
    func cancelPreparation(_ operationID: UUID)
    /// Abandons a pending Start position check without answering it.
    func cancelStartCheck(_ handle: PreparedRouteHandle)
    func discardPrepared(_ handle: PreparedRouteHandle)
    /// Follow the rider, or show the whole route before guidance starts.
    func recenter()
    func setMapVisible(_ visible: Bool)
    func setFollowAnimations(_ enabled: Bool)
    func startGuidance()
    func stop()
}

struct ProviderMapHost: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
