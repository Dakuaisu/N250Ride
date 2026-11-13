import Foundation
import RideCore
import Testing
@testable import N250Ride

@MainActor
struct ManualChecklistTests {
    let sections = ManualChecklist.sections(statusProfile: .legacy55)
    var checks: [ManualChecklist.Check] { sections.flatMap(\.checks) }
    var steps: [BluetoothConsole.Preset] { checks.flatMap(\.steps) }

    @Test func everyCheckHasAUniqueIDAndSomethingToDo() {
        #expect(Set(checks.map(\.id)).count == checks.count)
        #expect(checks.allSatisfy { !$0.steps.isEmpty || $0.howTo != nil })
    }

    @Test func everyStepIsAWellFormedPacketForItsChannel() {
        for step in steps {
            switch step.target {
            case ClusterGATT.navigation:
                #expect(TbtFrame.hasValidChecksum(step.bytes), "\(step.name)")
            case ClusterGATT.generalStatus:
                #expect(step.bytes.count == GeneralStatusProfile.legacy55.length, "\(step.name)")
            default:
                #expect(!step.bytes.isEmpty, "\(step.name)")
            }
        }
        #expect(Set(sections.flatMap { $0.checks.flatMap(\.steps) }.filter { $0.target == ClusterGATT.generalStatus }
            .map(\.bytes)).count > 1)
    }

    @Test func manualScreensAndReroutingCandidatesAreCovered() throws {
        let navigation = steps.filter { $0.target == ClusterGATT.navigation }.map(\.bytes)
        let icons = Set(navigation.map { $0[1] })
        for icon: UInt8 in [ClusterIcon.wrongWay, 77, 83, 87, ClusterIcon.destinationReached,
                            ClusterIcon.uTurnLeft, ClusterIcon.turnLeft + ClusterIcon.blinkOffset] {
            #expect(icons.contains(icon), "icon \(icon)")
        }
        let gpsValues = Set(navigation.map { ($0[12] >> 2) & 0x03 })
        #expect(gpsValues == [0, 1, 3])
        #expect(ClusterIcon.solid.allSatisfy { icon in checks.contains { $0.id == "icon.\(icon)" } })
        let callEnded = try #require(steps.first { $0.name == "Call ended" })
        #expect(callEnded.endsStatusTest)
    }

    @Test func resultsAreKeptAndReported() {
        let defaults = UserDefaults(suiteName: "ManualChecklistTests-\(UUID())")!
        let checklist = ManualChecklist(defaults: defaults)
        checklist.set("reroute.wrongway", outcome: .asManual)
        checklist.set("reroute.wrongway", note: "REROUTING shown")
        let reopened = ManualChecklist(defaults: defaults)
        #expect(reopened.result("reroute.wrongway") == .init(outcome: .asManual, note: "REROUTING shown"))
        #expect(reopened.tested(in: sections) == 1)
        let report = reopened.report(sections, appVersion: "1.0 (1)", statusProfile: .legacy55, consoleLog: "LOG")
        #expect(report.contains("[As manual] reroute.wrongway Wrong-way icon (66) - REROUTING shown"))
        #expect(report.contains("[Not tried] nav.turn Turn ahead"))
        #expect(report.hasSuffix("## Console log\nLOG"))
        reopened.reset()
        #expect(ManualChecklist(defaults: defaults).tested(in: sections) == 0)
    }
}
