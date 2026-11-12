import Foundation
import Testing
@testable import RideCore

@Suite("Diagnostics privacy")
struct DiagnosticsTests {
    let sentinelKey = "AIzaSy-SENTINEL-KEY-0000"
    let sentinelRoad = "Sentinel Secret Road"
    let sentinelLatitude = "12.345678"

    @Test func exportContainsNoKeyCoordinatesOrRoadText() throws {
        let clock = ManualClock()
        var log = DiagnosticsLog()
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(clock: clock)
        coordinator.onIntentChange = { log.record(.dashboard(.init($0)), at: clock.now) }
        coordinator.beginSession(SessionID())
        coordinator.linkReady(ClusterWritePump(transport: transport, clock: clock, link: responseLink))
        let destination = try #require(Coordinate(latitude: 12.345678, longitude: 77.654321))
        coordinator.receive(NavigationSnapshot(
            session: coordinator.session!, generation: coordinator.generation, observedAt: clock.now, state: .active,
            step: GuidanceStep(maneuver: .turnLeft, distanceMetres: 300, roadText: sentinelRoad),
            remainingMetres: 4_000, remainingSeconds: 600))
        log.record(.navigationState(.failed(.routeUnavailable("\(sentinelRoad) \(destination.latitude)"))), at: clock.now)
        log.record(.navigationState(.failed(.providerDisabled(sentinelKey))), at: clock.now)
        log.record(.link(.init(.ready(responseLink))), at: clock.now)
        log.record(.routeRequest(.init(.providerDisabled(sentinelKey))), at: clock.now)
        log.record(.appLaunched(live: false), at: clock.now)

        let text = log.export(appVersion: "1.0 (1)", sdkVersion: nil, osVersion: "iOS 18.0")
        #expect(!text.contains(sentinelKey))
        #expect(!text.contains(sentinelRoad))
        #expect(!text.contains("Sentinel"))
        #expect(!text.contains(sentinelLatitude))
        #expect(!text.contains("77.65"))
        #expect(text.contains("dashboard guidance"))
        #expect(text.contains("navigation failed.routeUnavailable"))
        #expect(text.contains("count dashboard"))
    }

    @Test func boundedAndDeduplicated() {
        var log = DiagnosticsLog(capacity: 3)
        let t = MonotonicInstant(offset: .zero)
        log.record(.link(.scanning), at: t)
        log.record(.link(.scanning), at: t)
        #expect(log.entries.count == 1)
        for state in [DiagnosticsLog.LinkSummary.connecting, .discovering, .ready, .idle] {
            log.record(.link(state), at: t)
        }
        #expect(log.entries.map(\.event) == [.link(.discovering), .link(.ready), .link(.idle)])
        log.removeAll()
        #expect(log.entries.isEmpty)
    }
}
