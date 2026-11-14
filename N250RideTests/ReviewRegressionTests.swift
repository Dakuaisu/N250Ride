import Foundation
import RideCore
import Testing
@testable import N250Ride

/// One regression per finding in docs/repository-review-and-roadmap.md.
@MainActor
struct ReviewRegressionTests {
    // MARK: H1 stale speech

    @Test func h1QueuedTurnDoesNotSpeakAfterMeasurementExpiry() {
        let clock = ManualClock()
        let speech = FakeSpeech(), audio = FakeAudio()
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        let session = SessionID()
        func turn(_ metres: Int) -> NavigationSnapshot {
            NavigationSnapshot(session: session, generation: RouteGeneration(0), observedAt: clock.now, state: .active,
                               step: GuidanceStep(maneuver: .turnLeft, distanceMetres: metres, sequence: 1),
                               remainingMetres: 900, remainingSeconds: 90, measurementAt: clock.now)
        }
        voice.handle(turn(250), eligible: true)
        voice.handle(turn(50), eligible: true)
        #expect(speech.texts == ["In 250 metres, turn left."], "the 'Now' prompt is pending")
        clock.advance(by: .seconds(5))
        voice.setEligible(false)
        speech.finish(1)
        #expect(speech.texts.count == 1, "measurement expired while waiting: the pending turn is dropped")
        #expect(audio.log.last == "deactivate")
    }

    @Test func h1LosingEligibilityCutsCurrentTurnAndDropsPending() {
        let clock = ManualClock()
        let speech = FakeSpeech(), audio = FakeAudio()
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        let session = SessionID()
        let snap = { (m: Int, seq: Int) in
            NavigationSnapshot(session: session, generation: RouteGeneration(0), observedAt: clock.now, state: .active,
                               step: GuidanceStep(maneuver: .turnLeft, distanceMetres: m, sequence: seq),
                               remainingMetres: 900, remainingSeconds: 90, measurementAt: clock.now)
        }
        voice.handle(snap(250, 1), eligible: true)
        voice.handle(snap(50, 1), eligible: true)
        voice.setEligible(false)
        #expect(speech.stops == 1, "the turn being spoken is cut off")
        speech.finish(1)
        #expect(speech.texts.count == 1, "and the pending one never plays")
    }

    @Test func h1NewStepWithoutPromptDropsTheOldStepsPendingTurn() {
        let clock = ManualClock()
        let speech = FakeSpeech(), audio = FakeAudio()
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        let session = SessionID()
        let snap = { (m: Int, seq: Int) in
            NavigationSnapshot(session: session, generation: RouteGeneration(0), observedAt: clock.now, state: .active,
                               step: GuidanceStep(maneuver: .turnLeft, distanceMetres: m, sequence: seq),
                               remainingMetres: 900, remainingSeconds: 90, measurementAt: clock.now)
        }
        voice.handle(snap(250, 1), eligible: true)
        voice.handle(snap(50, 1), eligible: true)
        voice.handle(snap(2_000, 2), eligible: true)
        speech.finish(1)
        #expect(speech.texts.count == 1, "step 1's 'Now' is obsolete once step 2 is current")
    }

    @Test func h1ExpiryWithoutSnapshotSilencesTheRide() {
        let h = RideHarness()
        h.startRide()
        h.emit(metres: 250)
        h.emit(metres: 50)
        #expect(h.speech.texts == ["In 250 metres, turn left."])
        h.timers.advance(by: .seconds(5))
        #expect(h.speech.stops >= 1, "expiry cuts the turn even with no new snapshot")
        h.speech.finish()
        #expect(h.speech.texts.count == 1)
    }

    // MARK: M1 Live Activity expiry

    @Test func m1EqualContentStillRenewsTheStaleDate() async {
        let timers = ManualRideTimers(clock: ManualClock())
        let sink = FakeActivitySink()
        let activity = RideLiveActivity(enabled: true, sink: sink, timers: timers, now: { timers.clock.wallNow })
        activity.start(destination: "Office")
        let session = SessionID()
        let health = RideHealthEvaluator.evaluate(RideHealthInput(
            phase: .navigating, position: .measured(age: .seconds(1), accuracy: 5), navigationState: .active,
            intent: .clear(.noSession), route: .ok, link: .ready, delivery: .guidanceSubmitted, voice: .ok))
        let snapshot = NavigationSnapshot(session: session, generation: RouteGeneration(0), observedAt: timers.clock.now,
                                          state: .active, step: GuidanceStep(maneuver: .turnLeft, distanceMetres: 300),
                                          remainingMetres: 900, remainingSeconds: 90)
        for second in 0..<8 {
            activity.update(snapshot, health: health, linkReady: true,
                            staleDate: timers.clock.wallNow.addingTimeInterval(5))
            timers.advance(by: .seconds(1))
            _ = second
        }
        await activity.settle()
        let dates = sink.staleDates.compactMap { $0 }
        #expect(dates.count >= 3, "renewals keep coming while the rider is stationary")
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) <= 3 },
                "each renewal arrives before the previous expiry")
    }

    @Test func m1ThrottledChangeIsDeliveredLaterAndEndWins() async {
        let timers = ManualRideTimers(clock: ManualClock())
        let sink = FakeActivitySink()
        let activity = RideLiveActivity(enabled: true, sink: sink, timers: timers, now: { timers.clock.wallNow })
        activity.minimumInterval = 10
        activity.start(destination: "Office")
        let health = RideHealthEvaluator.evaluate(RideHealthInput(
            phase: .navigating, position: .measured(age: .seconds(1), accuracy: 5), navigationState: .active,
            intent: .clear(.noSession), route: .ok, link: .ready, delivery: .guidanceSubmitted, voice: .ok))
        func snap(_ m: Int) -> NavigationSnapshot {
            NavigationSnapshot(session: SessionID(), generation: RouteGeneration(0), observedAt: timers.clock.now, state: .active,
                               step: GuidanceStep(maneuver: .turnLeft, distanceMetres: m), remainingMetres: 900,
                               remainingSeconds: 90)
        }
        activity.update(snap(300), health: health, linkReady: true, staleDate: nil)
        timers.advance(by: .seconds(1))
        activity.update(snap(250), health: health, linkReady: true, staleDate: nil)
        timers.advance(by: .seconds(10))
        await activity.settle()
        #expect(sink.calls.contains(.update(headline: "250 m", staleDate: nil)), "the held change still arrives")
        activity.update(snap(200), health: health, linkReady: true, staleDate: nil)
        activity.end()
        timers.advance(by: .seconds(20))
        await activity.settle()
        #expect(sink.calls.last == .end, "nothing is submitted after End")
    }

    // MARK: M2 Start and cancellation

    @Test func m2StartWaitingPastExpiryNeverCommits() {
        let h = RideHarness()
        h.spy.holdStartChecks = true
        h.model.propose(h.office, label: "Office")
        h.model.confirmDestination(label: "Office", saveAsFavourite: false)
        h.spy.pendingRoute?(.success(h.spy.options))
        h.timers.advance(by: .seconds(119))
        h.model.startNavigation()
        #expect(h.model.startStatus == .checking)
        h.timers.advance(by: .seconds(2))
        #expect(h.spy.cancelledStartChecks.count == 1, "the outstanding position check is abandoned")
        h.spy.startCheck = .ready
        h.spy.heldStartCheck?(.ready)
        #expect(h.spy.committed.isEmpty && !h.model.isRiding)
    }

    @Test func m2CancelStopsGPSImmediately() {
        let timers = ManualRideTimers(clock: ManualClock())
        let location = FakeLocation(), directions = FakeDirections()
        let provider = AppleNavigationProvider(clock: timers.clock, timers: timers,
                                               defaults: UserDefaults(suiteName: "m2-\(UUID())")!,
                                               location: location, directions: directions)
        let request = NavigationRouteRequest(
            operationID: UUID(), session: SessionID(), generation: RouteGeneration(0),
            target: Coordinate(latitude: 12.97, longitude: 77.59)!, title: "Office", preferences: RoutePreferences(),
            reason: .initial, alternatives: true, fix: .current)
        var answered = false
        provider.prepareRoute(request) { _ in answered = true }
        #expect(location.isRunning && provider.hasPendingFixWait)
        provider.cancelPreparation(request.operationID)
        #expect(!location.isRunning && !provider.hasPendingFixWait, "no waiter keeps GPS on after cancel")
        timers.advance(by: .seconds(20))
        #expect(!answered && timers.pending == 0)
    }

    // MARK: M3 stop arrival during a reroute

    @Test func m3ArrivalAtStopRetiresTheRerouteSoContinueWorks() {
        let h = RideHarness()
        h.startRide(stop: h.fuel)
        h.wait()
        h.model.requestReroute(.manual)
        #expect(h.model.routeOperation == .preparing(.manual))
        h.emit(.arrived)
        #expect(h.model.routeOperation == .idle && h.spy.cancelled.count == 1)
        h.wait()
        h.model.continueToFinal()
        #expect(h.spy.requests.last?.reason == .nextLeg, "Continue isn't blocked by the abandoned reroute")
        h.timers.advance(by: .seconds(26))
        guard case .requesting = h.model.stage else {
            Issue.record("the reroute's old 30 s deadline must not end leg two's calculation: \(h.model.stage)")
            return
        }
        #expect(h.model.routeOperation == .idle)
    }

    // MARK: M4 unreadable records are preserved

    @Test func m4FutureSchemaFilesAreNeverOverwritten() throws {
        let storage = TestStorage.directory()
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let future = Data(#"{"schemaVersion": 99, "payload": "from the future"}"#.utf8)
        for name in ["inbox.json", "history.json", "recovery.json"] {
            try future.write(to: storage.appendingPathComponent(name))
        }
        let defaults = UserDefaults(suiteName: "m4-\(UUID())")!
        let h = RideHarness(storage: storage, defaults: defaults)
        h.model.recovery.setEnabled(true)
        h.model.handleIncoming("Fuel https://maps.apple.com/?ll=12.95,77.58&q=Fuel")
        h.model.history.setEnabled(true)
        h.startRide()
        for name in ["inbox.json", "history.json"] {
            #expect(try Data(contentsOf: storage.appendingPathComponent(name)) == future, "\(name) kept as it was")
        }
        #expect(h.model.inbox.isBlocked && h.model.history.isBlocked)
        h.model.inbox.discardStored()
        #expect(!h.model.inbox.isBlocked)
        #expect(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("inbox.json").path))
    }

    @Test func m4RecoveryWithUnreadableJournalDoesNotOverwrite() throws {
        let storage = TestStorage.directory()
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let future = Data(#"{"schemaVersion": 99, "payload": {}}"#.utf8)
        try future.write(to: storage.appendingPathComponent("recovery.json"))
        let defaults = UserDefaults(suiteName: "m4r-\(UUID())")!
        defaults.set(true, forKey: "recoveryEnabled")
        let h = RideHarness(storage: storage, defaults: defaults)
        h.startRide()
        #expect(try Data(contentsOf: storage.appendingPathComponent("recovery.json")) == future)
        #expect(h.model.recovery.problem != nil)
    }

    // MARK: M5 failed writes don't diverge

    static func failingIO(failWrites: Bool = true, failBackup: Bool = false) -> RecordIO {
        RecordIO(write: { data, url in
            if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try RecordIO.real.write(data, url)
        }, excludeFromBackup: { url in
            if failBackup { throw CocoaError(.fileWriteNoPermission) }
            try RecordIO.real.excludeFromBackup(url)
        })
    }

    @Test func m5FailedStatusChangeKeepsTheOldState() {
        let storage = TestStorage.directory()
        let good = IncomingInbox(directory: storage, now: Date())
        guard case .added(let id) = good.add(coordinate: Coordinate(latitude: 12, longitude: 77)!, label: "A", link: nil,
                                             now: Date()) else {
            Issue.record("add failed")
            return
        }
        let failing = IncomingInbox(directory: storage, now: Date(), io: Self.failingIO())
        #expect(!failing.setStatus(id, .accepted))
        #expect(failing.item(id)?.status == .pending, "memory matches disk")
        #expect(!failing.discard(id))
        #expect(failing.item(id) != nil, "a failed delete doesn't pretend to have deleted")
    }

    @Test func m5AcceptanceMustBeStoredBeforeAnyRequest() throws {
        let storage = TestStorage.directory()
        let h = RideHarness(storage: storage)
        h.model.handleIncoming("Fuel https://maps.apple.com/?ll=12.95,77.58&q=Fuel")
        guard case .confirming = h.model.stage else {
            Issue.record("expected confirmation")
            return
        }
        // Make the inbox file unwritable: replace the directory's file with a directory of the same name.
        let file = storage.appendingPathComponent("inbox.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        h.model.confirmDestination(label: "Fuel", saveAsFavourite: false)
        #expect(h.spy.routeRequests == 0, "no dispatch without a stored acceptance")
        guard case .failed = h.model.stage else {
            Issue.record("expected a visible failure")
            return
        }
    }

    @Test func m5BackupMetadataFailureIsAWarningNotALostSave() throws {
        let storage = TestStorage.directory()
        let inbox = IncomingInbox(directory: storage, now: Date(), io: Self.failingIO(failWrites: false, failBackup: true))
        let result = inbox.add(coordinate: Coordinate(latitude: 12, longitude: 77)!, label: "A", link: nil, now: Date())
        guard case .added = result else {
            Issue.record("the bytes were written, so the add stands")
            return
        }
        #expect(inbox.problem?.contains("backups") == true)
        #expect(IncomingInbox(directory: storage, now: Date()).items.count == 1)
    }

    @Test func m5FailedHistoryDeleteIsReported() {
        let storage = TestStorage.directory()
        let store = RideHistoryStore(directory: storage, now: Date())
        store.setEnabled(true)
        let id = RideID()
        store.begin(id, startedAt: Date(), now: Date())
        store.finish(.completed, now: Date())
        let failing = RideHistoryStore(directory: storage, now: Date(), io: Self.failingIO())
        #expect(!failing.delete(id))
        #expect(failing.rides.count == 1)
    }

    // MARK: M6 two-leg history

    @Test func m6BothLegsAreInTheOneSummary() {
        let storage = TestStorage.directory()
        let store = RideHistoryStore(directory: storage, now: Date(timeIntervalSince1970: 1_800_000_000))
        store.setEnabled(true)
        let id = RideID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func fix(_ y: Double, _ t: Int) -> LocationFix {
            LocationFix(coordinate: Coordinate(latitude: 12.97 + y / 110_574, longitude: 77.59)!, horizontalAccuracy: 5,
                        observedAt: MonotonicInstant(offset: .seconds(t)))
        }
        store.begin(id, startedAt: start, now: start)
        for (i, y) in stride(from: 0.0, through: 500, by: 100).enumerated() { store.add(fix(y, i * 10), now: start) }
        store.breakSegment()
        store.continueRide(id)
        for (i, y) in stride(from: 5_000.0, through: 5_500, by: 100).enumerated() { store.add(fix(y, 600 + i * 10), now: start) }
        store.finish(.completed, now: start.addingTimeInterval(700))
        let ride = store.rides.first
        #expect(store.rides.count == 1)
        #expect((ride?.estimatedMetres ?? 0) > 950 && (ride?.estimatedMetres ?? 0) < 1_050, "both legs, no gap")
        #expect(ride?.activeSeconds == 100)
    }

    @Test func m6ResumeRecordsOnlyRidesThatWereBeingRecorded() {
        let storage = TestStorage.directory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = RideHistoryStore(directory: storage, now: now)
        store.setEnabled(true)
        let unrecorded = RideID()
        store.resume(unrecorded, now: now)
        #expect(!store.isRecording, "started with history off: not recorded after resume")
        let recorded = RideID()
        store.begin(recorded, startedAt: now, now: now)
        let reopened = RideHistoryStore(directory: storage, now: now.addingTimeInterval(60))
        reopened.resume(recorded, now: now.addingTimeInterval(60))
        #expect(reopened.isRecording)
    }

    // MARK: M7 completion ownership

    @Test func m7EachRawWriteGetsItsOwnAnswerAndPumpAnswersStayWithThePump() {
        var router = WriteCompletionRouter()
        let alert = PhonePackets.alertCharacteristic
        guard case .success(let first) = router.beginRaw(alert, pumpBusyOn: nil),
              case .success(let second) = router.beginRaw(alert, pumpBusyOn: nil) else {
            Issue.record("refused")
            return
        }
        #expect(router.complete(alert) == .raw(id: first))
        #expect(router.complete(alert) == .raw(id: second), "the second answer isn't handed to the pump")
        #expect(router.complete(alert) == .none, "an answer nobody asked for completes nothing")
        #expect(router.complete(ClusterGATT.generalStatus) == .pump(.status))
        #expect(router.beginRaw(ClusterGATT.generalStatus, pumpBusyOn: .status) == .failure(.channelBusy),
                "raw and pump writes never share a channel's answers")
        router.reset()
        #expect(router.complete(alert) == .none)
    }

    // MARK: M8 wizard evidence

    @Test func m8WizardDoesNotPassOnAnOldClear() {
        let transport = RecordingTransport()
        let clock = ManualClock()
        let coordinator = SessionCoordinator(clock: clock)
        let pump = ClusterWritePump(transport: transport, clock: clock, link: ClusterLinkInfo(
            navigationWriteMode: .withResponse, statusWriteMode: .withResponse, maximumWriteLength: 244))
        coordinator.linkReady(pump)
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(coordinator.delivery == .clearTransportAcknowledged, "a clear from link setup")
        let id = coordinator.requestFreshClear()!
        #expect(transport.writes.count == 2, "a brand-new clear was sent")
        #expect(coordinator.clearRequestOutcome(id) == nil, "unanswered: not a pass")
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(coordinator.clearRequestOutcome(id) == .clearTransportAcknowledged)
    }

    @Test func m8DisappearanceNeedsAnObservedArrow() {
        let h = RideHarness()
        let setup = h.model.setup
        setup.begin()
        setup.observeStopFrame(.pass)
        #expect(setup.report.stopFrameVisual == .notRun, "can't record a disappearance first")
        setup.observeArrow(.fail)
        #expect(setup.report.stopFrameVisual == .inconclusive)
    }

    // MARK: M9 preferences

    @Test func m9RerouteUsesTheCurrentPreferences() {
        let h = RideHarness()
        h.startRide()
        h.model.routePreferences.avoidTolls = true
        h.wait()
        h.model.requestReroute(.manual)
        #expect(h.spy.requests.last?.preferences.avoidTolls == true)
        h.spy.pendingReroute?(.failure(.network))
        #expect(h.model.ride?.preferences.avoidTolls == false, "a failed reroute doesn't change the ride")
        h.wait()
        h.model.requestReroute(.manual)
        h.spy.pendingReroute?(.success(()))
        #expect(h.model.ride?.preferences.avoidTolls == true, "committed with the route")
    }

    // MARK: L1 wording

    @Test func l1FooterSaysWhatIsKnown() {
        #expect(DashboardIntentView.text(.clear(.noSession), .linkDown)
                == "Dashboard clear requested - not navigating (bike not connected)")
        #expect(DashboardIntentView.text(.clear(.stale), .clearHandedOffWithoutResponse).hasSuffix("(sent, not acknowledged)"))
        #expect(!DashboardIntentView.text(.clear(.stale), .clearTransportAcknowledged).contains("cleared"))
    }

    // MARK: Quick wins

    @Test func oversizedSharedTextIsNotParsed() {
        let big = String(repeating: "x", count: MapLinkParser.maxInputBytes) + " 12.9716, 77.5946"
        #expect(MapLinkParser.parse(big) == nil)
        #expect(MapLinkParser.parse("12.9716, 77.5946") != nil)
    }
}


/// Second review round: one regression per remaining finding.
@MainActor
struct SecondReviewRegressionTests {
    func turn(_ metres: Int, session: SessionID, clock: ManualClock) -> NavigationSnapshot {
        NavigationSnapshot(session: session, generation: RouteGeneration(0), observedAt: clock.now, state: .active,
                           step: GuidanceStep(maneuver: .turnLeft, distanceMetres: metres, sequence: 1),
                           remainingMetres: 900, remainingSeconds: 90, measurementAt: clock.now)
    }

    // 1
    @Test func testAudioReplacesASpeakingTurn() {
        let clock = ManualClock()
        let speech = FakeSpeech(), audio = FakeAudio()
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        let session = SessionID()
        voice.handle(turn(250, session: session, clock: clock), eligible: true)
        voice.handle(turn(50, session: session, clock: clock), eligible: true)
        voice.test()
        #expect(speech.stops == 1, "the speaking turn is stopped, not left playing behind the sample")
        #expect(speech.texts.last?.hasPrefix("This is N250 Ride") == true)
        clock.advance(by: .seconds(5))
        voice.setEligible(false)
        speech.finish()
        #expect(speech.texts.count == 2, "the pending turn never plays after the sample")
    }

    // 2
    @Test func failedResolveDoesNotExpandTheLinkAgain() async throws {
        let storage = TestStorage.directory()
        let h = RideHarness(storage: storage)
        var expansions = 0
        h.model.expandLink = { _ in
            expansions += 1
            let file = storage.appendingPathComponent("inbox.json")
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            return URL(string: "https://maps.apple.com/?ll=12.95,77.58&q=Fuel")
        }
        h.model.handleIncoming("https://maps.app.goo.gl/abc")
        for _ in 0..<50 where h.model.linkMessage == "Opening shared link…" { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(expansions == 1)
        #expect(h.model.linkMessage == "Found the place, but couldn't save it on this phone. Try again later.")
        #expect(h.model.stage == .choosing)
    }

    // 3
    @Test func endingARideKeepsAnUnreadableRecoveryFile() throws {
        let storage = TestStorage.directory()
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let future = Data(#"{"schemaVersion": 99, "payload": {}}"#.utf8)
        let file = storage.appendingPathComponent("recovery.json")
        try future.write(to: file)
        let defaults = UserDefaults(suiteName: "r3-\(UUID())")!
        defaults.set(true, forKey: "recoveryEnabled")
        let h = RideHarness(storage: storage, defaults: defaults)
        h.startRide()
        h.model.stopNavigation()
        #expect(try Data(contentsOf: file) == future, "ending the ride is not an explicit discard")
        #expect(h.model.recovery.isBlocked)
        h.model.discardRecovery()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // 4
    @Test func restartAtTheStopKeepsBothLegsInHistory() {
        let storage = TestStorage.directory()
        let defaults = UserDefaults(suiteName: "r4-\(UUID())")!
        func feed(_ h: RideHarness, from: Double, to: Double) {
            for y in stride(from: from, through: to, by: 100) {
                h.timers.advance(by: .seconds(10))
                let place = Coordinate(latitude: 12.97 + y / 110_574, longitude: 77.59)!
                h.spy.onFix?(AdmittedFix(sample: LocationSample(coordinate: place, horizontalAccuracy: 5,
                                                                timestamp: h.clock.wallNow),
                                         measuredAt: h.clock.now, expiresAt: h.clock.now + .seconds(5)))
            }
        }
        let first = RideHarness(storage: storage, defaults: defaults)
        first.model.recovery.setEnabled(true)
        first.model.history.setEnabled(true)
        first.startRide(stop: first.fuel)
        feed(first, from: 0, to: 500)
        first.emit(.arrived)
        guard case .atStop = first.model.stage else {
            Issue.record("expected the stop")
            return
        }

        let second = RideHarness(storage: storage, defaults: defaults)
        second.model.resumeRecovery()
        guard case .atStop = second.model.stage else {
            Issue.record("resume restores the stop")
            return
        }
        #expect(second.model.history.isRecording, "recording carries on after the restart")
        second.wait()
        second.model.continueToFinal()
        second.spy.pendingRoute?(.success(second.spy.options))
        second.model.startNavigation()
        feed(second, from: 5_000, to: 5_500)
        second.emit(.arrived)
        let rides = second.model.history.rides
        #expect(rides.count == 1 && rides.first?.outcome == .completed)
        let metres = rides.first?.estimatedMetres ?? 0
        #expect(metres > 950 && metres < 1_050, "both legs, no gap across the stop: \(metres)")
    }

    // 5
    @Test func finalArrivalRetiresAPendingReroute() {
        let h = RideHarness()
        h.startRide()
        h.wait()
        h.model.requestReroute(.manual)
        h.emit(.arrived)
        #expect(h.model.routeOperation == .idle && h.spy.cancelled.count == 1)
        h.spy.pendingReroute?(.success(()))
        #expect(h.spy.committed.count == 1, "the late reroute doesn't commit after arrival")
        h.timers.advance(by: .seconds(31))
        #expect(h.model.routeOperation == .idle, "and its deadline shows no error")
        h.wait()
        h.model.requestReroute(.manual)
        #expect(h.spy.rerouteRequests.count == 1, "no recalculation after arriving")
    }

    // 6
    func healthy() -> RideHealth {
        RideHealthEvaluator.evaluate(RideHealthInput(
            phase: .navigating, position: .measured(age: .seconds(1), accuracy: 5), navigationState: .active,
            intent: .clear(.noSession), route: .ok, link: .ready, delivery: .guidanceSubmitted, voice: .ok))
    }

    func snap(_ m: Int, _ clock: ManualClock) -> NavigationSnapshot {
        NavigationSnapshot(session: SessionID(), generation: RouteGeneration(0), observedAt: clock.now, state: .active,
                           step: GuidanceStep(maneuver: .turnLeft, distanceMetres: m), remainingMetres: 900,
                           remainingSeconds: 90)
    }

    @Test func energyModeRenewsFreshnessWhileTextIsHeld() async {
        let timers = ManualRideTimers(clock: ManualClock())
        let sink = FakeActivitySink()
        let activity = RideLiveActivity(enabled: true, sink: sink, timers: timers, now: { timers.clock.wallNow })
        activity.minimumInterval = 10
        activity.start(destination: "Office")
        let start = timers.clock.wallNow
        for second in 0..<15 {
            activity.update(snap(second == 0 ? 300 : 250, timers.clock), health: healthy(), linkReady: true,
                            staleDate: timers.clock.wallNow.addingTimeInterval(5))
            timers.advance(by: .seconds(1))
        }
        await activity.settle()
        let dates = sink.staleDates.compactMap { $0 }
        #expect(dates.count >= 5)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $1.timeIntervalSince($0) <= 3 },
                "renewals keep the shown content fresh while the text change is held: \(dates.map { $0.timeIntervalSince(start) })")
        #expect(sink.calls.contains { if case .update("250 m", _) = $0 { true } else { false } },
                "the held text still arrives")
    }

    @Test func returningToTheShownTextDropsTheHeldChange() async {
        let timers = ManualRideTimers(clock: ManualClock())
        let sink = FakeActivitySink()
        let activity = RideLiveActivity(enabled: true, sink: sink, timers: timers, now: { timers.clock.wallNow })
        activity.minimumInterval = 10
        activity.start(destination: "Office")
        activity.update(snap(300, timers.clock), health: healthy(), linkReady: true, staleDate: nil)
        timers.advance(by: .seconds(1))
        activity.update(snap(250, timers.clock), health: healthy(), linkReady: true, staleDate: nil)
        timers.advance(by: .seconds(1))
        activity.update(snap(300, timers.clock), health: healthy(), linkReady: true, staleDate: nil)
        timers.advance(by: .seconds(30))
        await activity.settle()
        #expect(!sink.calls.contains { if case .update("250 m", _) = $0 { true } else { false } },
                "the obsolete held change is never submitted")
    }

    @Test func slowSinkStillEndsLast() async {
        let timers = ManualRideTimers(clock: ManualClock())
        let sink = FakeActivitySink()
        sink.updateDelay = .milliseconds(30)
        let activity = RideLiveActivity(enabled: true, sink: sink, timers: timers, now: { timers.clock.wallNow })
        activity.start(destination: "Office")
        for m in [300, 200, 100] {
            activity.update(snap(m, timers.clock), health: healthy(), linkReady: true,
                            staleDate: timers.clock.wallNow.addingTimeInterval(5))
            timers.advance(by: .seconds(3))
        }
        activity.end()
        timers.advance(by: .seconds(30))
        await activity.settle()
        #expect(sink.calls.last == .end)
    }

    // 8
    @Test func pumpWaitsForARawWriteOnItsChannel() {
        let transport = RecordingTransport()
        let pump = ClusterWritePump(transport: transport, clock: ManualClock(), link: ClusterLinkInfo(
            navigationWriteMode: .withResponse, statusWriteMode: .withResponse, maximumWriteLength: 244))
        var router = WriteCompletionRouter()
        pump.isChannelHeld = { router.holds($0) }
        guard case .success(let raw) = router.beginRaw(ClusterGATT.generalStatus, pumpBusyOn: nil) else {
            Issue.record("refused")
            return
        }
        pump.submitStatus([1, 2, 3])
        #expect(transport.writes.isEmpty, "the app's status waits for the console's answer")
        pump.submitNavigation(TbtFrame.start())
        #expect(transport.writes.count == 1, "navigation isn't held up")
        pump.didCompleteWrite(on: .navigation, success: true)
        #expect(router.complete(ClusterGATT.generalStatus) == .raw(id: raw))
        #expect(!router.isPending(raw))
        pump.channelReleased()
        #expect(transport.writes.last == [1, 2, 3])
    }
}


/// Third review round.
@MainActor
struct ThirdReviewRegressionTests {
    // 2
    @Test func recoveryOffAtLaunchStillKeepsAnUnreadableFile() throws {
        let storage = TestStorage.directory()
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let future = Data(#"{"schemaVersion": 99, "payload": {}}"#.utf8)
        let file = storage.appendingPathComponent("recovery.json")
        try future.write(to: file)
        let h = RideHarness(storage: storage)
        h.startRide()
        h.model.stopNavigation()
        #expect(try Data(contentsOf: file) == future, "recovery off: the file is never touched")
        h.model.recovery.setEnabled(true)
        h.wait()
        h.startRide()
        h.model.stopNavigation()
        #expect(try Data(contentsOf: file) == future, "enabled mid-session: checked before any cleanup")
    }

    // 3
    @Test func arrivalAtTheStopInsideStartIsNotOverwritten() {
        let storage = TestStorage.directory()
        let defaults = UserDefaults(suiteName: "r3s-\(UUID())")!
        let h = RideHarness(storage: storage, defaults: defaults)
        h.model.recovery.setEnabled(true)
        h.model.history.setEnabled(true)
        h.spy.onStartGuidance = { h.emit(.arrived) }
        h.startRide(stop: h.fuel)
        guard case .atStop = h.model.stage else {
            Issue.record("expected the stop, got \(h.model.stage)")
            return
        }
        #expect(h.model.ride?.phase == .atStop)
        #expect(h.model.history.isRecording, "leg one's recording carries on to leg two")
        let restarted = RideHarness(storage: storage, defaults: defaults)
        guard case .resume(let intent) = restarted.model.recoveryOffer else {
            Issue.record("expected an offer")
            return
        }
        #expect(intent.context.phase == .atStop, "the checkpoint at the stop is not replaced by leg one")
    }

    @Test func arrivalAtTheDestinationInsideStartFinishesTheRide() {
        let storage = TestStorage.directory()
        let defaults = UserDefaults(suiteName: "r3f-\(UUID())")!
        let h = RideHarness(storage: storage, defaults: defaults)
        h.model.recovery.setEnabled(true)
        h.model.history.setEnabled(true)
        h.spy.onStartGuidance = { h.emit(.arrived) }
        h.startRide()
        #expect(!h.model.history.isRecording, "a finished ride is not recorded again")
        #expect(h.model.history.rides.map(\.outcome) == [.completed])
        #expect(RideHarness(storage: storage, defaults: defaults).model.recoveryOffer == nil,
                "a finished ride is not offered for recovery")
    }
}


/// Fourth review round.
@MainActor
struct FourthReviewRegressionTests {
    // 1
    @Test func noStopCanBeAddedAfterArrival() {
        let storage = TestStorage.directory()
        let defaults = UserDefaults(suiteName: "r4a-\(UUID())")!
        let h = RideHarness(storage: storage, defaults: defaults)
        h.model.recovery.setEnabled(true)
        h.model.history.setEnabled(true)
        h.startRide()
        h.emit(.arrived)
        h.wait()
        let requests = h.spy.requests.count
        h.model.addStop(RideDestination(coordinate: h.fuel.coordinate, label: "Fuel", provenance: .shared))
        #expect(h.spy.requests.count == requests, "a finished journey isn't reopened")
        #expect(h.model.routeOperation == .failed(.replacement, "You've arrived. End this ride, then start a new one from there."))
        let restarted = RideHarness(storage: storage, defaults: defaults)
        #expect(restarted.model.history.rides.map(\.outcome) == [.completed])
        #expect(restarted.model.recoveryOffer == nil)
    }

    // 2
    func reachStop(_ h: RideHarness) {
        h.model.recovery.setEnabled(true)
        h.model.history.setEnabled(true)
        h.startRide(stop: h.fuel)
        h.emit(.arrived)
        h.wait()
        h.model.continueToFinal()
    }

    @Test func closingTheSecondLegWhileCalculatingEndsTheJourney() {
        let storage = TestStorage.directory()
        let defaults = UserDefaults(suiteName: "r4b-\(UUID())")!
        let h = RideHarness(storage: storage, defaults: defaults)
        reachStop(h)
        guard case .requesting = h.model.stage else {
            Issue.record("expected leg two calculating, got \(h.model.stage)")
            return
        }
        h.model.endRideForDiagnostics()
        let restarted = RideHarness(storage: storage, defaults: defaults)
        #expect(restarted.model.recoveryOffer == nil, "the abandoned journey isn't offered again")
        #expect(restarted.model.history.rides.map(\.outcome) == [.endedByRider])
    }

    @Test func closingTheSecondLegPreviewEndsTheJourney() {
        let storage = TestStorage.directory()
        let defaults = UserDefaults(suiteName: "r4c-\(UUID())")!
        let h = RideHarness(storage: storage, defaults: defaults)
        reachStop(h)
        h.spy.pendingRoute?(.success(h.spy.options))
        guard case .preview = h.model.stage else {
            Issue.record("expected leg two preview, got \(h.model.stage)")
            return
        }
        h.model.endRideForDiagnostics()
        let restarted = RideHarness(storage: storage, defaults: defaults)
        #expect(restarted.model.recoveryOffer == nil)
        #expect(restarted.model.history.rides.map(\.outcome) == [.endedByRider])
    }

    // 3
    final class FailSwitch: @unchecked Sendable {
        var fail = false
    }

    @Test func failedOptOutStillHoldsAfterRestart() {
        let storage = TestStorage.directory()
        let defaults = UserDefaults(suiteName: "r4d-\(UUID())")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fail = FailSwitch()
        let io = RecordIO(write: { data, url in
            if fail.fail { throw CocoaError(.fileWriteOutOfSpace) }
            try RecordIO.real.write(data, url)
        }, excludeFromBackup: { try RecordIO.real.excludeFromBackup($0) })
        let store = RideHistoryStore(directory: storage, now: now, defaults: defaults, io: io)
        store.setEnabled(true)
        let ride = RideID()
        store.begin(ride, startedAt: now, now: now)
        fail.fail = true
        store.setEnabled(false)
        #expect(!store.enabled && !store.isRecording, "recording stops at once")
        #expect(store.problem?.hasPrefix("History is off") == true, "the failed save is reported")

        let reopened = RideHistoryStore(directory: storage, now: now.addingTimeInterval(60), defaults: defaults)
        #expect(!reopened.enabled, "the opt-out isn't reverted by the restart")
        reopened.resume(ride, now: now.addingTimeInterval(60))
        #expect(!reopened.isRecording, "and the interrupted ride doesn't resume recording")
        let again = RideHistoryStore(directory: storage, now: now.addingTimeInterval(120), defaults: defaults)
        #expect(!again.enabled, "once stored, it stays off")
    }
}


/// Voice cut off mid-instruction (ride report, 2026-11-14).
@MainActor
struct VoiceCutoffTests {
    let clock = ManualClock()
    let speech = FakeSpeech()
    let audio = FakeAudio()
    let session = SessionID()

    func snap(_ metres: Int, sequence: Int = 3, generation: Int = 0) -> NavigationSnapshot {
        NavigationSnapshot(session: session, generation: RouteGeneration(generation), observedAt: clock.now, state: .active,
                           step: GuidanceStep(maneuver: .roundaboutClockwise, roundaboutExit: 3, roundaboutDirection: .right,
                                              distanceMetres: metres, roadText: "Jan Marg", sequence: sequence),
                           remainingMetres: 2_000, remainingSeconds: 200, measurementAt: clock.now)
    }

    @Test func aLongInstructionFinishesWhileFreshFixesKeepComing() {
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        voice.handle(snap(290), eligible: true)
        for t in 1...7 {
            clock.advance(by: .seconds(1))
            voice.handle(snap(290 - 10 * t), eligible: true)
        }
        #expect(speech.stops == 0, "a 6-7 s instruction isn't cut at 5 s")
    }

    @Test func passingTheTurnMidSentenceDoesNotCutIt() {
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        voice.handle(snap(40), eligible: true)
        clock.advance(by: .seconds(2))
        voice.handle(snap(900, sequence: 4), eligible: true)
        #expect(speech.stops == 0)
        #expect(speech.texts.count == 1)
    }

    @Test func gpsLossAndRouteChangeStillCutIt() {
        let voice = VoiceGuide(speech: speech, audio: audio, clock: clock)
        voice.handle(snap(290), eligible: true)
        voice.setEligible(false)
        #expect(speech.stops == 1, "GPS lost: the instruction may be wrong now")
        voice.setEligible(true)
        voice.handle(snap(50), eligible: true)
        voice.handle(snap(300, generation: 1), eligible: true)
        #expect(speech.stops == 2, "new route: the old instruction is cut")
    }
}

final class RecordingTransport: ClusterWriteTransport {
    var canSendWriteWithoutResponse = true
    private(set) var writes: [[UInt8]] = []
    func maximumWriteLength(for mode: WriteMode) -> Int { 244 }
    func write(_ bytes: [UInt8], to channel: ClusterChannel, mode: WriteMode) { writes.append(bytes) }
}
