import Foundation
import RideCore
import Testing
@testable import N250Ride

/// The real Apple provider, on virtual time, with scripted locations and directions.
@MainActor
struct AppleProviderAdapterTests {
    let timers = ManualRideTimers(clock: ManualClock())
    let location = FakeLocation()
    let directions = FakeDirections()
    let provider: AppleNavigationProvider
    let origin = Coordinate(latitude: 12.97, longitude: 77.59)!
    let target = Coordinate(latitude: 12.9745, longitude: 77.5863)!

    init() {
        provider = AppleNavigationProvider(clock: timers.clock, timers: timers,
                                           defaults: UserDefaults(suiteName: "adapter-\(UUID())")!,
                                           location: location, directions: directions)
    }

    func request(_ reason: RouteReason = .initial, session: SessionID = SessionID(),
                 generation: RouteGeneration = RouteGeneration(0), fix: FixRequirement = .initial) -> NavigationRouteRequest {
        NavigationRouteRequest(operationID: UUID(), session: session, generation: generation, target: target,
                               title: "Office", preferences: RoutePreferences(), reason: reason,
                               alternatives: reason == .initial, fix: fix)
    }

    @Test func untrustworthyFixesNeverStartARequest() {
        var results: [Result<PreparedRoute, RouteRequestFailure>] = []
        provider.prepareRoute(request(fix: .current)) { results.append($0) }
        #expect(location.isRunning)
        location.deliver(origin, age: 6, clock: timers.clock)
        location.deliver(origin, age: -3, clock: timers.clock)
        location.deliver(origin, accuracy: 80, age: 1, clock: timers.clock)
        #expect(directions.queries.isEmpty, "cached, future and imprecise fixes are not an origin")
        location.deliver(origin, age: 0.5, clock: timers.clock)
        location.deliver(origin, age: 1, clock: timers.clock)
        #expect(directions.queries.count == 1)
        #expect(directions.queries[0].origin == origin)
    }

    @Test func fixWaitTimesOutAndReleasesLocation() {
        var results: [Result<PreparedRoute, RouteRequestFailure>] = []
        provider.prepareRoute(request(fix: .current)) { results.append($0) }
        timers.advance(by: .milliseconds(14_999))
        #expect(results.isEmpty)
        timers.advance(by: .milliseconds(1))
        #expect(results.count == 1 && (try? results[0].get()) == nil)
        #expect(!location.isRunning, "a failed initial request does not leave GPS running")
    }

    @Test func oldTimeoutCannotDrainANewerWait() {
        var first: [Result<PreparedRoute, RouteRequestFailure>] = []
        var second: [Result<PreparedRoute, RouteRequestFailure>] = []
        provider.prepareRoute(request(fix: .current)) { first.append($0) }
        timers.advance(by: .seconds(10))
        provider.prepareRoute(request(fix: .current)) { second.append($0) }
        timers.advance(by: .seconds(6))
        #expect(first.isEmpty, "the replaced request answers nothing")
        #expect(second.isEmpty, "the first wait's timeout did not end the second")
        location.deliver(origin, clock: timers.clock)
        #expect(directions.queries.count == 1)
    }

    @Test func preparationNeverDisturbsTheActiveRoute() throws {
        var snapshots: [NavigationSnapshot] = []
        provider.onSnapshot = { snapshots.append($0) }
        let sessionA = SessionID()
        var prepared: PreparedRoute?
        location.deliver(origin, clock: timers.clock)
        provider.prepareRoute(request(session: sessionA)) { prepared = try? $0.get() }
        directions.answer(.success([FakeDirections.route(from: origin)]))
        let a = try #require(prepared)
        #expect(snapshots.isEmpty, "preparing emits nothing")
        #expect(provider.commitPreparedRoute(a.handle, option: 0))
        #expect(snapshots.isEmpty, "committing emits nothing")
        provider.startGuidance()
        #expect(snapshots.last?.session == sessionA, "the last fresh fix is guided on the committed route")

        var failed: Result<PreparedRoute, RouteRequestFailure>?
        provider.prepareRoute(request(.manual, session: sessionA, generation: RouteGeneration(1), fix: .current)) { failed = $0 }
        timers.advance(by: .seconds(1))
        location.deliver(FakeDirections.point(origin, x: 0, y: 100), clock: timers.clock)
        directions.answer(.failure(.network))
        #expect(failed.map { if case .failure(.network) = $0 { true } else { false } } == true)
        timers.advance(by: .seconds(1))
        location.deliver(FakeDirections.point(origin, x: 0, y: 150), clock: timers.clock)
        let latest = try #require(snapshots.last)
        #expect(latest.session == sessionA && latest.generation == RouteGeneration(0) && latest.state == .active,
                "route A keeps guiding after B failed")
        #expect(latest.measurementAt == timers.clock.now)
    }

    @Test func cancelledAnswerIsIgnored() {
        var results: [Result<PreparedRoute, RouteRequestFailure>] = []
        let r = request()
        location.deliver(origin, clock: timers.clock)
        provider.prepareRoute(r) { results.append($0) }
        provider.cancelPreparation(r.operationID)
        directions.answer(.success([FakeDirections.route(from: origin)]))
        #expect(results.isEmpty && directions.cancels == 1)
    }

    @Test func startCheckNeedsACurrentPositionNearTheStart() throws {
        var prepared: PreparedRoute?
        location.deliver(origin, clock: timers.clock)
        provider.prepareRoute(request()) { prepared = try? $0.get() }
        directions.answer(.success([FakeDirections.route(from: origin)]))
        let handle = try #require(prepared).handle
        var checks: [StartCheck] = []
        timers.advance(by: .seconds(20))
        provider.checkStart(handle) { checks.append($0) }
        #expect(checks.isEmpty, "the 20 s old fix is not current")
        location.deliver(FakeDirections.point(origin, x: 0, y: 300), clock: timers.clock)
        guard case .movedFromOrigin(let metres) = checks.first else {
            Issue.record("expected a displacement, got \(checks)")
            return
        }
        #expect(abs(metres - 300) < 5)
        timers.advance(by: .seconds(6))
        provider.checkStart(handle) { checks.append($0) }
        location.deliver(FakeDirections.point(origin, x: 0, y: 40), clock: timers.clock)
        #expect(checks.last == .ready)
    }
}
