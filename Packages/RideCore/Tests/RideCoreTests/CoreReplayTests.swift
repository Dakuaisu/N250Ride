import Foundation
import Testing
@testable import RideCore

@Suite("Deterministic core replay")
struct CoreReplayTests {
    /// A rider stops getting fixes: presentation refreshes keep coming, but the
    /// dashboard clears exactly five seconds after the last genuine measurement.
    static let genuineFixExpiry = """
    {"schemaVersion": 1, "events": [
      {"offset": 0, "ordinal": 0, "kind": "linkReady"},
      {"offset": 0, "ordinal": 1, "kind": "ack"},
      {"offset": 100, "ordinal": 0, "kind": "location", "x": 0, "y": 200},
      {"offset": 100, "ordinal": 1, "kind": "ack"},
      {"offset": 1100, "ordinal": 0, "kind": "refresh"},
      {"offset": 3100, "ordinal": 0, "kind": "refresh"},
      {"offset": 5099, "ordinal": 0, "kind": "tick"},
      {"offset": 5100, "ordinal": 0, "kind": "refresh"},
      {"offset": 5100, "ordinal": 1, "kind": "tick"},
      {"offset": 6000, "ordinal": 0, "kind": "location", "x": 0, "y": 230, "age": 5000},
      {"offset": 6500, "ordinal": 0, "kind": "location", "x": 0, "y": 240}
    ]}
    """

    /// The first clear fails, is sent again, and only that clear's answer counts.
    static let failedClear = """
    {"schemaVersion": 1, "events": [
      {"offset": 0, "ordinal": 0, "kind": "linkReady"},
      {"offset": 10, "ordinal": 0, "kind": "nack"},
      {"offset": 20, "ordinal": 0, "kind": "ack"},
      {"offset": 3020, "ordinal": 0, "kind": "tick"}
    ]}
    """

    @Test func refreshNeverExtendsGenuineFreshness() throws {
        let log = CoreReplayRunner().run(try ReplayTrace.load(Self.genuineFixExpiry))
        let lines = log.filter { $0.hasPrefix("t=") }
        #expect(lines[2].contains("guidance icon=74"), "first genuine fix shows the turn")
        #expect(lines[6].contains("guidance"), "4.999 s after the measurement: still fresh")
        #expect(lines[7].contains("clear stale") && lines[8].contains("clear stale"),
                "refreshes do not count as measurements")
        #expect(log.contains("rejected tooOld"), "a cached 5 s old fix is not evidence")
        #expect(lines[10].contains("guidance"), "a genuine new fix restores guidance")
    }

    @Test func failedClearIsRetriedAndAcknowledgedOnce() throws {
        let log = CoreReplayRunner().run(try ReplayTrace.load(Self.failedClear))
        #expect(log.contains("event failed(RideCore.ClusterChannel.navigation)"))
        #expect(log.filter { $0 == "event clearAcknowledged" }.count == 1)
        #expect(log.last?.contains("delivery=clearTransportAcknowledged writes=2") == true)
    }

    @Test func replayIsDeterministicOverManyRuns() throws {
        let trace = try ReplayTrace.load(Self.genuineFixExpiry)
        let first = CoreReplayRunner().run(trace)
        for _ in 0..<100 { #expect(CoreReplayRunner().run(trace) == first) }
    }

    @Test func malformedTracesAreRejected() {
        #expect(throws: ReplayTrace.Invalid.self) {
            try ReplayTrace.load(#"{"schemaVersion": 2, "events": []}"#)
        }
        #expect(throws: ReplayTrace.Invalid.self) {
            try ReplayTrace.load(#"{"schemaVersion": 1, "events": [{"offset": 5, "ordinal": 0, "kind": "tick"}, {"offset": 4, "ordinal": 0, "kind": "tick"}]}"#)
        }
        #expect(throws: ReplayTrace.Invalid.self) {
            try ReplayTrace.load(#"{"schemaVersion": 1, "events": [{"offset": 5, "ordinal": 1, "kind": "tick"}, {"offset": 5, "ordinal": 1, "kind": "tick"}]}"#)
        }
        #expect(throws: (any Error).self) {
            try ReplayTrace.load(#"{"schemaVersion": 1, "events": [{"offset": 0, "ordinal": 0, "kind": "teleport"}]}"#)
        }
    }
}
