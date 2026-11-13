import Foundation
import Testing
@testable import RideCore

@Suite("Ride health")
struct RideHealthTests {
    func input(_ position: RideHealthInput.Position = .measured(age: .seconds(1), accuracy: 8),
               state: NavigationState = .active, route: RideHealthInput.RouteStatus = .ok,
               link: RideHealthInput.Link = .ready, delivery: DashboardDelivery = .guidanceSubmitted,
               intent: DashboardIntent = .clear(.noSession), voice: RideHealthInput.Voice = .ok,
               phase: RideHealthInput.Phase = .navigating) -> RideHealthInput {
        RideHealthInput(phase: phase, position: position, navigationState: state, intent: intent, route: route,
                        link: link, delivery: delivery, voice: voice)
    }

    @Test func healthyRideIsEligible() {
        let health = RideHealthEvaluator.evaluate(input())
        #expect(health.directionEligible && health.severity == .ok && health.items.isEmpty)
    }

    @Test func bikeLossIsNotGPSLoss() {
        let bike = RideHealthEvaluator.evaluate(input(link: .down))
        #expect(bike.directionEligible, "phone guidance continues without the bike")
        #expect(bike.primary.kind == .dashboard && bike.primary.action == .reconnectBike)
        let gps = RideHealthEvaluator.evaluate(input(.measured(age: .seconds(5), accuracy: 8)))
        #expect(!gps.directionEligible, "a measurement exactly five seconds old is stale")
        #expect(gps.primary.kind == .position)
    }

    @Test func positionOutranksEverythingElse() {
        let health = RideHealthEvaluator.evaluate(input(.permissionDenied, route: .failed("No route found."),
                                                        link: .down, voice: .held("Headset disconnected.")))
        #expect(health.primary.kind == .position && health.primary.action == .openSettings)
        #expect(health.items.map(\.kind) == [.position, .route, .dashboard, .voice])
        #expect(!health.directionEligible)
    }

    @Test func imprecisePositionSuppressesDirections() {
        #expect(!RideHealthEvaluator.evaluate(input(.measured(age: .seconds(1), accuracy: 70))).directionEligible)
    }

    @Test func failedRerouteKeepsAnOnRouteRiderGuided() {
        let failed = RideHealthEvaluator.evaluate(input(route: .failed("Network error.")))
        #expect(failed.primary.action == .retryRoute)
        #expect(failed.directionEligible, "back on the old route with a fresh fix")
        #expect(!RideHealthEvaluator.evaluate(input(state: .rerouting, route: .failed("Network error."))).directionEligible)
    }

    @Test func unsupportedTurnSaysFollowThePhone() {
        let health = RideHealthEvaluator.evaluate(input(intent: .clear(.unsupportedManeuver)))
        #expect(health.items.contains { $0.message.contains("follow the phone") })
        #expect(health.directionEligible)
    }

    @Test func transportAcknowledgementIsNotRiderConfirmation() {
        let pending = RideHealthEvaluator.evaluate(input(delivery: .clearHandedOffWithoutResponse))
        #expect(pending.items.first?.message.contains("not yet confirmed") == true)
        let uncertain = RideHealthEvaluator.evaluate(input(delivery: .deliveryUncertain))
        #expect(uncertain.primary.kind == .dashboard && uncertain.primary.severity == .warning)
    }

    @Test func confirmationsAreExplained() {
        #expect(RideHealthEvaluator.evaluate(input(phase: .atStop)).primary.action == .confirmLeg)
        #expect(RideHealthEvaluator.evaluate(input(phase: .recoveryOffered)).primary.action == .resumeRide)
        #expect(!RideHealthEvaluator.evaluate(input(phase: .atStop)).directionEligible)
    }
}

@Suite("Clear delivery")
struct ClearDeliveryTests {
    let clock = ManualClock()

    @Test func deliveryStatesAreHonest() {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(clock: clock)
        #expect(coordinator.delivery == .linkDown)
        let pump = ClusterWritePump(transport: transport, clock: clock, link: responseLink)
        coordinator.linkReady(pump)
        #expect(coordinator.delivery == .clearPending && !coordinator.clearAcknowledged)
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(coordinator.delivery == .clearTransportAcknowledged && coordinator.clearAcknowledged)
        coordinator.showDiagnosticFrame(frame(icon: ClusterIcon.turnLeft, step: 300))
        pump.didCompleteWrite(on: .navigation, success: true)
        coordinator.clearDiagnosticFrame()
        #expect(coordinator.delivery == .clearPending && !coordinator.clearAcknowledged,
                "a new clear resets the acknowledgement of the old one")
        clock.advance(by: .seconds(3))
        coordinator.tick()
        #expect(coordinator.delivery == .deliveryUncertain && !coordinator.clearAcknowledged)
        coordinator.linkLost()
        #expect(coordinator.delivery == .linkDown)
    }

    @Test func withoutResponseIsNeverAcknowledged() {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(clock: clock)
        coordinator.linkReady(ClusterWritePump(transport: transport, clock: clock, link: ClusterLinkInfo(
            navigationWriteMode: .withoutResponse, statusWriteMode: nil, maximumWriteLength: 244)))
        #expect(coordinator.delivery == .clearHandedOffWithoutResponse && !coordinator.clearAcknowledged)
    }

    @Test func nextDeadlineCoversFreshnessResendAndTimeout() {
        let transport = FakeTransport()
        let coordinator = SessionCoordinator(clock: clock)
        #expect(coordinator.nextDeadline == nil, "nothing to do: no wake needed")
        let pump = ClusterWritePump(transport: transport, clock: clock, link: responseLink)
        coordinator.linkReady(pump)
        #expect(coordinator.nextDeadline == MonotonicInstant(offset: .seconds(3)), "the clear's write timeout")
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(coordinator.nextDeadline == nil)
        coordinator.beginSession(SessionID())
        coordinator.receive(NavigationSnapshot(
            session: coordinator.session!, generation: coordinator.generation, observedAt: clock.now, state: .active,
            step: GuidanceStep(maneuver: .turnLeft, distanceMetres: 300), remainingMetres: 4_000, remainingSeconds: 600,
            measurementAt: clock.now))
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(coordinator.nextDeadline == MonotonicInstant(offset: .milliseconds(800)), "the next resend")
    }
}
