import Foundation
import Testing
@testable import RideCore

@Suite("Voice prompts")
struct VoicePromptTests {
    let session = SessionID()

    func active(_ maneuver: Maneuver, _ metres: Int, road: String? = "MG Road", generation: Int = 0,
                direction: RoundaboutDirection? = nil) -> NavigationSnapshot {
        NavigationSnapshot(session: session, generation: RouteGeneration(generation), observedAt: MonotonicInstant(offset: .zero),
                           state: .active,
                           step: GuidanceStep(maneuver: maneuver, roundaboutDirection: direction, distanceMetres: metres, roadText: road),
                           remainingMetres: 5_000, remainingSeconds: 600)
    }

    func state(_ s: NavigationState) -> NavigationSnapshot {
        NavigationSnapshot(session: session, generation: RouteGeneration(0), observedAt: MonotonicInstant(offset: .zero), state: s)
    }

    @Test func announcesEachStageOnceAsTheTurnApproaches() {
        var planner = VoicePromptPlanner()
        let spoken = [2_000, 1_150, 1_100, 800, 290, 250, 120, 55, 20].compactMap { planner.prompt(for: active(.turnLeft, $0)) }
        #expect(spoken == ["In 1.2 kilometres, turn left onto MG Road.",
                           "In 300 metres, turn left onto MG Road.",
                           "Now, turn left onto MG Road."])
    }

    @Test func newStepResetsStagesAndStartingCloseSkipsFarStages() {
        var planner = VoicePromptPlanner()
        _ = planner.prompt(for: active(.turnLeft, 40))
        #expect(planner.prompt(for: active(.turnRight, 150, road: "Queens Road")) == "In 150 metres, turn right onto Queens Road.")
        #expect(planner.prompt(for: active(.turnRight, 140, road: "Queens Road")) == nil)
    }

    @Test func rerouteGenerationIsANewStep() {
        var planner = VoicePromptPlanner()
        _ = planner.prompt(for: active(.turnLeft, 250))
        #expect(planner.prompt(for: active(.turnLeft, 240, generation: 1)) == "In 250 metres, turn left onto MG Road.")
    }

    @Test func statesAreAnnouncedOncePerEpisode() {
        var planner = VoicePromptPlanner()
        #expect(planner.prompt(for: state(.rerouting)) == "Rerouting.")
        #expect(planner.prompt(for: state(.rerouting)) == nil)
        #expect(planner.prompt(for: state(.noLocation)) == "GPS signal lost.")
        _ = planner.prompt(for: active(.turnLeft, 5_000))
        #expect(planner.prompt(for: state(.rerouting)) == "Rerouting.")
        #expect(planner.prompt(for: state(.arrived)) == "You have arrived.")
        #expect(planner.prompt(for: state(.arrived)) == nil)
    }

    @Test func straightAndUnsupportedStaySilentNearTheTurn() {
        var planner = VoicePromptPlanner()
        #expect(planner.prompt(for: active(.straight, 2_400, road: nil)) == "Continue straight for 2.4 kilometres.")
        #expect(planner.prompt(for: active(.straight, 50, road: nil)) == nil)
        #expect(planner.prompt(for: active(.unsupported, 50)) == nil)
    }

    @Test func roundaboutsAndArrivalPhrases() {
        var planner = VoicePromptPlanner()
        #expect(planner.prompt(for: active(.roundaboutClockwise, 280, road: "Ring Road", direction: .straight))
                == "In 300 metres, at the roundabout, go straight on, towards Ring Road.")
        #expect(planner.prompt(for: active(.arrival, 200, road: nil)) == "In 200 metres, you will arrive at your destination.")
        #expect(VoicePromptPlanner.spoken(1_000) == "1 kilometre")
        #expect(VoicePromptPlanner.spoken(20) == "50 metres")
    }
}
