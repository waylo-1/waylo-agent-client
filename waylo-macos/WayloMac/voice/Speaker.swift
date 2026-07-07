import AVFoundation

/// Thin wrapper around AVSpeechSynthesizer for spoken step instructions.
/// Access is serialized through the synthesizer; safe to mark @unchecked Sendable
/// so the `static let shared` singleton compiles cleanly under strict concurrency.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        // The user's language preference (en/hi/pa). Instructions arrive
        // localized from the backend, so speak them in that language too.
        // A nil voice (no TTS for the locale) falls back to the system voice.
        utterance.voice = LanguagePreference.current.voice
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.45            // Slightly slower than default for clarity.
        utterance.pitchMultiplier = 1.0
        utterance.volume = 0.9
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
}
