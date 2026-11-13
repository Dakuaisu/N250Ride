import Foundation
import RideCore
@testable import N250Ride

@MainActor
final class FakeSpeech: SpeechClient {
    var onFinish: ((Int) -> Void)?
    private(set) var spoken: [(text: String, tag: Int)] = []
    private(set) var stops = 0

    func speak(_ text: String, tag: Int) { spoken.append((text, tag)) }
    func stop() { stops += 1 }

    /// The synthesizer finished the utterance with this tag.
    func finish(_ tag: Int? = nil) { onFinish?(tag ?? spoken.last?.tag ?? 0) }
    var texts: [String] { spoken.map(\.text) }
}

@MainActor
final class FakeAudio: AudioSessionClient {
    var onInterruption: ((Bool) -> Void)?
    var onRouteChange: ((AudioRouteChange) -> Void)?
    var outputName = "Helmet"
    var isExternalOutput = true
    var activationSucceeds = true
    private(set) var log: [String] = []

    func activate() -> Bool {
        log.append(activationSucceeds ? "activate" : "activate-failed")
        return activationSucceeds
    }

    func deactivate() { log.append("deactivate") }

    func headsetRemoved() {
        outputName = "iPhone"
        isExternalOutput = false
        onRouteChange?(.outputLost)
    }

    func headsetConnected() {
        outputName = "Helmet"
        isExternalOutput = true
        onRouteChange?(.outputAdded)
    }
}

@MainActor
final class FakeCalls: CallStateSource {
    var onChange: ((Bool) -> Void)?
    var callInProgress = false

    func set(_ active: Bool) {
        callInProgress = active
        onChange?(active)
    }
}

@MainActor
final class FakeActivitySink: ActivitySink {
    enum Call: Equatable {
        case start(String)
        case update(headline: String, staleDate: Date?)
        case end
        case endAll
    }

    private(set) var calls: [Call] = []
    /// Simulates a slow ActivityKit: each update waits this long before recording.
    var updateDelay: Duration = .zero

    func start(destination: String, state: RideActivityAttributes.ContentState) -> String? {
        calls.append(.start(destination))
        return "activity"
    }

    func update(_ id: String, state: RideActivityAttributes.ContentState, staleDate: Date?) async {
        if updateDelay > .zero { try? await Task.sleep(for: updateDelay) }
        calls.append(.update(headline: state.headline, staleDate: staleDate))
    }

    func end(_ id: String) async { calls.append(.end) }
    func endAll() async { calls.append(.endAll) }

    var staleDates: [Date?] {
        calls.compactMap { if case .update(_, let date) = $0 { date } else { nil } }
    }
}

enum TestStorage {
    static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("N250RideTests-\(UUID().uuidString)", isDirectory: true)
    }
}

extension AppDependencies {
    /// Real time (for tests that rely on the route gate's debounce), fake platform services.
    @MainActor
    static func test(storage: URL = TestStorage.directory(), calls: FakeCalls = FakeCalls(),
                     speech: FakeSpeech = FakeSpeech(), audio: FakeAudio = FakeAudio()) -> AppDependencies {
        AppDependencies(clock: SystemRideClock(), timers: SystemRideTimers(), storage: storage, calls: calls,
                        speech: speech, audio: audio, liveActivities: false, activitySink: FakeActivitySink())
    }

    /// Virtual time: nothing happens until the test advances the timers.
    @MainActor
    static func virtual(_ timers: ManualRideTimers, storage: URL = TestStorage.directory(), calls: FakeCalls = FakeCalls(),
                        speech: FakeSpeech = FakeSpeech(), audio: FakeAudio = FakeAudio(),
                        activities: FakeActivitySink? = nil) -> AppDependencies {
        AppDependencies(clock: timers.clock, timers: timers, storage: storage, calls: calls, speech: speech, audio: audio,
                        liveActivities: activities != nil, activitySink: activities ?? FakeActivitySink())
    }
}
