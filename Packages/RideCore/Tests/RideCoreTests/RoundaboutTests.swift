import Foundation
import Testing
@testable import RideCore

/// Synthetic roundabouts laid out the way Apple Maps returns them: the step with the
/// roundabout instruction runs along the approach and around the ring and ends where
/// the route leaves it; the next step starts on the exit road.
func roundaboutRoute(radius: Double, sweep: Double, instructions: String = "At the traffic circle, take the second exit onto Exit Road",
                     exitRoad: Double = 200, approachTurn: Double = 0, drivingSide: DrivingSide = .left) -> PlannedRoute {
    let mirror = drivingSide == .left ? 1.0 : -1.0
    func p(_ x: Double, _ y: Double) -> Coordinate { at(mirror * x, y) }
    // Approach heading north into the bottom of a ring centred on the origin.
    var leg: [Coordinate] = []
    let bend = approachTurn * .pi / 180
    let start = (x: -sin(bend) * 300, y: -radius - cos(bend) * 300)
    for i in 0...30 { leg.append(p(start.x + (0 - start.x) * Double(i) / 30, start.y + (-radius - start.y) * Double(i) / 30)) }
    // Clockwise (for left-hand traffic) from 6 o'clock by `sweep` degrees.
    var theta = -90.0
    let end = -90.0 - sweep
    while theta > end {
        theta -= 3
        let t = max(theta, end) * .pi / 180
        leg.append(p(radius * cos(t), radius * sin(t)))
    }
    let t = end * .pi / 180
    let exitPoint = (x: radius * cos(t), y: radius * sin(t))
    let out = [p(exitPoint.x, exitPoint.y), p(exitPoint.x + cos(t) * exitRoad, exitPoint.y + sin(t) * exitRoad)]
    return PlannedRoute(steps: [
        PlannedStep(points: [leg[0]], instructions: ""),
        PlannedStep(points: leg, instructions: instructions),
        PlannedStep(points: out, instructions: "Arrive at the destination"),
    ], expectedTravelSeconds: 120)
}

@Suite("Roundabout exits from the map")
struct RoundaboutTests {
    let session = SessionID()

    func plan(_ route: PlannedRoute, side: DrivingSide = .left) throws -> GuidanceEngine.PlannedManeuver {
        let engine = try #require(GuidanceEngine(route: route, session: session, generation: RouteGeneration(0),
                                                 configuration: GuidanceEngineConfiguration(drivingSide: side)))
        return try #require(engine.maneuvers.first { $0.maneuver == .roundaboutClockwise || $0.maneuver == .roundaboutCounterClockwise })
    }

    @Test(arguments: [15.0, 40.0, 70.0])
    func everyExitDirectionOnRingsOfAnySize(radius: Double) throws {
        let expected: [(Double, RoundaboutDirection)] = [
            (45, .sharpLeft), (90, .left), (135, .slightLeft), (180, .straight),
            (225, .slightRight), (270, .right), (315, .sharpRight),
        ]
        for (sweep, direction) in expected {
            let m = try plan(roundaboutRoute(radius: radius, sweep: sweep))
            #expect(m.maneuver == .roundaboutClockwise)
            #expect(m.roundaboutDirection == direction, "radius \(radius) m, sweep \(sweep)°: got \(String(describing: m.roundaboutDirection))")
        }
    }

    @Test func countdownEndsAtTheEntryAndTheRoundaboutLastsUntilTheExit() throws {
        let radius = 50.0
        let route = roundaboutRoute(radius: radius, sweep: 180)
        let engine = try #require(GuidanceEngine(route: route, session: session, generation: RouteGeneration(0)))
        func step(_ x: Double, _ y: Double, _ t: Int) -> GuidanceStep? {
            engine.update(LocationFix(coordinate: at(x, y), horizontalAccuracy: 5,
                                      observedAt: MonotonicInstant(offset: .seconds(t)))).snapshot.step
        }
        let approaching = try #require(step(0, -radius - 100, 1))
        #expect(approaching.maneuver == .roundaboutClockwise)
        #expect(abs(approaching.distanceMetres - 100) <= 6, "counts down to the entry, not the exit 157 m round the ring")
        let inRing = try #require(step(-radius, 0, 10))
        #expect(inRing.maneuver == .roundaboutClockwise && inRing.distanceMetres == 0, "still the roundabout while going round")
        let after = try #require(step(0, radius + 30, 20))
        #expect(after.maneuver == .arrival)
    }

    @Test func applesWordingWinsWhenItIsExplicit() throws {
        let continueStraight = try plan(roundaboutRoute(radius: 40, sweep: 215,
                                                        instructions: "At the traffic circle, continue onto Jan Marg"))
        #expect(continueStraight.roundaboutDirection == .straight)
        let turnLeft = try plan(roundaboutRoute(radius: 40, sweep: 225,
                                                instructions: "At the traffic circle, turn left onto Rajesh Pilot Marg"))
        #expect(turnLeft.roundaboutDirection == .left, "geometry said right, the text says left")
        let turnRightSlight = try plan(roundaboutRoute(radius: 40, sweep: 225,
                                                       instructions: "At the traffic circle, turn right onto Uttar Marg"))
        #expect(turnRightSlight.roundaboutDirection == .slightRight, "measured direction kept when on the stated side")
    }

    @Test func exitNumberIsReadFromTheText() throws {
        #expect(try plan(roundaboutRoute(radius: 40, sweep: 180)).exitNumber == 2)
        #expect(ManeuverClassifier.cues("At the roundabout, take the 3rd exit onto MG Road").exit == 3)
        #expect(ManeuverClassifier.cues("At the traffic circle, take the fifth exit onto Kushak Road").exit == 5)
        #expect(ManeuverClassifier.cues("At the traffic circle, continue onto Jan Marg").exit == nil)
    }

    @Test func shortExitRoadAndAngledApproachStillWork() throws {
        #expect(try plan(roundaboutRoute(radius: 40, sweep: 90, exitRoad: 12)).roundaboutDirection == .left)
        #expect(try plan(roundaboutRoute(radius: 40, sweep: 270, approachTurn: 20)).roundaboutDirection == .right)
    }

    @Test func rightHandTrafficCirculatesTheOtherWay() throws {
        let m = try plan(roundaboutRoute(radius: 40, sweep: 270, drivingSide: .right), side: .right)
        #expect(m.maneuver == .roundaboutCounterClockwise && m.roundaboutDirection == .left)
    }
}
