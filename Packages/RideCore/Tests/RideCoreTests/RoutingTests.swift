import Foundation
import Testing
@testable import RideCore

@Suite("Route request gate")
struct RouteRequestGateTests {
    let ist = TimeZone(identifier: "Asia/Kolkata")!

    func clock(_ iso: String) -> ManualClock {
        ManualClock(wallNow: ISO8601DateFormatter().date(from: iso)!)
    }

    func gate(_ policy: RouteRequestPolicy, clock: ManualClock, store: InMemoryUsageCounterStore = .init()) -> RouteRequestGate {
        RouteRequestGate(policy: policy, store: store, clock: clock, timeZone: ist)
    }

    @Test func disabledProviderNeverAuthorizes() {
        let store = InMemoryUsageCounterStore()
        let g = gate(.disabled(reason: "GATE-1 open"), clock: clock("2026-11-11T04:00:00Z"), store: store)
        #expect(g.authorize(destinationCount: 1) == .failure(.providerDisabled("GATE-1 open")))
        #expect(store.saved == nil)
    }

    @Test func countsBeforeDispatchAndCoalescesRepeatedStarts() throws {
        let c = clock("2026-11-11T04:00:00Z")
        let store = InMemoryUsageCounterStore()
        let g = gate(.metered(RouteRequestLimits()), clock: c, store: store)
        let ticket = try g.authorize(destinationCount: 1).get()
        #expect(store.saved?.dayCount == 1)
        #expect(g.authorize(destinationCount: 1) == .failure(.requestInFlight))
        #expect(g.authorize(destinationCount: 1) == .failure(.requestInFlight))
        g.finish(ticket)
        #expect(g.authorize(destinationCount: 1) == .failure(.tooSoon))
        c.advance(by: .seconds(2))
        #expect(g.authorize(destinationCount: 3).isSuccess)
        #expect(g.usage.dayCount == 4, "multi-waypoint counts each destination")
        #expect(g.usage.monthCount == 4)
    }

    @Test func failedRequestsAreNotRefundedOrRetried() throws {
        let c = clock("2026-11-11T04:00:00Z")
        let g = gate(.metered(RouteRequestLimits()), clock: c)
        let ticket = try g.authorize(destinationCount: 1).get()
        g.finish(ticket)
        #expect(g.usage.dayCount == 1)
        #expect(g.inFlight == nil)
    }

    @Test func dailyAndMonthlyLimitsRejectBeforeDispatch() throws {
        let c = clock("2026-11-11T04:00:00Z")
        let store = InMemoryUsageCounterStore(UsageCounters(dayKey: "2026-11-11", dayCount: 19, monthKey: "2026-11", monthCount: 100))
        let g = gate(.metered(RouteRequestLimits()), clock: c, store: store)
        #expect(g.authorize(destinationCount: 2) == .failure(.dailyLimitReached(limit: 20)))
        let ticket = try g.authorize(destinationCount: 1).get()
        g.finish(ticket)
        c.advance(by: .seconds(3))
        #expect(g.authorize(destinationCount: 1) == .failure(.dailyLimitReached(limit: 20)))

        let monthStore = InMemoryUsageCounterStore(UsageCounters(dayKey: "2026-11-11", dayCount: 0, monthKey: "2026-11", monthCount: 600))
        let g2 = gate(.metered(RouteRequestLimits()), clock: c, store: monthStore)
        #expect(g2.authorize(destinationCount: 1) == .failure(.monthlyLimitReached(limit: 600)))
    }

    @Test func dayAndMonthRollOverInConfiguredTimeZone() throws {
        // 2026-11-30 23:59 IST
        let c = clock("2026-11-30T18:29:00Z")
        let store = InMemoryUsageCounterStore(UsageCounters(dayKey: "2026-11-30", dayCount: 20, monthKey: "2026-11", monthCount: 600))
        let g = gate(.metered(RouteRequestLimits()), clock: c, store: store)
        #expect(g.authorize(destinationCount: 1) == .failure(.dailyLimitReached(limit: 20)))
        c.advance(by: .seconds(60))
        let ticket = try g.authorize(destinationCount: 1).get()
        g.finish(ticket)
        #expect(store.saved == UsageCounters(dayKey: "2026-12-01", dayCount: 1, monthKey: "2026-12", monthCount: 1))
        let usage = g.usage
        #expect(usage.dayResetsAt == ISO8601DateFormatter().date(from: "2026-12-01T18:30:00Z"))
        #expect(usage.monthResetsAt == ISO8601DateFormatter().date(from: "2026-12-31T18:30:00Z"))
    }

    @Test func unmeteredFallbackStillSerialisesButDoesNotCount() throws {
        let store = InMemoryUsageCounterStore()
        let g = gate(.unmetered, clock: clock("2026-11-11T04:00:00Z"), store: store)
        _ = try g.authorize(destinationCount: 1).get()
        #expect(g.authorize(destinationCount: 1) == .failure(.requestInFlight))
        #expect(store.saved == nil)
        #expect(g.usage.limits == nil)
    }

    @Test func rejectsEmptyRequests() {
        let g = gate(.metered(RouteRequestLimits()), clock: clock("2026-11-11T04:00:00Z"))
        #expect(g.authorize(destinationCount: 0) == .failure(.invalidDestinationCount))
    }
}

@Suite("Destination input")
struct DestinationInputTests {
    @Test func parsesLatLng() throws {
        let c = try DestinationInputParser.parse(" 12.9716, 77.5946 ").get()
        #expect(c.latitude == 12.9716 && c.longitude == 77.5946)
        #expect(try DestinationInputParser.parse("-33.8688,151.2093").get().latitude == -33.8688)
    }

    @Test(arguments: [
        ("", DestinationParseError.empty),
        ("12.97", .malformed),
        ("12.97,77.59,1", .malformed),
        ("north,east", .malformed),
        ("1e1,2", .malformed),
        ("nan,77", .malformed),
        ("91,77", .latitudeOutOfRange),
        ("-90.0001,0", .latitudeOutOfRange),
        ("12,180.5", .longitudeOutOfRange),
        ("7JCJ+8J", .shortPlusCode),
        ("7JCJ+8J Bengaluru", .invalidPlusCode),
        ("8FWC2345+G", .invalidPlusCode),
        ("8FWC2_45+G6", .invalidPlusCode),
    ])
    func rejectsBadInput(input: String, expected: DestinationParseError) {
        #expect(DestinationInputParser.parse(input) == .failure(expected))
    }

    @Test func decodesFullPlusCodeToCentre() throws {
        let c = try DestinationInputParser.parse("7J4VWHC2+VG").get()
        let area = try #require(OpenLocationCode.decode("7J4VWHC2+VG"))
        #expect(c.latitude == area.centerLatitude && c.longitude == area.centerLongitude)
        #expect(area.latitudeLo < c.latitude && c.latitude < area.latitudeHi)
    }

    static func csv(_ name: String) -> [[String]] {
        let url = Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "olc")!
        return try! String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    @Test func matchesReferenceValidityTable() {
        let rows = Self.csv("validityTests")
        #expect(rows.count == 25)
        for row in rows {
            #expect(OpenLocationCode.isValid(row[0]) == (row[1] == "true"), "\(row[0]) valid")
            #expect(OpenLocationCode.isShort(row[0]) == (row[2] == "true"), "\(row[0]) short")
            #expect(OpenLocationCode.isFull(row[0]) == (row[3] == "true"), "\(row[0]) full")
        }
    }

    @Test func matchesReferenceDecodingTable() throws {
        let rows = Self.csv("decoding")
        #expect(rows.count == 420)
        let tolerance = 1e-10
        for row in rows {
            let area = try #require(OpenLocationCode.decode(row[0]), "\(row[0])")
            #expect(area.length == Int(row[1]), "\(row[0]) length")
            #expect(abs(area.latitudeLo - Double(row[2])!) < tolerance, "\(row[0]) latLo")
            #expect(abs(area.longitudeLo - Double(row[3])!) < tolerance, "\(row[0]) lngLo")
            #expect(abs(area.latitudeHi - Double(row[4])!) < tolerance, "\(row[0]) latHi")
            #expect(abs(area.longitudeHi - Double(row[5])!) < tolerance, "\(row[0]) lngHi")
        }
    }

    @Test func favouritesSaveRenameDelete() throws {
        var list = FavouritesList()
        let home = try #require(Coordinate(latitude: 12.97, longitude: 77.59))
        let saved = list.add(label: "  Home  ", coordinate: home)
        #expect(saved.label == "Home")
        let unnamed = list.add(label: "", coordinate: home)
        #expect(unnamed.label == "12.97000, 77.59000")
        list.rename(saved.id, to: String(repeating: "x", count: 100))
        #expect(list.items[0].label.count == FavouritesList.maxLabelLength)
        list.delete(unnamed.id)
        #expect(list.items.map(\.id) == [saved.id])
        let roundTrip = try JSONDecoder().decode(FavouritesList.self, from: JSONEncoder().encode(list))
        #expect(roundTrip == list)
    }
}

@Suite("Fixture replay")
struct FixtureReplayTests {
    @Test func replayDrivesDashboardFromPreviewToStop() throws {
        let clock = ManualClock()
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(clock: clock, configuration: SessionConfiguration(timeZone: TimeZone(identifier: "UTC")!))
        let source = FixtureNavigationSource(route: .demo, clock: clock)
        var states: [NavigationState] = []
        source.onSnapshot = {
            states.append($0.state)
            coordinator.receive($0)
        }
        let session = SessionID()
        coordinator.beginSession(session)
        coordinator.linkReady(ClusterWritePump(
            transport: transport, clock: clock,
            link: ClusterLinkInfo(navigationWriteMode: .withoutResponse, statusWriteMode: nil, maximumWriteLength: 182)))
        source.preview(session: session, generation: coordinator.generation)
        source.start()

        var seconds = 0
        while !states.contains(.arrived), seconds < 600 {
            clock.advance(by: .seconds(1))
            source.tick()
            coordinator.tick()
            seconds += 1
        }
        source.stop()

        #expect(states.first == .preview)
        #expect(states.contains(.active))
        #expect(states.suffix(2) == [.arrived, .stopped])
        let icons = Set(transport.navigationWrites.compactMap { TbtFrameSummary(frame: $0)?.icon })
        for expected in [ClusterIcon.turnLeft, ClusterIcon.turnRight, ClusterIcon.roundaboutLeft,
                         ClusterIcon.turnLeft + 32, ClusterIcon.destinationReached] {
            #expect(icons.contains(expected), "icon \(expected)")
        }
        #expect(transport.navigationWrites.first == TbtFrame.stop())
        #expect(transport.navigationWrites.last == TbtFrame.stop())
        let exits = transport.navigationWrites.compactMap { TbtFrameSummary(frame: $0) }
            .filter { $0.icon == ClusterIcon.roundaboutLeft }.map(\.roundaboutExit)
        #expect(Set(exits) == [4], "straight ahead on a clockwise roundabout")
    }
}
