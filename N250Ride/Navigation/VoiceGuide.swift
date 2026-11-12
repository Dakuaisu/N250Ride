import AVFoundation
import RideCore

/// Spoken turn prompts through whatever audio route is active (helmet intercom,
/// earphones or speaker). Other audio is ducked while speaking, then restored.
@MainActor
final class VoiceGuide: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var planner = VoicePromptPlanner()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func reset() {
        planner = VoicePromptPlanner()
        synthesizer.stopSpeaking(at: .immediate)
    }

    func handle(_ snapshot: NavigationSnapshot) {
        guard let text = planner.prompt(for: snapshot) else { return }
        speak(text)
    }

    func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-IN") ?? AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func finished() {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension VoiceGuide: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
