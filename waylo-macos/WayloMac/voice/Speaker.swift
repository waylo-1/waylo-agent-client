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
        // localized from the backend, so speak them in that language too. Pick the
        // HIGHEST-quality installed voice for that language (premium/enhanced/Siri)
        // instead of the tinny default "compact" voice; falls back gracefully.
        let base = LanguagePreference.current.voice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.voice = Self.bestVoice(forLanguage: base?.language ?? "en-US") ?? base
        utterance.rate = 0.48            // Natural, clear cadence.
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    /// The best-sounding installed voice for a language: prefer premium, then
    /// enhanced, then Siri voices, then anything but the low-quality compact
    /// default. Cached per language so we don't rescan on every utterance.
    private static var voiceCache: [String: AVSpeechSynthesisVoice] = [:]
    static func bestVoice(forLanguage language: String) -> AVSpeechSynthesisVoice? {
        let lang = language.lowercased()
        if let cached = voiceCache[lang] { return cached }
        let prefix = String(lang.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(prefix)
        }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = 0
            switch v.quality {
            case .premium:  s += 300   // downloadable "Siri"/premium — most natural
            case .enhanced: s += 200
            default:        s += 0     // compact — the robotic default
            }
            if v.language.lowercased() == lang { s += 20 }        // exact locale (en-US)
            if v.identifier.lowercased().contains("siri") { s += 50 }
            if v.identifier.lowercased().contains("eloquence") { s -= 100 } // novelty
            return s
        }
        let best = candidates.max { score($0) < score($1) }
        if let best { voiceCache[lang] = best }
        DebugLogger.log("TTS", "best voice for \(lang): \(best?.name ?? "none") quality=\(best.map { "\($0.quality.rawValue)" } ?? "-")")
        return best
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
}
