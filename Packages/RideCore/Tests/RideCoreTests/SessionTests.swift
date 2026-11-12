import Foundation
import Testing
@testable import RideCore

@Suite("Navigation state machine")
struct NavigationStateMachineTests {
    let session = SessionID()

    func snapshot(_ state: NavigationState, generation: Int = 0, at seconds: Int, session: SessionID? = nil) -> NavigationSnapshot {
        NavigationSnapshot(session: session ?? self.session, generation: RouteGeneration(generation),
                           observedAt: MonotonicInstant(offset: .seconds(seconds)), state: state)
    }

    @Test func happyPathPreviewActiveArrivalStopped() {
        var machine = NavigationStateMachine()
        #expect(machine.state == .idle)
        machine.begin(session)
        #expect(machine.state == .preview)
        for (i, state) in [NavigationState.preview, .active, .arrived, .stopped].enumerated() {
            #expect(machine.accept(snapshot(state, at: i)) == .success(snapshot(state, at: i)))
            #expect(machine.state == state)
        }
        #expect(machine.accept(snapshot(.active, at: 9)) == .failure(.sessionAlreadyStopped))
    }

    @Test func delayedOldCallbacksAreRejected() {
        var machine = NavigationStateMachine()
        machine.begin(session)
        _ = machine.accept(snapshot(.active, at: 1))
        let next = machine.advanceGeneration()
        #expect(next == RouteGeneration(1))
        #expect(machine.accept(snapshot(.active, generation: 0, at: 5)) == .failure(.obsoleteGeneration))
        #expect(machine.accept(snapshot(.active, generation: 1, at: 3)).isSuccess)
        #expect(machine.accept(snapshot(.active, generation: 1, at: 2)) == .failure(.outOfOrder))
        #expect(machine.accept(snapshot(.active, generation: 1, at: 4, session: SessionID())) == .failure(.wrongSession))
        machine.end()
        #expect(machine.accept(snapshot(.active, generation: 1, at: 6)) == .failure(.noActiveSession))
    }

    @Test func deniedPermissionIsExplicitState() {
        var machine = NavigationStateMachine()
        machine.begin(session)
        _ = machine.accept(snapshot(.failed(.locationPermissionDenied), at: 1))
        #expect(machine.state == .failed(.locationPermissionDenied))
        #expect(!machine.state.allowsGuidance)
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

@Suite("Session coordinator safety rules")
struct SessionCoordinatorTests {
    let clock = ManualClock(wallNow: ISO8601DateFormatter().date(from: "2026-11-11T09:00:00Z")!)
    let transport = FakeTransport()
    let utc = TimeZone(identifier: "UTC")!

    func makeCoordinator(profile: GeneralStatusProfile? = nil) -> (SessionCoordinator, ClusterWritePump) {
        let coordinator = SessionCoordinator(clock: clock, configuration: SessionConfiguration(statusProfile: profile, timeZone: utc))
        let pump = ClusterWritePump(transport: transport, clock: clock, link: responseLink)
        return (coordinator, pump)
    }

    func active(_ c: SessionCoordinator, _ maneuver: Maneuver = .turnLeft, step: Int = 400,
                generation: RouteGeneration? = nil, state: NavigationState = .active) -> NavigationSnapshot {
        NavigationSnapshot(
            session: c.session!, generation: generation ?? c.generation, observedAt: clock.now, state: state,
            step: GuidanceStep(maneuver: maneuver, distanceMetres: step, roadText: "MG Road"),
            remainingMetres: 4_200, remainingSeconds: 600
        )
    }

    /// Completes the outstanding acknowledged write, as CoreBluetooth would.
    func ack(_ pump: ClusterWritePump, _ channel: ClusterChannel = .navigation) {
        pump.didCompleteWrite(on: channel, success: true)
    }

    @Test func newLinkClearsBeforeFreshGuidance() throws {
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.receive(active(c))
        c.linkReady(pump)
        ack(pump)
        #expect(transport.navigationWrites.count == 2)
        #expect(transport.navigationWrites[0] == TbtFrame.stop())
        let summary = try #require(TbtFrameSummary(frame: transport.navigationWrites[1]))
        #expect(summary.icon == ClusterIcon.turnLeft)
        #expect(summary.etaHour == 9 && summary.etaMinute == 10 && !summary.isPM)
        #expect(summary.text == "MG Road")
        #expect(c.clearAcknowledged)
    }

    @Test(arguments: [NavigationState.rerouting, .noLocation, .stopped, .failed(.travelModeUnsupported)])
    func nonGuidingStatesClearImmediately(state: NavigationState) {
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.linkReady(pump)
        ack(pump)
        c.receive(active(c))
        ack(pump)
        clock.advance(by: .milliseconds(100))
        c.receive(NavigationSnapshot(session: c.session!, generation: c.generation, observedAt: clock.now, state: state))
        ack(pump)
        #expect(transport.navigationWrites.last == TbtFrame.stop())
        #expect(c.intent == .clear(.notGuiding(state)))
    }

    @Test func missingStepAndUnsupportedManeuverClearInsteadOfGuessing() {
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.linkReady(pump)
        ack(pump)
        c.receive(active(c, .unsupported))
        #expect(c.intent == .clear(.unsupportedManeuver))
        var noStep = active(c)
        noStep.step = nil
        c.receive(noStep)
        #expect(c.intent == .clear(.noStep))
        #expect(transport.navigationWrites == [TbtFrame.stop()], "clear is sent once, not repeated")
    }

    @Test func watchdogClearsStaleGuidanceAndResumesOnFreshData() {
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.linkReady(pump)
        ack(pump)
        c.receive(active(c))
        ack(pump)
        clock.advance(by: .seconds(5))
        c.tick()
        ack(pump)
        #expect(c.intent != .clear(.stale), "exactly five seconds is still fresh")
        clock.advance(by: .milliseconds(1))
        c.tick()
        ack(pump)
        #expect(c.intent == .clear(.stale))
        #expect(transport.navigationWrites.last == TbtFrame.stop())
        c.receive(active(c, .turnRight))
        #expect(TbtFrameSummary(frame: transport.navigationWrites.last!)?.icon == ClusterIcon.turnRight)
    }

    @Test func validQuietGuidanceIsResentNotCleared() {
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.linkReady(pump)
        ack(pump)
        c.receive(active(c))
        ack(pump)
        let before = transport.navigationWrites.count
        clock.advance(by: .milliseconds(800))
        c.tick()
        ack(pump)
        #expect(transport.navigationWrites.count == before + 1)
        #expect(transport.navigationWrites.last != TbtFrame.stop())
    }

    @Test func lateOldRouteNeverResurrectsArrows() {
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.linkReady(pump)
        ack(pump)
        let old = active(c, .turnLeft)
        c.replaceRoute()
        #expect(c.receive(old) == .failure(.obsoleteGeneration))
        #expect(c.intent == .clear(.notGuiding(.preview)))
        #expect(transport.navigationWrites == [TbtFrame.stop()])
        #expect(c.rejectedSnapshots == 1)
    }

    @Test func linkLossPurgesAndNeverClaimsClear() {
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.linkReady(pump)
        c.receive(active(c))
        c.linkLost()
        ack(pump)
        #expect(!c.clearAcknowledged)
        #expect(c.output == .unknownLinkDown)
        c.endSession()
        #expect(transport.navigationWrites == [TbtFrame.stop()], "nothing is written without a link")

        let newPump = ClusterWritePump(transport: transport, clock: clock, link: responseLink)
        c.linkReady(newPump)
        #expect(transport.navigationWrites == [TbtFrame.stop(), TbtFrame.stop()])
    }

    @Test func arrivalShowsDestinationThenStopClears() throws {
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.linkReady(pump)
        ack(pump)
        c.receive(NavigationSnapshot(session: c.session!, generation: c.generation, observedAt: clock.now, state: .arrived))
        ack(pump)
        #expect(TbtFrameSummary(frame: transport.navigationWrites.last!)?.icon == ClusterIcon.destinationReached)
        c.endSession()
        ack(pump)
        #expect(transport.navigationWrites.last == TbtFrame.stop())
    }

    @Test func outOfRangeValuesAreSuppressed() {
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.linkReady(pump)
        ack(pump)
        c.receive(active(c, step: -5))
        #expect(c.intent == .clear(.invalidValues(.distanceOutOfRange(-5))))
    }

    @Test func statusHeartbeatOnlyWithProvenProfile() {
        let (c, pump) = makeCoordinator(profile: .v2_89)
        c.linkReady(pump)
        ack(pump)
        #expect(transport.writes.last?.channel == .status)
        #expect(transport.writes.last?.bytes[54] == 1)
        ack(pump, .status)
        clock.advance(by: .seconds(5))
        c.tick()
        #expect(transport.writes.last?.bytes[54] == 2)

        let plain = FakeTransport()
        let quiet = SessionCoordinator(clock: clock)
        quiet.linkReady(ClusterWritePump(transport: plain, clock: clock, link: responseLink))
        #expect(plain.writes.allSatisfy { $0.channel == .navigation })
    }

    @Test func bluetoothLifecycleNeverRequestsRoutes() {
        let store = InMemoryUsageCounterStore()
        let gate = RouteRequestGate(policy: .metered(RouteRequestLimits()), store: store, clock: clock)
        let (c, pump) = makeCoordinator()
        c.beginSession(SessionID())
        c.receive(active(c))
        for _ in 0..<5 {
            c.linkReady(ClusterWritePump(transport: transport, clock: clock, link: responseLink))
            c.linkLost()
        }
        c.linkReady(pump)
        #expect(gate.usage.dayCount == 0)
        #expect(store.saved == nil)
        #expect(gate.inFlight == nil)
    }
}
