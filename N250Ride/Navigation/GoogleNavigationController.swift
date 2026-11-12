#if canImport(GoogleNavigation)
import CoreLocation
import GoogleMaps
import GoogleNavigation
import RideCore
import SwiftUI

/// Owns the Google SDK for the life of the process: one map view and one navigator,
/// never recreated by SwiftUI. Constructed only in live mode (key present and
/// GATE-1/GATE-2 authorised); simulation never initialises the SDK.
///
/// Route requests go through `RouteRequestGate` in `AppModel`; this type only
/// dispatches an already-authorised request and never retries on its own.
@MainActor
final class GoogleNavigationController: NSObject, LiveNavigationProvider {
    var onSnapshot: ((NavigationSnapshot) -> Void)?
    var onLongPress: ((Coordinate) -> Void)?
    /// Unused: the Navigation SDK reroutes by itself at no extra destination charge.
    var onRerouteNeeded: (() -> Void)?
    var routePreferences = RoutePreferences() {
        didSet {
            mapView.navigator?.avoidsTolls = routePreferences.avoidTolls
            mapView.navigator?.avoidsHighways = routePreferences.avoidHighways
        }
    }

    let name = "Google"
    let routingLabel = "Google two-wheeler route with traffic"
    let termsNotice = "Google's navigation terms and driver-awareness notice must be accepted first."
    var sdkVersion: String? { Self.sdkVersion }
    var mapHostView: UIView { mapView }

    let mapView: GMSMapView
    private let clock: RideClock
    private var session: SessionID?
    private var generation = RouteGeneration(0)
    private var lastFields: GoogleNavInfoFields?
    private(set) var termsAccepted = GMSNavigationServices.areTermsAndConditionsAccepted()

    static let companyName = "N250 Ride"

    static func provideKeyOnce(_ key: String) -> Bool {
        GMSServices.provideAPIKey(key)
    }

    init(clock: RideClock) {
        self.clock = clock
        mapView = GMSMapView(options: GMSMapViewOptions())
        super.init()
        mapView.delegate = self
        mapView.isMyLocationEnabled = true
        mapView.settings.compassButton = true
    }

    static var sdkVersion: String { GMSNavigationServices.navSDKVersion() }

    /// Shows Google's terms/driver-awareness dialog; navigation stays disabled until accepted.
    func requestTerms(completion: @escaping @MainActor (Bool) -> Void) {
        let options = GMSNavigationTermsAndConditionsOptions(companyName: Self.companyName)
        GMSNavigationServices.showTermsAndConditionsDialogIfNeeded(with: options) { [weak self] accepted in
            MainActor.assumeIsolated {
                self?.termsAccepted = accepted
                if accepted { self?.enableNavigation() }
                completion(accepted)
            }
        }
    }

    private func enableNavigation() {
        guard !mapView.isNavigationEnabled else { return }
        mapView.isNavigationEnabled = true
        mapView.travelMode = .twoWheeler
        mapView.navigator?.add(self)
        mapView.navigator?.voiceGuidance = .silent
        mapView.navigator?.timeUpdateThreshold = 1
        mapView.navigator?.distanceUpdateThreshold = 5
        mapView.roadSnappedLocationProvider?.add(self)
        mapView.roadSnappedLocationProvider?.allowsBackgroundLocationUpdates = true
        mapView.roadSnappedLocationProvider?.startUpdatingLocation()
    }

    /// Dispatches one authorised destination request. The caller has already counted it.
    func selectRoute(_ id: RouteOption.ID) -> Bool { id == 0 }

    func recenter() {
        mapView.cameraMode = .following
    }

    func requestRoute(to coordinate: Coordinate, title: String, session: SessionID, generation: RouteGeneration,
                      completion: @escaping @MainActor (Result<[RouteOption], RouteRequestFailure>) -> Void) {
        guard termsAccepted, let navigator = mapView.navigator,
              let waypoint = GMSNavigationWaypoint(
                location: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                title: title)
        else {
            completion(.failure(.other("navigation not ready")))
            return
        }
        self.session = session
        self.generation = generation
        lastFields = nil
        mapView.travelMode = .twoWheeler
        navigator.setDestinations([waypoint]) { routeDescription, error in
            let status = routeDescription?.routeStatus
            let errorCode = error.map { ($0 as NSError).code }
            MainActor.assumeIsolated {
                if let status, let failure = GoogleGuidanceMapper.failure(for: status) {
                    completion(.failure(failure))
                } else if status == nil {
                    completion(.failure(.other(errorCode.map { "\($0)" } ?? "no response")))
                } else {
                    let navigator = self.mapView.navigator
                    completion(.success([RouteOption(
                        id: 0, name: "Google two-wheeler route",
                        distanceMetres: navigator?.distanceToNextDestination ?? 0,
                        expectedSeconds: navigator?.timeToNextDestination ?? 0,
                        hasTolls: false, hasHighways: false)]))
                }
            }
        }
    }

    func reroute(session: SessionID, generation: RouteGeneration,
                 completion: @escaping @MainActor (Result<Void, RouteRequestFailure>) -> Void) {
        completion(.failure(.other("Google reroutes automatically")))
    }

    func startGuidance() {
        mapView.navigator?.isGuidanceActive = true
        mapView.cameraMode = .following
    }

    func stop() {
        mapView.navigator?.isGuidanceActive = false
        mapView.navigator?.clearDestinations()
        mapView.cameraMode = .free
        if let session {
            onSnapshot?(NavigationSnapshot(session: session, generation: generation,
                                           observedAt: clock.now, state: .stopped))
        }
        session = nil
        lastFields = nil
    }

    private func publish(_ fields: GoogleNavInfoFields) {
        guard let session else { return }
        lastFields = fields
        onSnapshot?(GoogleGuidanceMapper.snapshot(fields, session: session, generation: generation,
                                                  observedAt: clock.now))
    }
}

extension GoogleNavigationController: GMSNavigatorListener {
    nonisolated func navigator(_ navigator: GMSNavigator, didUpdate navInfo: GMSNavigationNavInfo) {
        let fields = GoogleNavInfoFields(navInfo)
        MainActor.assumeIsolated { publish(fields) }
    }

    nonisolated func navigator(_ navigator: GMSNavigator, didArriveAt waypoint: GMSNavigationWaypoint) {
        MainActor.assumeIsolated {
            guard let session else { return }
            onSnapshot?(NavigationSnapshot(session: session, generation: generation,
                                           observedAt: clock.now, state: .arrived))
        }
    }
}

extension GoogleNavigationController: GMSRoadSnappedLocationProviderListener {
    /// Location updates prove the SDK is alive during quiet stretches, so the last
    /// guidance is re-published with a fresh timestamp instead of going stale.
    nonisolated func locationProvider(_ locationProvider: GMSRoadSnappedLocationProvider,
                                      didUpdate location: CLLocation) {
        let valid = location.horizontalAccuracy >= 0
        MainActor.assumeIsolated {
            guard valid, let lastFields else { return }
            publish(lastFields)
        }
    }
}

extension GoogleNavigationController: GMSMapViewDelegate {
    nonisolated func mapView(_ mapView: GMSMapView, didLongPressAt coordinate: CLLocationCoordinate2D) {
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        MainActor.assumeIsolated {
            if let picked = Coordinate(latitude: latitude, longitude: longitude) { onLongPress?(picked) }
        }
    }
}
#endif
