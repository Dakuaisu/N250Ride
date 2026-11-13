import Foundation
import RideCore
@testable import N250Ride

/// Replays a scripted ride through the production AppModel and the real
/// AppleNavigationProvider, with fake location and directions on virtual time.
/// Records safety-relevant effects as canonical text so runs can be compared.
@MainActor
final class AppReplayRunner {
    enum Event: Equatable {
        case confirm
        /// Sensor fix at metres east/north of the origin, measured `age` seconds ago.
        case fix(x: Double, y: Double, age: Double = 0)
        case routeOK
        case routeFails
        case start
        case reroute
        case automaticReroute
        case stop
        case advance(milliseconds: Int)
    }

    let timers = ManualRideTimers(clock: ManualClock(wallNow: Date(timeIntervalSince1970: 1_800_000_000)))
    let location = FakeLocation()
    let directions = FakeDirections()
    let provider: AppleNavigationProvider
    let model: AppModel
    let origin = Coordinate(latitude: 12.97, longitude: 77.59)!
    private(set) var log: [String] = []

    init() {
        let defaults = UserDefaults(suiteName: "AppReplay-\(UUID())")!
        provider = AppleNavigationProvider(clock: timers.clock, timers: timers, defaults: defaults,
                                           location: location, directions: directions)
        model = AppModel(configuration: AppConfiguration(navigationProvider: .apple, googleAPIKey: nil,
                                                         liveNavigationAuthorized: false, provenStatusProfile: nil),
                         defaults: defaults, provider: provider, dependencies: .virtual(timers))
        model.locationAuthorization = { .authorizedWhenInUse }
        model.acceptTerms()
    }

    func run(_ events: [Event]) -> [String] {
        for event in events {
            apply(event)
            log.append("\(event): \(stageName) health=\(model.health.directionEligible ? "go" : "paused") "
                       + "intent=\(intentName) queries=\(directions.queries.count) gen=\(model.guidance?.generation.value ?? -1)")
        }
        return log
    }

    private func apply(_ event: Event) {
        switch event {
        case .confirm:
            model.propose(FakeDirections.point(origin, x: -400, y: 500), label: "Office")
            model.confirmDestination(label: "Office", saveAsFavourite: false)
        case .fix(let x, let y, let age):
            location.deliver(FakeDirections.point(origin, x: x, y: y), age: age, clock: timers.clock)
        case .routeOK:
            directions.answer(.success([FakeDirections.route(from: origin)]))
        case .routeFails:
            directions.answer(.failure(.network))
        case .start:
            model.startNavigation()
        case .reroute:
            model.requestReroute(.manual)
        case .automaticReroute:
            provider.onRerouteNeeded?()
        case .stop:
            model.stopNavigation()
        case .advance(let ms):
            timers.advance(by: .milliseconds(ms))
        }
    }

    private var stageName: String {
        switch model.stage {
        case .choosing: "choosing"
        case .confirming: "confirming"
        case .requesting: "requesting"
        case .preview: "preview"
        case .navigating: "navigating"
        case .atStop: "atStop"
        case .failed: "failed"
        }
    }

    private var intentName: String {
        switch model.intent {
        case .guidance(let fields, _): "icon\(fields.icon)/\(fields.stepMetres)m"
        case .clear(let reason): "clear(\(reason))"
        }
    }
}
