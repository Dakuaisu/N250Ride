import Foundation
import Testing
@testable import RideCore

/// Synthetic geometry in metres east (x) / north (y) of a fixed origin.
private let origin = (lat: 12.97, lng: 77.59)

func at(_ x: Double, _ y: Double) -> Coordinate {
    Coordinate(latitude: origin.lat + y / 110_574,
               longitude: origin.lng + x / (cos(origin.lat * .pi / 180) * 111_320))!
}

/// North 500 m, right (east) 400 m, left (north) 400 m, arrive. Shaped like a real
/// MapKit route: a zero-length first step, and each instruction describing the
/// maneuver at the end of its step's line.
let cityRoute = PlannedRoute(steps: [
    PlannedStep(points: [at(0, 0)], instructions: ""),
    PlannedStep(points: [at(0, 0), at(0, 250), at(0, 500)], instructions: "Turn right onto First Cross"),
    PlannedStep(points: [at(0, 500), at(400, 500)], instructions: "Turn left onto Second Main"),
    PlannedStep(points: [at(400, 500), at(400, 900)], instructions: "Arrive at the destination"),
], expectedTravelSeconds: 260)

@Suite("Maneuver classifier")
struct ManeuverClassifierTests {
    typealias G = ManeuverClassifier.Geometry

    func classify(_ text: String, near: Double?, far: Double? = nil, side: DrivingSide = .left)
        -> (Maneuver, RoundaboutDirection?) {
        ManeuverClassifier.classify(ManeuverClassifier.cues(text), G(near: near, far: far), drivingSide: side)
    }

    @Test func readsEnglishCues() {
        #expect(ManeuverClassifier.cues("Turn right onto Left Bank Road") == .init(kind: .turn, side: .right))
        #expect(ManeuverClassifier.cues("Keep left at the fork") == .init(kind: .keep, side: .left))
        #expect(ManeuverClassifier.cues("At the roundabout, take the 2nd exit onto MG Road").kind == .roundabout)
        #expect(ManeuverClassifier.cues("Make a U-turn").kind == .uTurn)
        #expect(ManeuverClassifier.cues("The destination is on your left").kind == .arrive)
        #expect(ManeuverClassifier.cues("Take exit 4 toward Hosur").kind == .ramp)
        #expect(ManeuverClassifier.cues("Gire à direita").kind == nil)
    }

    @Test func geometryAndTextAgree() {
        #expect(classify("Turn right onto X", near: 88).0 == .turnRight)
        #expect(classify("Turn left onto X", near: -92).0 == .turnLeft)
        #expect(classify("Turn left onto X", near: -140).0 == .sharpLeft)
        #expect(classify("Bear right", near: 25).0 == .slightRight)
        #expect(classify("Keep left", near: -5).0 == .keepLeft)
        #expect(classify("Continue onto X", near: 8).0 == .straight)
    }

    /// Real Silk Board route (2026-11-12): "Keep right onto Outer Ring Road" where the road bends 35 degrees left.
    @Test func forkTextSideWinsOverRoadBend() {
        #expect(classify("Keep right onto Outer Ring Road", near: -35, far: -35).0 == .keepRight)
        #expect(classify("Take exit 2 on the left", near: 20).0 == .rampLeft)
        #expect(classify("Turn right onto X", near: -35).0 == .unsupported, "turns still need agreement")
    }

    @Test func conflictsAreSuppressed() {
        #expect(classify("Turn left onto X", near: 90).0 == .unsupported)
        #expect(classify("Continue onto X", near: 80).0 == .unsupported)
        #expect(classify("Turn onto X", near: 3).0 == .unsupported)
        #expect(classify("Keep onto X", near: 2).0 == .unsupported)
    }

    @Test func doubleBendsAreSuppressed() {
        #expect(classify("Turn left", near: -40, far: 20).0 == .unsupported)
        #expect(classify("", near: -40, far: -5).0 == .unsupported, "no text: unlabelled roundabout-like bend")
        #expect(classify("", near: -85, far: -80).0 == .turnLeft)
        #expect(classify("Gire", near: 30, far: 28).0 == .slightRight)
    }

    @Test func roundaboutDirectionFromFarAngle() {
        #expect(classify("At the roundabout, take the 2nd exit", near: -40, far: 4) == (.roundaboutClockwise, .straight))
        #expect(classify("At the roundabout, take the 3rd exit", near: -40, far: 95) == (.roundaboutClockwise, .right))
        #expect(classify("At the roundabout, take the 1st exit", near: -40, far: -70) == (.roundaboutClockwise, .left))
        #expect(classify("At the roundabout, take the exit", near: 20, far: -130, side: .right)
            == (.roundaboutCounterClockwise, .sharpLeft))
        #expect(classify("At the roundabout, take the exit", near: -40, far: nil).0 == .unsupported)
    }

    @Test func uTurnSideFollowsTrafficSide() {
        #expect(classify("Make a U-turn", near: 178).0 == .uTurnRight)
        #expect(classify("Make a U-turn", near: 178, side: .right).0 == .uTurnLeft)
        #expect(classify("Make a U-turn to the left", near: 178).0 == .uTurnLeft)
    }
}

@Suite("Guidance engine")
struct GuidanceEngineTests {
    let session = SessionID()
    var engine: GuidanceEngine { GuidanceEngine(route: cityRoute, session: session, generation: RouteGeneration(3))! }

    func fix(_ x: Double, _ y: Double, accuracy: Double = 5, t: Int) -> LocationFix {
        LocationFix(coordinate: at(x, y), horizontalAccuracy: accuracy,
                    observedAt: MonotonicInstant(offset: .seconds(t)))
    }

    @Test func plansManeuversFromGeometryAndText() {
        let e = engine
        #expect(e.maneuvers.map(\.maneuver) == [.turnRight, .turnLeft, .arrival])
        #expect(e.maneuvers.map { Int($0.along.rounded()) } == [500, 900, 1300])
        #expect(e.maneuvers.map(\.road) == ["First Cross", "Second Main", nil])
        #expect(abs(e.totalMetres - 1300) < 1)
    }

    @Test func tracksProgressStepAndEta() throws {
        let e = engine
        let s = e.update(fix(6, 200, t: 1)).snapshot
        #expect(s.state == .active)
        #expect(s.generation == RouteGeneration(3))
        let step = try #require(s.step)
        #expect(step.maneuver == .turnRight && step.distanceMetres == 300 && step.roadText == "First Cross")
        #expect(s.remainingMetres == 1100)
        #expect(s.remainingSeconds == 220)

        let after = e.update(fix(120, 497, t: 30)).snapshot
        #expect(after.step?.maneuver == .turnLeft)
        #expect(after.step?.distanceMetres == 280)
    }

    @Test func progressNeverRunsBackwards() {
        let e = engine
        _ = e.update(fix(0, 300, t: 1))
        let back = e.update(fix(0, 280, t: 2)).snapshot
        #expect(back.step?.distanceMetres == 200)
    }

    @Test func leavingTheRouteRequestsThrottledReroute() {
        let e = engine
        _ = e.update(fix(0, 200, t: 0))
        #expect(e.update(fix(100, 250, t: 1)).snapshot.state == .active)
        #expect(e.update(fix(100, 260, t: 2)).requestReroute == false)
        let third = e.update(fix(100, 270, t: 3))
        #expect(third.snapshot.state == .rerouting && third.requestReroute)
        #expect(e.update(fix(110, 280, t: 4)).requestReroute == false)
        #expect(e.update(fix(110, 290, t: 17)).requestReroute == false)
        #expect(e.update(fix(110, 300, t: 18)).requestReroute)
        let back = e.update(fix(0, 320, t: 19)).snapshot
        #expect(back.state == .active)
    }

    @Test func snappingIgnoresDistantPartsOfTheRoute() {
        let e = engine
        _ = e.update(fix(0, 10, t: 0))
        for t in 1...3 { _ = e.update(fix(400, 880, t: t)) }
        #expect(e.progressMetres < 20, "a fix near the destination must not teleport progress")
    }

    @Test func arrivalIsStickyAndPoorFixesAreNoLocation() {
        let e = engine
        #expect(e.update(fix(0, 100, accuracy: -1, t: 0)).snapshot.state == .noLocation)
        #expect(e.update(fix(0, 100, accuracy: 80, t: 1)).snapshot.state == .noLocation)
        _ = e.update(fix(0, 400, t: 2))
        _ = e.update(fix(300, 500, t: 3))
        _ = e.update(fix(400, 700, t: 4))
        #expect(e.update(fix(400, 880, t: 5)).snapshot.state == .arrived)
        #expect(e.update(fix(0, 0, t: 6)).snapshot.state == .arrived)
    }

    @Test func roundaboutRouteGetsDirection() throws {
        let route = PlannedRoute(steps: [
            PlannedStep(points: [at(0, 0), at(0, 300)], instructions: "At the roundabout, take the 2nd exit onto Ring Road"),
            PlannedStep(points: [at(0, 300), at(-15, 315), at(0, 330), at(0, 500)],
                        instructions: "Arrive at the destination"),
        ], expectedTravelSeconds: 60)
        let e = try #require(GuidanceEngine(route: route, session: session, generation: RouteGeneration(0)))
        #expect(e.maneuvers.first?.maneuver == .roundaboutClockwise)
        #expect(e.maneuvers.first?.roundaboutDirection == .straight)
        #expect(e.maneuvers.first?.road == "Ring Road")
    }

    @Test func rejectsDegenerateRoutes() {
        #expect(GuidanceEngine(route: PlannedRoute(steps: [], expectedTravelSeconds: 10),
                               session: session, generation: RouteGeneration(0)) == nil)
        #expect(GuidanceEngine(route: PlannedRoute(steps: [PlannedStep(points: [at(0, 0)], instructions: "")],
                                                   expectedTravelSeconds: 10),
                               session: session, generation: RouteGeneration(0)) == nil)
    }

    @Test func replayDrivesDashboardAndOldRouteCannotResurrect() throws {
        let clock = ManualClock()
        let transport = FakeTransport()
        let c = SessionCoordinator(clock: clock)
        let pump = ClusterWritePump(transport: transport, clock: clock, link: ClusterLinkInfo(
            navigationWriteMode: .withoutResponse, statusWriteMode: nil, maximumWriteLength: 182))
        c.linkReady(pump)
        c.beginSession(session)
        let first = try #require(GuidanceEngine(route: cityRoute, session: session, generation: c.generation))

        let trace: [(Double, Double)] = (0...50).map { (0, Double($0) * 10) } + (1...40).map { (Double($0) * 10, 500) }
            + (1...40).map { (400, 500 + Double($0) * 10) }
        for (x, y) in trace {
            clock.advance(by: .seconds(1))
            c.receive(first.update(LocationFix(coordinate: at(x, y), horizontalAccuracy: 5, observedAt: clock.now)).snapshot)
        }
        let icons = Set(transport.navigationWrites.compactMap { TbtFrameSummary(frame: $0)?.icon })
        for icon in [ClusterIcon.turnRight, ClusterIcon.turnRight + 32, ClusterIcon.turnLeft,
                     ClusterIcon.turnLeft + 32, ClusterIcon.destinationReached] {
            #expect(icons.contains(icon), "icon \(icon)")
        }

        c.replaceRoute()
        let stale = first.update(LocationFix(coordinate: at(400, 899), horizontalAccuracy: 5, observedAt: clock.now))
        #expect(c.receive(stale.snapshot) == .failure(.obsoleteGeneration))
    }
}

@Suite("Guidance engine GPS gaps")
struct GuidanceGapTests {
    @Test func tunnelGapDoesNotLookLikeLeavingTheRoute() throws {
        let e = try #require(GuidanceEngine(route: cityRoute, session: SessionID(), generation: RouteGeneration(0)))
        _ = e.update(LocationFix(coordinate: at(0, 50), horizontalAccuracy: 5, observedAt: MonotonicInstant(offset: .seconds(0))))
        let out = e.update(LocationFix(coordinate: at(300, 500), horizontalAccuracy: 5,
                                       observedAt: MonotonicInstant(offset: .seconds(40))))
        #expect(out.snapshot.state == .active)
        #expect(out.snapshot.step?.maneuver == .turnLeft)
    }
}
