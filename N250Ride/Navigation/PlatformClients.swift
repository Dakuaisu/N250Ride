import CoreLocation
import MapKit
import RideCore

/// Location samples and authorisation, separated from `CLLocationManager` so the
/// provider's own logic runs unchanged against scripted samples in tests.
@MainActor
protocol LocationClient: AnyObject {
    var onSamples: (([LocationSample]) -> Void)? { get set }
    var onAuthorizationDenied: (() -> Void)? { get set }
    var isRunning: Bool { get }
    func start(background: Bool)
    func stop()
}

/// What MapKit is asked for. Converted to `MKDirections.Request` by the real client.
struct DirectionsQuery: Sendable, Equatable {
    var origin: Coordinate
    var destination: Coordinate
    var avoidTolls: Bool
    var avoidHighways: Bool
    var alternatives: Bool
}

/// A route candidate as plain values: MapKit objects never leave the client.
struct PlannedCandidate: Sendable {
    var route: PlannedRoute
    var line: [Coordinate]
    var option: RouteOption
}

@MainActor
protocol DirectionsClient: AnyObject {
    /// At most one calculation at a time; a new one cancels the previous.
    func calculate(_ query: DirectionsQuery,
                   completion: @escaping @MainActor (Result<[PlannedCandidate], RouteRequestFailure>) -> Void)
    func cancel()
}

@MainActor
final class CoreLocationClient: NSObject, LocationClient, CLLocationManagerDelegate {
    var onSamples: (([LocationSample]) -> Void)?
    var onAuthorizationDenied: (() -> Void)?
    private(set) var isRunning = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start(background: Bool) {
        manager.allowsBackgroundLocationUpdates = background
        manager.showsBackgroundLocationIndicator = background
        guard !isRunning else { return }
        isRunning = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.allowsBackgroundLocationUpdates = false
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let samples = locations.compactMap { location in
            Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude).map {
                LocationSample(coordinate: $0, horizontalAccuracy: location.horizontalAccuracy, timestamp: location.timestamp)
            }
        }
        MainActor.assumeIsolated { onSamples?(samples) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if status == .denied || status == .restricted { onAuthorizationDenied?() }
        }
    }
}

@MainActor
final class MapKitDirectionsClient: DirectionsClient {
    private var directions: MKDirections?
    private var generation = 0

    func calculate(_ query: DirectionsQuery,
                   completion: @escaping @MainActor (Result<[PlannedCandidate], RouteRequestFailure>) -> Void) {
        cancel()
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: Self.location(query.origin)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: Self.location(query.destination)))
        request.transportType = .automobile
        request.tollPreference = query.avoidTolls ? .avoid : .any
        request.highwayPreference = query.avoidHighways ? .avoid : .any
        request.requestsAlternateRoutes = query.alternatives
        let directions = MKDirections(request: request)
        self.directions = directions
        generation += 1
        let mine = generation
        directions.calculate { response, error in
            let planned = (response?.routes ?? []).prefix(3).enumerated().map { Self.planned($0.element, id: $0.offset) }
                .sorted { $0.option.expectedSeconds < $1.option.expectedSeconds }
            let failure = error.map(Self.failure)
            MainActor.assumeIsolated {
                guard mine == self.generation else { return }
                self.directions = nil
                if planned.isEmpty {
                    completion(.failure(failure ?? .noRoute))
                } else {
                    completion(.success(planned))
                }
            }
        }
    }

    func cancel() {
        generation += 1
        directions?.cancel()
        directions = nil
    }

    private static func location(_ c: Coordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    nonisolated private static func planned(_ route: MKRoute, id: Int) -> PlannedCandidate {
        let steps = route.steps.map { PlannedStep(points: coordinates($0.polyline), instructions: $0.instructions) }
        let option = RouteOption(id: id, name: route.name, distanceMetres: route.distance,
                                 expectedSeconds: route.expectedTravelTime,
                                 hasTolls: route.hasTolls, hasHighways: route.hasHighways)
        return PlannedCandidate(route: PlannedRoute(steps: steps, expectedTravelSeconds: route.expectedTravelTime),
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
        if nsError.domain == NSURLErrorDomain {
            return nsError.code == NSURLErrorCancelled ? .cancelled : .network
        }
        if nsError.domain == kCLErrorDomain { return .locationUnavailable }
        return .other("\(nsError.domain) \(nsError.code)")
    }
}
