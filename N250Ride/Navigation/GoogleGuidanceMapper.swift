#if canImport(GoogleNavigation)
import Foundation
import GoogleNavigation
import RideCore

/// Plain values copied out of `GMSNavigationStepInfo`, so mapping is testable with
/// synthetic fixtures (the SDK classes cannot be instantiated).
struct GoogleStepFields: Equatable {
    var maneuver: GMSNavigationManeuver
    var roundaboutTurnNumber: Int
    var distanceToStepMetres: Double
    var simpleRoadName: String
}

/// Plain values copied out of `GMSNavigationNavInfo`.
struct GoogleNavInfoFields: Equatable {
    var navState: GMSNavigationNavState
    var step: GoogleStepFields?
    var distanceToDestinationMetres: Double
    var timeToDestinationSeconds: Double

    init(navState: GMSNavigationNavState, step: GoogleStepFields?,
         distanceToDestinationMetres: Double, timeToDestinationSeconds: Double) {
        self.navState = navState
        self.step = step
        self.distanceToDestinationMetres = distanceToDestinationMetres
        self.timeToDestinationSeconds = timeToDestinationSeconds
    }

    init(_ info: GMSNavigationNavInfo) {
        navState = info.navState
        step = info.currentStep.map {
            GoogleStepFields(maneuver: $0.maneuver, roundaboutTurnNumber: $0.roundaboutTurnNumber,
                             distanceToStepMetres: info.distanceToCurrentStepMeters,
                             simpleRoadName: $0.simpleRoadName)
        }
        distanceToDestinationMetres = info.distanceToFinalDestinationMeters
        timeToDestinationSeconds = info.timeToFinalDestinationSeconds
    }
}

/// The only place Google enum values are interpreted. Anything unclassifiable is
/// `.unsupported`, which clears the dashboard instead of guessing.
enum GoogleGuidanceMapper {
    static func maneuver(_ m: GMSNavigationManeuver) -> Maneuver {
        switch m {
        case .depart, .straight, .nameChange: .straight
        case .destination, .destinationLeft, .destinationRight: .arrival
        case .turnLeft: .turnLeft
        case .turnRight: .turnRight
        case .turnKeepLeft: .keepLeft
        case .turnKeepRight: .keepRight
        case .turnSlightLeft: .slightLeft
        case .turnSlightRight: .slightRight
        case .turnSharpLeft: .sharpLeft
        case .turnSharpRight: .sharpRight
        case .turnUTurnClockwise, .onRampUTurnClockwise, .offRampUTurnClockwise: .uTurnRight
        case .turnUTurnCounterClockwise, .onRampUTurnCounterClockwise, .offRampUTurnCounterClockwise: .uTurnLeft
        case .mergeUnspecified, .mergeLeft, .mergeRight: .merge
        case .forkLeft: .forkLeft
        case .forkRight: .forkRight
        case .onRampLeft, .onRampKeepLeft, .onRampSlightLeft, .onRampSharpLeft,
             .offRampLeft, .offRampKeepLeft, .offRampSlightLeft, .offRampSharpLeft: .rampLeft
        case .onRampRight, .onRampKeepRight, .onRampSlightRight, .onRampSharpRight,
             .offRampRight, .offRampKeepRight, .offRampSlightRight, .offRampSharpRight: .rampRight
        case .roundaboutClockwise, .roundaboutStraightClockwise, .roundaboutLeftClockwise,
             .roundaboutRightClockwise, .roundaboutSlightLeftClockwise, .roundaboutSlightRightClockwise,
             .roundaboutSharpLeftClockwise, .roundaboutSharpRightClockwise, .roundaboutUTurnClockwise,
             .roundaboutExitClockwise: .roundaboutClockwise
        case .roundaboutCounterClockwise, .roundaboutStraightCounterClockwise, .roundaboutLeftCounterClockwise,
             .roundaboutRightCounterClockwise, .roundaboutSlightLeftCounterClockwise,
             .roundaboutSlightRightCounterClockwise, .roundaboutSharpLeftCounterClockwise,
             .roundaboutSharpRightCounterClockwise, .roundaboutUTurnCounterClockwise,
             .roundaboutExitCounterClockwise: .roundaboutCounterClockwise
        case .ferryBoat: .ferry
        case .ferryTrain: .ferryTrain
        // A ramp with no side has no faithful arrow.
        case .onRampUnspecified, .offRampUnspecified, .unknown: .unsupported
        @unknown default: .unsupported
        }
    }

    /// Exit direction encoded in Google's roundabout maneuvers; nil for the generic
    /// enter/exit values that carry no direction.
    static func roundaboutDirection(_ m: GMSNavigationManeuver) -> RoundaboutDirection? {
        switch m {
        case .roundaboutStraightClockwise, .roundaboutStraightCounterClockwise: .straight
        case .roundaboutLeftClockwise, .roundaboutLeftCounterClockwise: .left
        case .roundaboutRightClockwise, .roundaboutRightCounterClockwise: .right
        case .roundaboutSlightLeftClockwise, .roundaboutSlightLeftCounterClockwise: .slightLeft
        case .roundaboutSlightRightClockwise, .roundaboutSlightRightCounterClockwise: .slightRight
        case .roundaboutSharpLeftClockwise, .roundaboutSharpLeftCounterClockwise: .sharpLeft
        case .roundaboutSharpRightClockwise, .roundaboutSharpRightCounterClockwise: .sharpRight
        case .roundaboutUTurnClockwise, .roundaboutUTurnCounterClockwise: .uTurn
        default: nil
        }
    }

    static func state(_ s: GMSNavigationNavState) -> NavigationState {
        switch s {
        case .enroute: .active
        case .rerouting: .rerouting
        case .stopped: .stopped
        case .unknown: .noLocation
        @unknown default: .noLocation
        }
    }

    static func snapshot(_ fields: GoogleNavInfoFields, session: SessionID, generation: RouteGeneration,
                         observedAt: MonotonicInstant) -> NavigationSnapshot {
        NavigationSnapshot(
            session: session,
            generation: generation,
            observedAt: observedAt,
            state: state(fields.navState),
            step: fields.step.flatMap(step),
            remainingMetres: metres(fields.distanceToDestinationMetres),
            remainingSeconds: metres(fields.timeToDestinationSeconds),
            measurementAt: observedAt
        )
    }

    private static func step(_ s: GoogleStepFields) -> GuidanceStep? {
        guard let distance = metres(s.distanceToStepMetres) else { return nil }
        return GuidanceStep(
            maneuver: maneuver(s.maneuver),
            roundaboutExit: s.roundaboutTurnNumber > 0 ? s.roundaboutTurnNumber : nil,
            roundaboutDirection: roundaboutDirection(s.maneuver),
            distanceMetres: distance,
            roadText: s.simpleRoadName.isEmpty ? nil : s.simpleRoadName
        )
    }

    /// Non-negative finite value rounded to an integer, else nil (the SDK uses -1 for unknown).
    private static func metres(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0, value < Double(Int32.max) else { return nil }
        return Int(value.rounded())
    }

    static func failure(for status: GMSRouteStatus) -> RouteRequestFailure? {
        switch status {
        case .OK: nil
        case .noRouteFound: .noTwoWheelerRoute
        case .networkError: .network
        case .quotaExceeded: .quotaExceeded
        case .apiKeyNotAuthorized: .keyNotAuthorized
        case .locationUnavailable: .locationUnavailable
        case .canceled: .cancelled
        default: .other("status \(status.rawValue)")
        }
    }
}
#endif
