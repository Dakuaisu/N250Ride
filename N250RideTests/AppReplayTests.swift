import Foundation
import RideCore
import Testing
@testable import N250Ride

@MainActor
struct AppReplayTests {
    typealias E = AppReplayRunner.Event

    static let ride: [E] = [
        .fix(x: 0, y: 0), .confirm, .routeOK, .start,
        .advance(milliseconds: 1_000), .fix(x: 0, y: 20),
        .advance(milliseconds: 1_000), .fix(x: 0, y: 40),
        .advance(milliseconds: 4_999),
        .advance(milliseconds: 1),
        .fix(x: 0, y: 60, age: 6),
        .advance(milliseconds: 500), .fix(x: 0, y: 80),
        .stop,
    ]

    @Test func genuineFixesDriveTheDashboardAndExpire() {
        let log = AppReplayRunner().run(Self.ride)
        #expect(log[3].hasPrefix("start: navigating health=go intent=icon73/"), "the last fresh fix guides at once")
        #expect(log[8].contains("health=go"), "4.999 s after the last fix")
        #expect(log[9].contains("health=paused intent=clear(stale)"), "5 s after it, with no new fix")
        #expect(log[10].contains("health=paused"), "a 6 s old cached fix is not evidence")
        #expect(log[12].contains("health=go"), "a genuine new fix restores guidance")
        #expect(log[13].hasPrefix("stop: choosing health=paused intent=clear(noSession)"))
        #expect(log.allSatisfy { !$0.contains("queries=2") }, "one route request for the whole ride")
    }

    @Test func lateRouteAfterStopChangesNothing() {
        let runner = AppReplayRunner()
        let log = runner.run([.fix(x: 0, y: 0), .confirm, .stop, .routeOK, .advance(milliseconds: 60_000)])
        #expect(log.last?.hasPrefix("advance(milliseconds: 60000): choosing") == true)
        #expect(runner.directions.cancels >= 1 && runner.model.routeOptions.isEmpty)
    }

    @Test func manualAndAutomaticRerouteMakeOneRequest() {
        let runner = AppReplayRunner()
        let log = runner.run([.fix(x: 0, y: 0), .confirm, .routeOK, .start, .advance(milliseconds: 3_000),
                              .fix(x: 0, y: 30), .reroute, .automaticReroute, .reroute, .routeOK,
                              .advance(milliseconds: 500), .fix(x: 0, y: 40)])
        #expect(runner.directions.queries.count == 2)
        #expect(log.last?.contains("gen=1") == true, "the committed reroute is generation 1")
    }

    @Test func failedRerouteKeepsGuidingOnTheOldRoute() {
        let runner = AppReplayRunner()
        let log = runner.run([.fix(x: 0, y: 0), .confirm, .routeOK, .start, .advance(milliseconds: 3_000),
                              .fix(x: 0, y: 30), .reroute, .routeFails, .advance(milliseconds: 500), .fix(x: 0, y: 40)])
        #expect(log.last?.contains("navigating health=go") == true && log.last?.contains("gen=0") == true)
        #expect(runner.model.routeOperation == .failed(.manual, RouteRequestFailure.network.message))
    }

    @Test func replayIsDeterministic() {
        let first = AppReplayRunner().run(Self.ride)
        for _ in 0..<100 { #expect(AppReplayRunner().run(Self.ride) == first) }
    }
}
