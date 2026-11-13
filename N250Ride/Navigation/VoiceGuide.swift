import AVFoundation
import Observation
import RideCore

/// Speaks text; reports when an utterance with a given tag finished or was cancelled.
@MainActor
protocol SpeechClient: AnyObject {
    var onFinish: ((Int) -> Void)? { get set }
    func speak(_ text: String, tag: Int)
    func stop()
}

enum AudioRouteChange: Equatable {
    /// The output in use went away (headset unplugged or disconnected).
    case outputLost
    /// A new output appeared.
    case outputAdded
    case other
}

/// The system audio session, behind a seam so interruption and route handling is testable.
@MainActor
protocol AudioSessionClient: AnyObject {
    var onInterruption: ((Bool) -> Void)? { get set }
    var onRouteChange: ((AudioRouteChange) -> Void)? { get set }
    var outputName: String { get }
    var isExternalOutput: Bool { get }
    /// Configures for spoken prompts and activates; false when the system refused.
    func activate() -> Bool
    func deactivate()
}

/// Spoken directions through whatever output the system chose (helmet, earphones,
/// or the phone speaker when allowed). Holds at most the prompt being spoken and one
/// pending prompt; anything for another route or after a hold is dropped, never
/// replayed. Calls, interruptions and a lost headset each hold speech independently.
///
/// A turn prompt is spoken only while it is still true: same route and maneuver,
/// guidance eligible, and its position measurement not yet expired. It is checked
/// again right before speaking, and a turn being spoken is cut off when it stops being true.
@MainActor
@Observable
final class VoiceGuide {
    enum Hold: Hashable {
        case call, interruption, speakerFallback
    }

    private(set) var holds: Set<Hold> = []
    private(set) var outputName: String
    private(set) var activationFailed = false
    var style: VoiceStyle {
        didSet { planner.style = style }
    }

    @ObservationIgnored private let speech: SpeechClient
    @ObservationIgnored private let audio: AudioSessionClient
    @ObservationIgnored private let clock: RideClock
    @ObservationIgnored private var planner: VoicePromptPlanner
    @ObservationIgnored private var enabled = true
    @ObservationIgnored private var current: (tag: Int, prompt: VoicePrompt)?
    @ObservationIgnored private var pending: VoicePrompt?
    @ObservationIgnored private var latest: NavigationSnapshot?
    @ObservationIgnored private var nextTag = 0
    @ObservationIgnored private var lastTestAt: MonotonicInstant?
    @ObservationIgnored private var eligible = false

    static let testInterval: Duration = .seconds(3)

    init(speech: SpeechClient, audio: AudioSessionClient, clock: RideClock, style: VoiceStyle = .detailed) {
        self.speech = speech
        self.audio = audio
        self.clock = clock
        self.style = style
        planner = VoicePromptPlanner(style: style)
        outputName = audio.outputName
        speech.onFinish = { [weak self] in self?.finished($0) }
        audio.onInterruption = { [weak self] began in self?.interruption(began) }
        audio.onRouteChange = { [weak self] in self?.routeChanged($0) }
    }

    /// Why speech is paused, for ride health; nil when it isn't.
    var holdReason: String? {
        if holds.contains(.call) { return "Voice paused during the call." }
        if holds.contains(.speakerFallback) { return "Headset disconnected - voice paused. Allow the phone speaker?" }
        if holds.contains(.interruption) { return "Voice paused by another app." }
        if activationFailed { return "Audio unavailable - voice can't play." }
        return nil
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on { silence() }
    }

    /// A new ride or leg: forget every stage spoken so far.
    func reset() {
        planner = VoicePromptPlanner(style: style)
        latest = nil
        silence()
    }

    /// Ride health's verdict, updated whenever it changes (including measurement expiry
    /// with no new snapshot). Losing eligibility drops every turn prompt at once.
    func setEligible(_ on: Bool) {
        eligible = on
        dropObsoleteTurns()
    }

    /// `eligible` is ride health's verdict: turns are spoken only on current guidance.
    func handle(_ snapshot: NavigationSnapshot, eligible: Bool) {
        if let latest, latest.session != snapshot.session || latest.generation != snapshot.generation {
            silence()
        }
        latest = snapshot
        self.eligible = eligible
        dropObsoleteTurns()
        // Held or stale turns are not planned at all, so a stage that was never
        // spoken can still be spoken once it is current and allowed again.
        guard enabled, holds.isEmpty, eligible || snapshot.state != .active,
              let prompt = planner.next(for: snapshot) else { return }
        enqueue(prompt)
    }

    /// The current instruction again; refused while held or not current.
    func repeatCurrent(eligible: Bool) {
        guard enabled, holds.isEmpty, eligible, let latest, let text = planner.repeatPrompt(for: latest) else { return }
        self.eligible = eligible
        pending = nil
        if current != nil { speech.stop() }
        current = nil
        let prompt = VoicePrompt(text: text, priority: .turn, session: latest.session, generation: latest.generation,
                                 step: latest.step?.sequence, validUntil: VoicePromptPlanner.validity(latest))
        guard isCurrent(prompt) else { return }
        say(prompt)
    }

    /// A short sample on the current output, at most once every three seconds.
    func test() {
        let now = clock.now
        if let lastTestAt, now.duration(since: lastTestAt) < Self.testInterval { return }
        lastTestAt = now
        guard holds.subtracting([.speakerFallback]).isEmpty else { return }
        say(VoicePrompt(text: "This is N250 Ride. Directions will sound like this.", priority: .status,
                        session: SessionID(), generation: RouteGeneration(0)))
    }

    func callChanged(_ active: Bool) {
        setHold(.call, active)
    }

    /// Explicit permission to use the phone speaker after the headset went away.
    func allowSpeaker() {
        setHold(.speakerFallback, false)
    }

    // MARK: Scheduling

    private func enqueue(_ prompt: VoicePrompt) {
        guard let current else { return say(prompt) }
        if prompt.priority > current.prompt.priority {
            pending = nil
            speech.stop()
            self.current = nil
            say(prompt)
        } else if pending == nil || prompt.priority >= pending!.priority {
            pending = prompt
        }
    }

    private func say(_ prompt: VoicePrompt) {
        guard audio.activate() else {
            activationFailed = true
            return
        }
        activationFailed = false
        nextTag += 1
        current = (nextTag, prompt)
        speech.speak(prompt.text, tag: nextTag)
    }

    private func finished(_ tag: Int) {
        guard current?.tag == tag else { return }
        current = nil
        let next = pending
        pending = nil
        if let next, holds.isEmpty, isCurrent(next) {
            say(next)
        } else {
            audio.deactivate()
        }
    }

    /// Whether a prompt is still true right now. Status prompts stay valid; a turn
    /// needs eligible guidance on the same route and maneuver and an unexpired measurement.
    private func isCurrent(_ prompt: VoicePrompt) -> Bool {
        guard prompt.priority == .turn else { return true }
        guard eligible, let latest, latest.state == .active, latest.session == prompt.session,
              latest.generation == prompt.generation, latest.step?.sequence == prompt.step else { return false }
        return prompt.validUntil.map { clock.now < $0 } ?? true
    }

    private func dropObsoleteTurns() {
        if let pending, !isCurrent(pending) { self.pending = nil }
        if let current, !isCurrent(current.prompt) {
            self.current = nil
            speech.stop()
            audio.deactivate()
        }
    }

    private func silence() {
        pending = nil
        if current != nil {
            current = nil
            speech.stop()
        }
        audio.deactivate()
    }

    private func setHold(_ hold: Hold, _ on: Bool) {
        if on {
            holds.insert(hold)
            silence()
        } else {
            holds.remove(hold)
        }
    }

    private func interruption(_ began: Bool) {
        setHold(.interruption, began)
    }

    private func routeChanged(_ change: AudioRouteChange) {
        let wasExternal = outputName != "iPhone"
        outputName = audio.outputName
        switch change {
        case .outputLost where wasExternal && !audio.isExternalOutput:
            setHold(.speakerFallback, true)
        case .outputAdded where audio.isExternalOutput:
            setHold(.speakerFallback, false)
        default:
            break
        }
    }
}

// MARK: Real clients

@MainActor
final class SystemSpeechClient: NSObject, SpeechClient, AVSpeechSynthesizerDelegate {
    var onFinish: ((Int) -> Void)?
    private let synthesizer = AVSpeechSynthesizer()
    private var tags: [ObjectIdentifier: Int] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, tag: Int) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        tags[ObjectIdentifier(utterance)] = tag
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        // Cancelled utterances may not all report back; their tags are retired here.
        tags.removeAll()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated { done(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        MainActor.assumeIsolated { done(id) }
    }

    private func done(_ id: ObjectIdentifier) {
        guard let tag = tags.removeValue(forKey: id) else { return }
        onFinish?(tag)
    }
}

@MainActor
final class SystemAudioSessionClient: AudioSessionClient {
    var onInterruption: ((Bool) -> Void)?
    var onRouteChange: ((AudioRouteChange) -> Void)?
    private let session = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []
    private var active = false

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { self?.onInterruption?(began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let change: AudioRouteChange = switch reason {
            case .oldDeviceUnavailable: .outputLost
            case .newDeviceAvailable: .outputAdded
            default: .other
            }
            MainActor.assumeIsolated { self?.onRouteChange?(change) }
        })
    }

    var outputName: String {
        let output = session.currentRoute.outputs.first
        return output?.portType == .builtInSpeaker || output == nil ? "iPhone" : output?.portName ?? "iPhone"
    }

    var isExternalOutput: Bool {
        session.currentRoute.outputs.contains { ![.builtInSpeaker, .builtInReceiver].contains($0.portType) }
    }

    func activate() -> Bool {
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true)
            active = true
            return true
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            active = false
            return false
        }
    }

    func deactivate() {
        guard active else { return }
        active = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
