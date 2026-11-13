import Foundation
import RideCore
import Testing
import UIKit
@testable import N250Ride

/// The production AppModel on virtual time with a spy provider and temporary storage.
@MainActor
final class RideHarness {
    let timers = ManualRideTimers(clock: ManualClock())
    let spy = SpyProvider()
    let storage: URL
    let defaults: UserDefaults
    let calls = FakeCalls()
    let speech = FakeSpeech()
    let audio = FakeAudio()
    let model: AppModel
    let office = Coordinate(latitude: 12.9716, longitude: 77.5946)!
    let fuel = Favourite(label: "Fuel", coordinate: Coordinate(latitude: 12.95, longitude: 77.60)!)

    init(storage: URL = TestStorage.directory(), defaults: UserDefaults? = nil) {
        self.storage = storage
        self.defaults = defaults ?? UserDefaults(suiteName: "RideHarness-\(UUID())")!
        model = AppModel(configuration: AppConfiguration(navigationProvider: .apple, googleAPIKey: nil,
                                                         liveNavigationAuthorized: false, provenStatusProfile: nil),
                         defaults: self.defaults, provider: spy,
                         dependencies: .virtual(timers, storage: storage, calls: calls, speech: speech, audio: audio))
        model.locationAuthorization = { .authorizedWhenInUse }
    }

    var clock: ManualClock { timers.clock }

    /// Past the route gate's two-second debounce.
    func wait(_ seconds: Int = 3) { timers.advance(by: .seconds(seconds)) }

    func startRide(stop: Favourite? = nil) {
        model.propose(office, label: "Office")
        model.confirmDestination(label: "Office", saveAsFavourite: false, stop: stop)
        spy.pendingRoute?(.success(spy.options))
        model.startNavigation()
    }

    /// The session the coordinator committed for the latest started route.
    var session: SessionID { spy.requests.last { !$0.reason.keepsSession }!.session }

    /// A genuine measurement now, on the given route generation.
    func emit(_ state: NavigationState = .active, metres: Int = 300, generation: Int = 0, session: SessionID? = nil) {
        spy.lastFix = AdmittedFix(sample: LocationSample(coordinate: office, horizontalAccuracy: 5, timestamp: clock.wallNow),
                                  measuredAt: clock.now, expiresAt: clock.now + .seconds(5))
        spy.onSnapshot?(NavigationSnapshot(
            session: session ?? self.session, generation: RouteGeneration(generation), observedAt: clock.now, state: state,
            step: state == .active ? GuidanceStep(maneuver: .turnLeft, distanceMetres: metres, sequence: 1) : nil,
            remainingMetres: state == .active ? 4_000 : 0, remainingSeconds: state == .active ? 600 : 0,
            measurementAt: clock.now))
    }
}

@MainActor
struct RouteTransactionTests {
    let h = RideHarness()

    @Test func previewCommitsNothingAndStartCommitsOnce() {
        h.model.propose(h.office, label: "Office")
        h.model.confirmDestination(label: "Office", saveAsFavourite: false)
        h.spy.pendingRoute?(.success(h.spy.options))
        h.model.selectRoute(2)
        #expect(h.spy.committed.isEmpty && h.spy.selected == [2], "choosing between routes activates nothing")
        #expect(h.model.navigationState == .idle, "no coordinator session during preview")
        h.model.startNavigation()
        h.model.startNavigation()
        #expect(h.spy.committed.count == 1 && h.spy.started == 1)
        #expect(h.model.isRiding)
    }

    @Test func movedRiderMustRecalculate() {
        h.spy.startCheck = .movedFromOrigin(metres: 240)
        h.model.propose(h.office, label: "Office")
        h.model.confirmDestination(label: "Office", saveAsFavourite: false)
        h.spy.pendingRoute?(.success(h.spy.options))
        h.model.startNavigation()
        #expect(h.model.startStatus == .blocked("You've moved 240 m from where this route starts. Recalculate before starting."))
        #expect(h.spy.committed.isEmpty)
        h.wait()
        h.model.recalculatePreview()
        #expect(h.spy.routeRequests == 2 && h.spy.discarded.count == 1)
    }

    @Test func previewExpiresAfterTwoMinutes() {
        h.model.propose(h.office, label: "Office")
        h.model.confirmDestination(label: "Office", saveAsFavourite: false)
        h.spy.pendingRoute?(.success(h.spy.options))
        h.timers.advance(by: .seconds(121))
        #expect(h.model.previewExpired)
        h.model.startNavigation()
        #expect(h.spy.committed.isEmpty, "an expired preview never starts")
    }

    @Test func manualAndAutomaticRerouteShareOneRequest() {
        h.startRide()
        h.wait()
        h.model.requestReroute(.manual)
        h.spy.onRerouteNeeded?()
        h.model.requestReroute(.manual)
        #expect(h.spy.rerouteRequests == [RouteGeneration(1)])
        h.spy.pendingReroute?(.success(()))
        #expect(h.model.routeOperation == .idle && h.spy.committed.count == 2)
        h.emit(generation: 0)
        #expect(h.model.guidance == nil, "the old generation is no longer admitted")
        h.emit(generation: 1)
        #expect(h.model.guidance?.generation == RouteGeneration(1))
    }

    @Test func failedRerouteKeepsTheRouteAndOffersRetry() {
        h.startRide()
        h.emit()
        h.wait()
        h.model.requestReroute(.manual)
        h.spy.pendingReroute?(.failure(.network))
        #expect(h.model.routeOperation == .failed(.manual, RouteRequestFailure.network.message))
        #expect(h.spy.committed.count == 1, "nothing replaced")
        h.emit(generation: 0)
        #expect(h.model.guidance?.generation == RouteGeneration(0) && h.model.health.directionEligible)
        #expect(h.model.health.primary.action == .retryRoute)
    }

    @Test func rerouteTimesOutAndReleasesItsTicket() {
        h.startRide()
        h.wait()
        h.model.requestReroute(.manual)
        h.timers.advance(by: .seconds(30))
        #expect(h.model.routeOperation == .failed(.manual, RouteRequestFailure.timedOut.message))
        #expect(h.spy.cancelled.count == 1)
        h.spy.pendingReroute?(.success(()))
        #expect(h.spy.committed.count == 1, "the late answer changes nothing")
        h.wait()
        h.model.requestReroute(.manual)
        #expect(h.spy.rerouteRequests.count == 2, "the gate was released")
    }

    @Test func positionExpiryPausesDirectionsWithoutANewSnapshot() {
        h.startRide()
        h.emit()
        #expect(h.model.health.directionEligible)
        h.timers.advance(by: .milliseconds(4_999))
        #expect(h.model.health.directionEligible)
        h.timers.advance(by: .milliseconds(1))
        #expect(!h.model.health.directionEligible, "five seconds after the measurement, with no new fix")
        #expect(h.model.intent == .clear(.stale))
    }

    @Test func idleAppSchedulesNoWakes() {
        #expect(h.timers.pending == 0, "nothing to do means no periodic wake")
        h.model.setSimulationMode(true)
        h.model.propose(h.office, label: "Office")
        h.model.confirmDestination(label: "Office", saveAsFavourite: false)
        h.model.startNavigation()
        h.timers.advance(by: .seconds(2))
        #expect(h.model.counters.wakes >= 9 && h.model.counters.wakes <= 11, "the synthetic ride ticks every 200 ms")
        h.model.stopNavigation()
        let wakes = h.model.counters.wakes
        h.timers.advance(by: .seconds(60))
        #expect(h.model.counters.wakes == wakes, "and stops after the ride")
    }
}

@MainActor
struct StopFlowTests {
    let h = RideHarness()

    @Test func stopArrivalEndsTheLegAndWaitsForContinue() {
        h.startRide(stop: h.fuel)
        #expect(h.spy.requests[0].target == h.fuel.coordinate)
        let legOne = h.session
        h.emit(.arrived)
        guard case .atStop = h.model.stage else {
            Issue.record("expected the stop, got \(h.model.stage)")
            return
        }
        #expect(h.model.navigationState == .idle, "leg one's session is over")
        h.emit(.arrived, session: legOne)
        h.emit(session: legOne)
        #expect(h.model.guidance == nil, "nothing from the old leg is admitted")
        h.wait()
        h.model.continueToFinal()
        let legTwo = h.spy.requests.last!
        #expect(legTwo.reason == .nextLeg && legTwo.target == h.office && legTwo.session != legOne)
        h.spy.pendingRoute?(.success(h.spy.options))
        h.model.cancelPreview()
        guard case .atStop = h.model.stage else {
            Issue.record("cancel returns to the stop")
            return
        }
        h.wait()
        h.model.continueToFinal()
        h.spy.pendingRoute?(.success(h.spy.options))
        h.model.startNavigation()
        #expect(h.model.isRiding && h.model.ride?.phase == .toFinal)
        #expect(h.spy.committed.count == 2)
    }

    @Test func skippingTheStopIsANewRouteOnlyWhenItSucceeds() {
        h.startRide(stop: h.fuel)
        let legOne = h.session
        h.wait()
        h.model.skipStop()
        h.spy.pendingRoute?(.failure(.network))
        #expect(h.model.ride?.phase == .toStop, "failure keeps the stop")
        h.wait()
        h.model.skipStop()
        h.spy.pendingRoute?(.success(h.spy.options))
        #expect(h.model.ride?.phase == .toFinal && h.spy.committed.count == 2)
        h.emit(session: legOne)
        #expect(h.model.guidance == nil, "the old session is gone")
    }

    @Test func aSecondStopIsRefused() {
        h.startRide(stop: h.fuel)
        h.model.addStop(RideDestination(coordinate: h.office, label: "ATM", provenance: .manual))
        #expect(h.model.routeOperation == .failed(.replacement, "This ride already has a stop. Skip it first."))
    }
}

@MainActor
struct InboxFlowTests {
    let h = RideHarness()

    @Test func shareDuringARideIsQueuedNotOpened() {
        h.startRide()
        h.model.handleIncoming("Fuel https://maps.apple.com/?ll=12.95,77.58&q=Fuel")
        #expect(h.model.isRiding && h.model.inbox.waiting.count == 1)
        #expect(h.model.linkMessage?.hasPrefix("Destination saved") == true)
        h.model.stopNavigation()
        h.model.openInboxItem(h.model.inbox.waiting[0].id)
        guard case .confirming(let pending) = h.model.stage else {
            Issue.record("expected confirmation")
            return
        }
        #expect(pending.label == "Fuel" && pending.provenance == .shared)
    }

    @Test func failedReplacementKeepsTheCurrentRide() {
        h.startRide()
        let ride = h.model.ride?.id
        h.model.handleIncoming("Fuel https://maps.apple.com/?ll=12.95,77.58&q=Fuel")
        h.wait()
        h.model.replaceDestination(with: h.model.inbox.items[0].id)
        h.spy.pendingRoute?(.failure(.network))
        #expect(h.model.ride?.id == ride && h.spy.committed.count == 1)
        guard case .navigating(let pending) = h.model.stage else {
            Issue.record("still riding")
            return
        }
        #expect(pending.label == "Office")
    }

    @Test func inboxIsBoundedAndSurvivesARestart() {
        let inbox = IncomingInbox(directory: h.storage, now: h.clock.wallNow)
        for i in 0..<10 {
            #expect(inbox.add(coordinate: Coordinate(latitude: 12 + Double(i) / 100, longitude: 77)!, label: "P\(i)",
                              link: nil, now: h.clock.wallNow) != .full)
        }
        #expect(inbox.add(coordinate: h.office, label: "Too many", link: nil, now: h.clock.wallNow) == .full)
        let first = inbox.items[0]
        #expect(inbox.add(coordinate: first.coordinate, label: first.label, link: nil, now: h.clock.wallNow) == .duplicate(first.id))
        inbox.setStatus(first.id, .reserved)
        let reopened = IncomingInbox(directory: h.storage, now: h.clock.wallNow)
        #expect(reopened.items.count == 10 && reopened.items[0].status == .pending)
        let week = IncomingInbox(directory: h.storage, now: h.clock.wallNow.addingTimeInterval(IncomingInbox.lifetime))
        #expect(week.items.isEmpty, "seven days after receipt")
    }

    @Test func linksFollowOnlyMapHosts() {
        #expect(LinkExpander.mayFollow(URL(string: "https://maps.app.goo.gl/abc")!))
        #expect(!LinkExpander.mayFollow(URL(string: "http://maps.app.goo.gl/abc")!), "HTTPS only")
        #expect(!LinkExpander.mayFollow(URL(string: "https://user:pw@maps.app.goo.gl/abc")!))
        #expect(!LinkExpander.mayFollow(URL(string: "https://192.168.1.1/maps")!))
        #expect(!LinkExpander.mayFollow(URL(string: "https://google.evil.com/maps")!))
        #expect(LinkExpander.mayFollow(URL(string: "https://www.google.co.in/maps/@12.9,77.5,15z")!))
    }
}

@MainActor
struct RecoveryFlowTests {
    @Test func interruptedRideIsOfferedAndResumesFresh() {
        let storage = TestStorage.directory()
        let defaults = UserDefaults(suiteName: "Recovery-\(UUID())")!
        let first = RideHarness(storage: storage, defaults: defaults)
        first.model.recovery.setEnabled(true)
        first.startRide(stop: first.fuel)

        let restarted = RideHarness(storage: storage, defaults: defaults)
        guard case .resume(let intent) = restarted.model.recoveryOffer else {
            Issue.record("expected an offer")
            return
        }
        #expect(intent.context.itinerary.stop?.label == "Fuel")
        #expect(restarted.spy.routeRequests == 0 && !restarted.model.isRiding, "offering requests nothing")
        restarted.model.resumeRecovery()
        let request = restarted.spy.requests.last
        #expect(request?.reason == .recovery && request?.fix.measuredAfter != nil)
        #expect(request?.target == restarted.fuel.coordinate, "resumes the leg it was on")
        restarted.spy.pendingRoute?(.success(restarted.spy.options))
        restarted.model.startNavigation()
        #expect(restarted.model.ride?.id == intent.context.id && restarted.model.recoveryOffer == nil)
    }

    @Test func endedRidesAndDamagedRecordsAreNotOffered() throws {
        let storage = TestStorage.directory()
        let defaults = UserDefaults(suiteName: "Recovery-\(UUID())")!
        let first = RideHarness(storage: storage, defaults: defaults)
        first.model.recovery.setEnabled(true)
        first.startRide()
        first.model.stopNavigation()
        #expect(RideHarness(storage: storage, defaults: defaults).model.recoveryOffer == nil)

        try Data("{not json".utf8).write(to: storage.appendingPathComponent("recovery.json"))
        let damaged = RideHarness(storage: storage, defaults: defaults)
        #expect(damaged.model.recoveryOffer == nil && damaged.model.recovery.problem != nil)
        #expect(damaged.spy.routeRequests == 0)
    }

    @Test func recoveryOffStoresNothing() {
        let h = RideHarness()
        h.startRide()
        #expect(!FileManager.default.fileExists(atPath: h.storage.appendingPathComponent("recovery.json").path))
    }
}

@MainActor
struct HistoryFlowTests {
    @Test func historyIsOptInAndOneRowPerRide() {
        let h = RideHarness()
        h.startRide()
        h.emit(.arrived)
        h.model.stopNavigation()
        #expect(!FileManager.default.fileExists(atPath: h.storage.appendingPathComponent("history.json").path),
                "nothing written while history is off")

        h.model.history.setEnabled(true)
        h.wait()
        h.startRide()
        h.emit()
        h.emit(.arrived)
        h.model.stopNavigation()
        #expect(h.model.history.rides.count == 1 && h.model.history.rides[0].outcome == .completed)
        let file = try? String(contentsOf: h.storage.appendingPathComponent("history.json"), encoding: .utf8)
        #expect(file?.contains("77.59") == false && file?.contains("Office") == false, "no positions or place names")
        h.model.history.delete(h.model.history.rides[0].id)
        #expect(h.model.history.rides.isEmpty)
    }

    @Test func disablingMidRideDiscardsTheRecording() {
        let h = RideHarness()
        h.model.history.setEnabled(true)
        h.startRide()
        h.model.history.setEnabled(false)
        h.model.stopNavigation()
        #expect(h.model.history.rides.isEmpty)
    }

    @Test func aStoppedAppLeavesAnInterruptedRide() {
        let storage = TestStorage.directory()
        let store = RideHistoryStore(directory: storage, now: Date(timeIntervalSince1970: 1_800_000_000))
        store.setEnabled(true)
        let id = RideID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        store.begin(id, startedAt: start, now: start)
        store.add(LocationFix(coordinate: Coordinate(latitude: 12.97, longitude: 77.59)!, horizontalAccuracy: 5,
                              observedAt: MonotonicInstant(offset: .seconds(1))), now: start.addingTimeInterval(61))
        let reopened = RideHistoryStore(directory: storage, now: start.addingTimeInterval(3_600))
        #expect(reopened.rides.map(\.outcome) == [.interrupted] && !reopened.isFinished(id))
    }
}

@MainActor
struct VoiceAdapterTests {
    let clock = ManualClock()
    let speech = FakeSpeech()
    let audio = FakeAudio()
    let session = SessionID()

    func snapshot(_ metres: Int, generation: Int = 0, state: NavigationState = .active) -> NavigationSnapshot {
        NavigationSnapshot(session: session, generation: RouteGeneration(generation), observedAt: clock.now, state: state,
                           step: GuidanceStep(maneuver: .turnLeft, distanceMetres: metres, sequence: 1),
                           remainingMetres: 1_000, remainingSeconds: 100)
    }

    @Test func overlappingHoldsResumeNothingUntilAllClear() {
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        audio.onInterruption?(true)
        voice.callChanged(true)
        audio.headsetRemoved()
        audio.onInterruption?(false)
        voice.callChanged(false)
        voice.handle(snapshot(250), eligible: true)
        #expect(speech.texts.isEmpty, "the headset hold remains")
        #expect(voice.holdReason?.contains("Headset") == true)
        voice.allowSpeaker()
        #expect(speech.texts.isEmpty, "clearing the holds replays nothing")
        voice.handle(snapshot(240), eligible: true)
        #expect(speech.texts == ["In 250 metres, turn left."], "only the current, never-spoken stage")
    }

    @Test func staleOrObsoletePromptsAreNotSpoken() {
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        voice.handle(snapshot(250), eligible: false)
        #expect(speech.texts.isEmpty, "no turn on stale guidance")
        voice.handle(snapshot(240), eligible: true)
        voice.handle(snapshot(50), eligible: true)
        #expect(speech.texts == ["In 250 metres, turn left."], "one prompt speaking, the next waits")
        voice.handle(snapshot(250, generation: 1), eligible: true)
        speech.finish(1)
        #expect(speech.texts == ["In 250 metres, turn left.", "In 250 metres, turn left."],
                "the old route's pending 'Now' was dropped; the new route speaks")
        speech.finish(1)
        #expect(speech.texts.count == 2, "a stale completion is ignored")
    }

    @Test func voiceOffAndFailedActivationLeaveNothingActive() {
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        voice.handle(snapshot(250), eligible: true)
        voice.setEnabled(false)
        #expect(audio.log.last == "deactivate" && speech.stops == 1)
        voice.setEnabled(true)
        audio.activationSucceeds = false
        voice.handle(snapshot(50), eligible: true)
        #expect(voice.holdReason == "Audio unavailable - voice can't play.")
    }

    @Test func testAudioIsRateLimited() {
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        voice.test()
        voice.test()
        clock.advance(by: .seconds(3))
        voice.test()
        #expect(speech.texts.count == 2)
    }
}

@MainActor
struct BikeSetupTests {
    @Test func visualStepsNeedTheRidersAnswer() {
        let h = RideHarness()
        let setup = h.model.setup
        setup.begin()
        setup.next()
        #expect(setup.step == .connect)
        setup.next()
        #expect(setup.step == .connect && setup.message == "Connect to the bike on the Bike tab first.")
        var report = BikeCapabilityReport(appVersion: "1", calibration: BikeCapabilityReport.calibration, date: Date())
        report.gatt = .pass
        report.clearTransport = .pass
        #expect(report.verdict.hasPrefix("Inconclusive"), "a transport acknowledgement is not a visual check")
        for sample in BikeSetupModel.samples { report.samples[sample.id] = .pass }
        report.stopFrameVisual = .pass
        #expect(report.verdict == "Works as tested (parked)")
        report.samples["left"] = .fail
        #expect(report.verdict == "Not compatible as tested")
        #expect(!report.isCurrent(statusProfile: .legacy55), "evidence is tied to the status profile it used")
    }
}
