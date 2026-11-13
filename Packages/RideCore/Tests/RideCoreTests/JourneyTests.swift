import Foundation
import Testing
@testable import RideCore

private let home = Coordinate(latitude: 12.97, longitude: 77.59)!
private let fuel = Coordinate(latitude: 12.95, longitude: 77.60)!

@Suite("Itinerary with one stop")
struct ItineraryTests {
    let twoLeg = RideContext(itinerary: Itinerary(final: destination("Office", home), stop: destination("Fuel", fuel)))!

    @Test func stopArrivalWaitsForContinue() throws {
        guard case .reachedStop(let atStop) = ItineraryPolicy.arrival(twoLeg) else {
            Issue.record("expected the stop")
            return
        }
        #expect(atStop.phase == .atStop && atStop.id == twoLeg.id)
        #expect(ItineraryPolicy.arrival(atStop) == .ignored, "a repeated arrival does not advance")
        let onward = try ItineraryPolicy.continueToFinal(atStop).get()
        #expect(onward.phase == .toFinal && onward.activeTarget.label == "Office")
        #expect(ItineraryPolicy.arrival(onward) == .completed)
    }

    @Test func skipAndAddFollowTheRules() throws {
        let skipped = try ItineraryPolicy.skipStop(twoLeg).get()
        #expect(skipped.activeTarget.label == "Office" && skipped.itinerary.stop != nil)
        #expect(ItineraryPolicy.continueToFinal(twoLeg) == .failure(.wrongPhase))
        let direct = RideContext(itinerary: Itinerary(final: destination("Office", home)))!
        let withStop = try ItineraryPolicy.addStop(destination("ATM", fuel), to: direct).get()
        #expect(withStop.phase == .toStop && withStop.activeTarget.label == "ATM")
        #expect(ItineraryPolicy.addStop(destination("Second"), to: withStop) == .failure(.alreadyHasStop))
    }
}

@Suite("Recovery journal")
struct RecoveryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var context: RideContext { RideContext(itinerary: Itinerary(final: destination("Office", home)))! }

    @Test func currentRideIsOffered() throws {
        let intent = RideIntent(context: context, startedAt: now.addingTimeInterval(-600), checkpointAt: now.addingTimeInterval(-60))
        let journal = RecoveryJournal(lastCommitted: intent)
        #expect(RecoveryPolicy.offer(for: journal, now: now, suppressed: []) == .resume(intent))
        let decoded = try JSONDecoder().decode(RecoveryJournal.self, from: JSONEncoder().encode(journal))
        #expect(decoded == journal)
    }

    @Test func expiredFutureAndFinishedRidesAreNotOffered() {
        let old = RideIntent(context: context, startedAt: now, checkpointAt: now.addingTimeInterval(-RecoveryPolicy.lifetime))
        #expect(RecoveryPolicy.offer(for: RecoveryJournal(lastCommitted: old), now: now, suppressed: []) == nil)
        let future = RideIntent(context: context, startedAt: now, checkpointAt: now.addingTimeInterval(3_600))
        #expect(RecoveryPolicy.offer(for: RecoveryJournal(lastCommitted: future), now: now, suppressed: []) == nil)
        let done = RideIntent(context: context, startedAt: now, checkpointAt: now)
        #expect(RecoveryPolicy.offer(for: RecoveryJournal(lastCommitted: done), now: now, suppressed: [done.context.id]) == nil)
    }

    @Test func unfinishedStartIsShownAsUnfinishedNotAsStarted() {
        let previous = RideIntent(context: context, startedAt: now, checkpointAt: now)
        let pending = PendingStart(context: context, reason: "replacement", recordedAt: now)
        let offer = RecoveryPolicy.offer(for: RecoveryJournal(lastCommitted: previous, pendingStart: pending), now: now, suppressed: [])
        #expect(offer == .unfinishedStart(pending, previous: previous))
    }
}

@Suite("Ride history accumulation")
struct RideAccumulatorTests {
    func fix(_ x: Double, _ y: Double, t: Int, accuracy: Double = 5) -> LocationFix {
        LocationFix(coordinate: at(x, y), horizontalAccuracy: accuracy, observedAt: MonotonicInstant(offset: .seconds(t)))
    }

    @Test func countsDistinguishableMovement() {
        var a = RideAccumulator()
        for (i, y) in stride(from: 0.0, through: 1_000, by: 100).enumerated() { a.add(fix(0, y, t: i * 10)) }
        #expect(abs(a.estimatedMetres - 1_000) < 10, "within the test grid's flat-earth approximation")
        #expect(a.activeSeconds == 100)
    }

    @Test func ignoresJitterJumpsDuplicatesAndBadFixes() {
        var a = RideAccumulator()
        a.add(fix(0, 0, t: 0))
        for t in 1...20 { a.add(fix(Double(t % 2) * 3, 0, t: t)) }
        #expect(a.estimatedMetres == 0, "3 m wobble inside 5 m accuracy is noise")
        a.add(fix(0, 5_000, t: 21))
        #expect(a.estimatedMetres == 0, "5 km in one second is not a ride")
        a.add(fix(0, 5_000, t: 21))
        a.add(fix(0, 5_200, t: 31, accuracy: 60))
        #expect(a.estimatedMetres == 0, "imprecise fix is ignored")
        #expect(a.activeSeconds == 31)
    }

    @Test func longGapsAndBreaksAreNotBridged() {
        var a = RideAccumulator(baselineSeconds: 50, baselineMetres: 400)
        a.add(fix(0, 0, t: 0))
        a.add(fix(0, 900, t: 200))
        #expect(a.estimatedMetres == 400 && a.activeSeconds == 50, "a 200 s gap is not travel time or distance")
        a.breakSegment()
        a.add(fix(0, 2_000, t: 210))
        a.add(fix(0, 2_100, t: 220))
        #expect(abs(a.estimatedMetres - 500) < 2)
    }

    @Test func historyKeepsOneNewestRowPerRideWithinRetention() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = RideID()
        let epoch = UUID()
        func summary(_ id: RideID, revision: Int, age: TimeInterval) -> RideSummary {
            RideSummary(id: id, startedAt: now.addingTimeInterval(-age), lastObservedAt: now.addingTimeInterval(-age),
                        activeSeconds: 1, estimatedMetres: 1, outcome: .interrupted, revision: revision, consentEpoch: epoch)
        }
        let rows = RideHistoryPolicy.pruned([summary(id, revision: 1, age: 10), summary(id, revision: 3, age: 5),
                                             summary(RideID(), revision: 1, age: RideHistoryPolicy.maxAge)], now: now)
        #expect(rows.count == 1 && rows.first?.revision == 3)
    }
}

@Suite("Voice policy")
struct VoicePolicyTests {
    let session = SessionID()

    func active(_ maneuver: Maneuver, _ metres: Int, session: SessionID? = nil, sequence: Int = 1) -> NavigationSnapshot {
        NavigationSnapshot(session: session ?? self.session, generation: RouteGeneration(0),
                           observedAt: MonotonicInstant(offset: .zero), state: .active,
                           step: GuidanceStep(maneuver: maneuver, distanceMetres: metres, roadText: "MG Road", sequence: sequence),
                           remainingMetres: 5_000, remainingSeconds: 600)
    }

    @Test func conciseDropsTheEarlyWarningAndRoadNames() {
        var planner = VoicePromptPlanner(style: .concise)
        let spoken = [1_100, 250, 40].compactMap { planner.prompt(for: active(.turnLeft, $0)) }
        #expect(spoken == ["In 250 metres, turn left.", "Now, turn left."])
    }

    @Test func sameStepInANewSessionIsANewPrompt() {
        var planner = VoicePromptPlanner()
        _ = planner.prompt(for: active(.turnLeft, 250))
        #expect(planner.prompt(for: active(.turnLeft, 240)) == nil)
        let restarted = planner.next(for: active(.turnLeft, 240, session: SessionID()))
        #expect(restarted?.text == "In 250 metres, turn left onto MG Road.")
        #expect(restarted?.priority == .turn)
    }

    @Test func repeatOnlyWhileGuidanceIsActive() {
        let planner = VoicePromptPlanner()
        #expect(planner.repeatPrompt(for: active(.turnRight, 430)) == "In 450 metres, turn right onto MG Road.")
        var stale = active(.turnRight, 430)
        stale.state = .noLocation
        #expect(planner.repeatPrompt(for: stale) == nil)
    }

    @Test func statusPromptsOutrankTurns() {
        var planner = VoicePromptPlanner()
        var rerouting = active(.turnLeft, 200)
        rerouting.state = .rerouting
        #expect(planner.next(for: rerouting)?.priority == .status)
    }
}
