import CoreLocation
import MapKit
import OSLog
import RideCore
import UIKit

/// Apple MapKit guidance: one `MKDirections` car route per explicit request or
/// throttled reroute, followed by RideCore's `GuidanceEngine` on live locations.
/// Apple has no motorcycle profile, so routes are car-profile and labelled as such.
/// Routes are held in memory for the session only (Apple Maps terms, Att. 6 §2.5).
@MainActor
final class AppleNavigationProvider: NSObject, LiveNavigationProvider {
    var onSnapshot: ((NavigationSnapshot) -> Void)?
    var onLongPress: ((Coordinate) -> Void)?
    var onRerouteNeeded: (() -> Void)?
    var routePreferences = RoutePreferences()

    let name = "Apple Maps"
    let routingLabel = "Apple Maps car route - Apple has no motorcycle routing"
    let termsNotice = """
        YOUR USE OF THIS REAL TIME ROUTE GUIDANCE APPLICATION IS AT YOUR SOLE RISK. LOCATION DATA MAY NOT BE ACCURATE.

        Routes come from Apple Maps for cars; there is no motorcycle profile, so a route may use roads or turns \
        that are not ideal on a bike. Never handle the phone while riding.
        """
    let sdkVersion: String? = nil
    var mapHostView: UIView { mapView }
    private(set) var termsAccepted: Bool

    private let mapView = MKMapView()
    private let locationManager = CLLocationManager()
    private let clock: RideClock
    private let defaults: UserDefaults
    private var engine: GuidanceEngine?
    private var destination: (coordinate: Coordinate, title: String)?
    private var candidates: [Planned] = []
    private var selectedID = 0
    private var routeIdentity: (session: SessionID, generation: RouteGeneration)?
    private var overlays: [MKPolyline] = []
    private var guiding = false
    private var directions: MKDirections?
    private var lastFix: (coordinate: CLLocationCoordinate2D, accuracy: Double, at: Date)?
    private var waitingForFix: [(CLLocationCoordinate2D?) -> Void] = []
    private static let fixTimeout: Duration = .seconds(15)
    /// Core Location may stay quiet while the rider is stopped. A fix this recent
    /// still counts as a valid position, so guidance is refreshed instead of going stale.
    private static let quietFixValidity: TimeInterval = 10
    private var refresher: Task<Void, Never>?

    private static let termsKey = "appleRouteGuidanceNoticeAccepted"
    /// Counts and error codes only; never coordinates or place names.
    nonisolated private static let log = Logger(subsystem: "com.n250ride", category: "routing")

    init(clock: RideClock, defaults: UserDefaults = .standard) {
        self.clock = clock
        self.defaults = defaults
        termsAccepted = defaults.bool(forKey: Self.termsKey)
        super.init()
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func requestTerms(completion: @escaping @MainActor (Bool) -> Void) {
        termsAccepted = true
        defaults.set(true, forKey: Self.termsKey)
        completion(true)
    }

    // MARK: Routes

    func requestRoute(to destination: Coordinate, title: String, session: SessionID, generation: RouteGeneration,
                      completion: @escaping @MainActor (Result<[RouteOption], RouteRequestFailure>) -> Void) {
        self.destination = (destination, title)
        locationManager.startUpdatingLocation()
        calculate(session: session, generation: generation, alternatives: true) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                showWholeRoute()
                completion(.success(candidates.map(\.option)))
            case .failure(let failure):
                completion(.failure(failure))
            }
        }
    }

    func selectRoute(_ id: RouteOption.ID) -> Bool {
        guard !guiding, let identity = routeIdentity, let chosen = candidates.first(where: { $0.option.id == id }),
              let engine = GuidanceEngine(route: chosen.route, session: identity.session,
                                          generation: identity.generation) else { return false }
        selectedID = id
        self.engine = engine
        drawRoutes()
        return true
    }

    func recenter() {
        if guiding || overlays.isEmpty {
            mapView.setUserTrackingMode(guiding ? .followWithHeading : .follow, animated: true)
        } else {
            showWholeRoute()
        }
    }

    func reroute(session: SessionID, generation: RouteGeneration,
                 completion: @escaping @MainActor (Result<Void, RouteRequestFailure>) -> Void) {
        calculate(session: session, generation: generation, alternatives: false, completion: completion)
    }

    private func calculate(session: SessionID, generation: RouteGeneration, alternatives: Bool,
                           completion: @escaping @MainActor (Result<Void, RouteRequestFailure>) -> Void) {
        currentFix { [weak self] origin in
            guard let self else { return }
            guard let origin else {
                completion(.failure(.locationUnavailable))
                return
            }
            calculate(from: origin, session: session, generation: generation, alternatives: alternatives,
                      completion: completion)
        }
    }

    /// A recent, reasonably accurate fix from our own location manager, waiting up to
    /// 15 s for one. Starting from an explicit coordinate avoids MapKit's slow
    /// current-location lookup.
    private func currentFix(_ completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        if let fix = lastFix, Date().timeIntervalSince(fix.at) < 30, fix.accuracy <= 100 {
            completion(fix.coordinate)
            return
        }
        locationManager.startUpdatingLocation()
        waitingForFix.append(completion)
        Task { [weak self] in
            try? await Task.sleep(for: Self.fixTimeout)
            guard let self, !waitingForFix.isEmpty else { return }
            let waiting = waitingForFix
            waitingForFix = []
            waiting.forEach { $0(nil) }
        }
    }

    private func calculate(from origin: CLLocationCoordinate2D, session: SessionID, generation: RouteGeneration,
                           alternatives: Bool,
                           completion: @escaping @MainActor (Result<Void, RouteRequestFailure>) -> Void) {
        guard let destination else {
            completion(.failure(.other("no destination")))
            return
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(
            latitude: destination.coordinate.latitude, longitude: destination.coordinate.longitude)))
        request.transportType = .automobile
        request.tollPreference = routePreferences.avoidTolls ? .avoid : .any
        request.highwayPreference = routePreferences.avoidHighways ? .avoid : .any
        request.requestsAlternateRoutes = alternatives
        directions?.cancel()
        let directions = MKDirections(request: request)
        self.directions = directions
        Self.log.info("directions request started alternatives=\(alternatives)")
        directions.calculate { response, error in
            Self.log.info("directions finished routes=\(response?.routes.count ?? 0) error=\((error as NSError?)?.domain ?? "-", privacy: .public)/\((error as NSError?)?.code ?? 0)")
            let planned = (response?.routes ?? []).prefix(3).enumerated().map { Self.planned($0.element, id: $0.offset) }
                .sorted { $0.option.expectedSeconds < $1.option.expectedSeconds }
            let failure = error.map(Self.failure)
            MainActor.assumeIsolated {
                guard let first = planned.first else {
                    completion(.failure(failure ?? .noRoute))
                    return
                }
                guard let engine = GuidanceEngine(route: first.route, session: session, generation: generation) else {
                    completion(.failure(.other("empty route")))
                    return
                }
                // Snapshots only come from later location callbacks, so storing the new
                // route first still lets the caller switch generation before any arrive.
                self.engine = engine
                self.candidates = planned
                self.selectedID = first.option.id
                self.routeIdentity = (session, generation)
                self.drawRoutes()
                completion(.success(()))
            }
        }
    }

    func startGuidance() {
        guiding = true
        drawRoutes()
        refreshFromLastFix(maxAge: 30)
        refresher?.cancel()
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshFromLastFix(maxAge: Self.quietFixValidity)
            }
        }
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.startUpdatingLocation()
        mapView.setUserTrackingMode(.followWithHeading, animated: true)
    }

    func stop() {
        guiding = false
        refresher?.cancel()
        refresher = nil
        directions?.cancel()
        directions = nil
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        if let engine {
            onSnapshot?(NavigationSnapshot(session: engine.session, generation: engine.generation,
                                           observedAt: clock.now, state: .stopped))
        }
        engine = nil
        destination = nil
        candidates = []
        routeIdentity = nil
        mapView.removeOverlays(overlays)
        overlays = []
        mapView.setUserTrackingMode(.none, animated: true)
    }

    // MARK: Conversion (runs on the MapKit callback; only Sendable values leave it)

    private struct Planned: Sendable {
        var route: PlannedRoute
        var line: [Coordinate]
        var option: RouteOption
    }

    nonisolated private static func planned(_ route: MKRoute, id: Int) -> Planned {
        let steps = route.steps.map { step in
            PlannedStep(points: coordinates(step.polyline), instructions: step.instructions)
        }
        let option = RouteOption(id: id, name: route.name, distanceMetres: route.distance,
                                 expectedSeconds: route.expectedTravelTime,
                                 hasTolls: route.hasTolls, hasHighways: route.hasHighways)
        return Planned(route: PlannedRoute(steps: steps, expectedTravelSeconds: route.expectedTravelTime),
                       line: coordinates(route.polyline), option: option)
    }

    nonisolated private static func coordinates(_ polyline: MKPolyline) -> [Coordinate] {
        var raw = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&raw, range: NSRange(location: 0, length: polyline.pointCount))
        return raw.compactMap { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    nonisolated private static func failure(_ error: Error) -> RouteRequestFailure {
        let nsError = error as NSError
        if nsError.domain == "MKLocationErrorDomain" { return .locationUnavailable }
        if nsError.domain == MKErrorDomain {
            switch MKError.Code(rawValue: UInt(nsError.code)) {
            case .loadingThrottled: return .throttled
            case .directionsNotFound: return .noRoute
            case .serverFailure: return .network
            default: return .other("MapKit \(nsError.code)")
            }
        }
        if nsError.domain == NSURLErrorDomain { return .network }
        if nsError.domain == kCLErrorDomain { return .locationUnavailable }
        return .other("\(nsError.domain) \(nsError.code)")
    }

    // MARK: Map

    /// Alternatives in grey under the selected route in blue; while guiding only the
    /// selected route is drawn. The overlay title carries the style to the renderer.
    private func drawRoutes() {
        mapView.removeOverlays(overlays)
        overlays = []
        let shown = guiding ? candidates.filter { $0.option.id == selectedID } : candidates
        let ordered = shown.filter { $0.option.id != selectedID } + shown.filter { $0.option.id == selectedID }
        for candidate in ordered {
            let coordinates = candidate.line.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let overlay = MKPolyline(coordinates: coordinates, count: coordinates.count)
            overlay.title = candidate.option.id == selectedID ? Self.selectedTitle : Self.alternativeTitle
            overlays.append(overlay)
        }
        mapView.addOverlays(overlays, level: .aboveRoads)
        Self.log.info("routes drawn shown=\(self.overlays.count) guiding=\(self.guiding) mapOverlays=\(self.mapView.overlays.count)")
    }

    private func showWholeRoute() {
        guard let first = overlays.first else { return }
        let rect = overlays.dropFirst().reduce(first.boundingMapRect) { $0.union($1.boundingMapRect) }
        mapView.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 120, right: 40), animated: true)
    }

    nonisolated static let selectedTitle = "selected"
    nonisolated static let alternativeTitle = "alternative"

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
        if let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude) {
            onLongPress?(coordinate)
        }
    }

    private func record(_ coordinate: CLLocationCoordinate2D, accuracy: Double) {
        guard accuracy >= 0 else { return }
        lastFix = (coordinate, accuracy, Date())
        if accuracy <= 100, !waitingForFix.isEmpty {
            let waiting = waitingForFix
            waitingForFix = []
            waiting.forEach { $0(coordinate) }
        }
    }

    private func refreshFromLastFix(maxAge: TimeInterval) {
        guard let fix = lastFix, Date().timeIntervalSince(fix.at) < maxAge,
              let coordinate = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        else { return }
        handle(LocationFix(coordinate: coordinate, horizontalAccuracy: fix.accuracy, observedAt: clock.now))
    }

    private func handle(_ fix: LocationFix) {
        guard guiding, let engine else { return }
        let update = engine.update(fix)
        onSnapshot?(update.snapshot)
        if update.requestReroute { onRerouteNeeded?() }
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        guard guiding, let engine, status == .denied || status == .restricted else { return }
        onSnapshot?(NavigationSnapshot(session: engine.session, generation: engine.generation,
                                       observedAt: clock.now, state: .failed(.locationPermissionDenied)))
    }
}

extension AppleNavigationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.compactMap { location -> (Coordinate, Double)? in
            Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                .map { ($0, location.horizontalAccuracy) }
        }
        MainActor.assumeIsolated {
            for (coordinate, accuracy) in fixes {
                record(CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                       accuracy: accuracy)
                handle(LocationFix(coordinate: coordinate, horizontalAccuracy: accuracy, observedAt: clock.now))
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { handleAuthorization(status) }
    }
}

extension AppleNavigationProvider: MKMapViewDelegate {
    nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        let renderer = MKPolylineRenderer(overlay: overlay)
        let selected = overlay.title == Self.selectedTitle
        renderer.strokeColor = selected ? .systemBlue : .systemGray
        renderer.alpha = selected ? 1 : 0.7
        renderer.lineWidth = selected ? 7 : 5
        return renderer
    }
}
