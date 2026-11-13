import Foundation
import RideCore
@testable import N250Ride

@MainActor
final class FakeLocation: LocationClient {
    var onSamples: (([LocationSample]) -> Void)?
    var onAuthorizationDenied: (() -> Void)?
    private(set) var isRunning = false
    private(set) var starts = 0

    func start(background: Bool) {
        if !isRunning { starts += 1 }
        isRunning = true
    }

    func stop() { isRunning = false }

    /// A sample measured `age` seconds before the clock's current wall time.
    func deliver(_ coordinate: Coordinate, accuracy: Double = 5, age: TimeInterval = 0, clock: RideClock) {
        onSamples?([LocationSample(coordinate: coordinate, horizontalAccuracy: accuracy,
                                   timestamp: clock.wallNow.addingTimeInterval(-age))])
    }
}

@MainActor
final class FakeDirections: DirectionsClient {
    private(set) var queries: [DirectionsQuery] = []
    private(set) var cancels = 0
    private var completion: ((Result<[PlannedCandidate], RouteRequestFailure>) -> Void)?

    func calculate(_ query: DirectionsQuery,
                   completion: @escaping @MainActor (Result<[PlannedCandidate], RouteRequestFailure>) -> Void) {
        queries.append(query)
        self.completion = completion
    }

    func cancel() {
        cancels += 1
        completion = nil
    }

    var isWaiting: Bool { completion != nil }

    func answer(_ result: Result<[PlannedCandidate], RouteRequestFailure>) {
        let done = completion
        completion = nil
        done?(result)
    }

    /// A straight 1.3 km route north, then a left turn: enough for real guidance.
    static func route(from origin: Coordinate) -> PlannedCandidate {
        func at(_ x: Double, _ y: Double) -> Coordinate {
            Coordinate(latitude: origin.latitude + y / 110_574,
                       longitude: origin.longitude + x / (cos(origin.latitude * .pi / 180) * 111_320))!
        }
        let steps = [
            PlannedStep(points: [at(0, 0)], instructions: ""),
            PlannedStep(points: [at(0, 0), at(0, 500)], instructions: "Turn left onto First Cross"),
            PlannedStep(points: [at(0, 500), at(-400, 500)], instructions: "Arrive at the destination"),
        ]
        let line = [at(0, 0), at(0, 500), at(-400, 500)]
        return PlannedCandidate(route: PlannedRoute(steps: steps, expectedTravelSeconds: 120), line: line,
                                option: RouteOption(id: 0, name: "Test Road", distanceMetres: 900, expectedSeconds: 120,
                                                    hasTolls: false, hasHighways: false))
    }

    static func point(_ origin: Coordinate, x: Double, y: Double) -> Coordinate {
        Coordinate(latitude: origin.latitude + y / 110_574,
                   longitude: origin.longitude + x / (cos(origin.latitude * .pi / 180) * 111_320))!
    }
}
