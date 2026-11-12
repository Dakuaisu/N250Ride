#if canImport(GoogleNavigation)
import GoogleNavigation
import RideCore
import Testing
@testable import N250Ride

/// SDK-shaped synthetic fixtures; no SDK initialisation, key or network.
struct GoogleGuidanceMapperTests {
    let session = SessionID()

    func fields(_ state: GMSNavigationNavState = .enroute, maneuver: GMSNavigationManeuver = .turnLeft,
                step: Double = 250, exit: Int = 0, road: String = "MG Road",
                total: Double = 4_200, time: Double = 600, hasStep: Bool = true) -> GoogleNavInfoFields {
        GoogleNavInfoFields(
            navState: state,
            step: hasStep ? GoogleStepFields(maneuver: maneuver, roundaboutTurnNumber: exit,
                                             distanceToStepMetres: step, simpleRoadName: road) : nil,
            distanceToDestinationMetres: total, timeToDestinationSeconds: time)
    }

    func snapshot(_ f: GoogleNavInfoFields) -> NavigationSnapshot {
        GoogleGuidanceMapper.snapshot(f, session: session, generation: RouteGeneration(2),
                                      observedAt: MonotonicInstant(offset: .seconds(7)))
    }

    @Test(arguments: [
        (GMSNavigationManeuver.turnLeft, Maneuver.turnLeft),
        (.turnRight, .turnRight),
        (.turnSlightLeft, .slightLeft),
        (.turnSlightRight, .slightRight),
        (.turnSharpLeft, .sharpLeft),
        (.turnSharpRight, .sharpRight),
        (.turnKeepLeft, .keepLeft),
        (.turnKeepRight, .keepRight),
        (.forkLeft, .forkLeft),
        (.forkRight, .forkRight),
        (.mergeLeft, .merge),
        (.onRampLeft, .rampLeft),
        (.offRampSlightRight, .rampRight),
        (.turnUTurnClockwise, .uTurnRight),
        (.turnUTurnCounterClockwise, .uTurnLeft),
        (.roundaboutLeftClockwise, .roundaboutClockwise),
        (.roundaboutExitCounterClockwise, .roundaboutCounterClockwise),
        (.depart, .straight),
        (.nameChange, .straight),
        (.destinationLeft, .arrival),
        (.ferryBoat, .ferry),
        (.ferryTrain, .ferryTrain),
        (.unknown, .unsupported),
        (.onRampUnspecified, .unsupported),
        (.offRampUnspecified, .unsupported),
    ])
    func mapsManeuver(google: GMSNavigationManeuver, expected: Maneuver) {
        #expect(GoogleGuidanceMapper.maneuver(google) == expected)
    }

    @Test func everyRawManeuverMapsWithoutFallingBackToStraight() {
        for raw: UInt in 0...65 {
            guard let m = GMSNavigationManeuver(rawValue: raw) else { continue }
            let mapped = GoogleGuidanceMapper.maneuver(m)
            if mapped == .straight {
                #expect([GMSNavigationManeuver.depart, .straight, .nameChange].contains(m), "raw \(raw)")
            }
        }
    }

    @Test func activeStepBecomesTypedSnapshot() {
        let s = snapshot(fields(maneuver: .roundaboutRightClockwise, step: 249.6, exit: 3))
        #expect(s.state == .active)
        #expect(s.generation == RouteGeneration(2))
        #expect(s.step == GuidanceStep(maneuver: .roundaboutClockwise, roundaboutExit: 3, roundaboutDirection: .right,
                                       distanceMetres: 250, roadText: "MG Road"))
        #expect(s.remainingMetres == 4_200)
        #expect(s.remainingSeconds == 600)
    }

    @Test func roundaboutDirectionComesFromManeuverOnly() {
        #expect(GoogleGuidanceMapper.roundaboutDirection(.roundaboutStraightClockwise) == .straight)
        #expect(GoogleGuidanceMapper.roundaboutDirection(.roundaboutSharpLeftCounterClockwise) == .sharpLeft)
        #expect(GoogleGuidanceMapper.roundaboutDirection(.roundaboutUTurnClockwise) == .uTurn)
        #expect(GoogleGuidanceMapper.roundaboutDirection(.roundaboutClockwise) == nil)
        #expect(GoogleGuidanceMapper.roundaboutDirection(.roundaboutExitCounterClockwise) == nil)
        #expect(GoogleGuidanceMapper.roundaboutDirection(.turnRight) == nil)
    }

    @Test func statesMapExplicitly() {
        #expect(snapshot(fields(.rerouting)).state == .rerouting)
        #expect(snapshot(fields(.stopped)).state == .stopped)
        #expect(snapshot(fields(.unknown)).state == .noLocation)
    }

    @Test func unknownValuesBecomeNilNotZero() {
        let s = snapshot(fields(step: -1, total: -1, time: .nan))
        #expect(s.step == nil)
        #expect(s.remainingMetres == nil)
        #expect(s.remainingSeconds == nil)
        #expect(snapshot(fields(hasStep: false)).step == nil)
        #expect(snapshot(fields(road: "")).step?.roadText == nil)
    }

    @Test func routeStatusFailuresNeverSuggestCarRouting() {
        #expect(GoogleGuidanceMapper.failure(for: .OK) == nil)
        #expect(GoogleGuidanceMapper.failure(for: .noRouteFound) == .noTwoWheelerRoute)
        #expect(GoogleGuidanceMapper.failure(for: .quotaExceeded) == .quotaExceeded)
        #expect(RouteRequestFailure.noTwoWheelerRoute.message.contains("car routing is not used"))
    }
}
#endif
