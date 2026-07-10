import Foundation
import Speech
import AVFoundation

/// The user's spoken-language preference. Drives BOTH speech recognition
/// (MicHandler) and TTS (Speaker). Plan instructions arrive already localized
/// from the backend (its langdetect reads the task text), so once the user
/// speaks Hindi, the whole loop is Hindi: STT → plan → spoken steps.
enum LanguagePreference: String, CaseIterable {
    case english = "en-US"
    case hindi = "hi-IN"
    case punjabi = "pa-IN"

    static let defaultsKey = "waylo.speechLanguage"

    static var current: LanguagePreference {
        get {
            LanguagePreference(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .hindi: return "हिन्दी"
        case .punjabi: return "ਪੰਜਾਬੀ"
        }
    }

    /// A recognizer for this language, falling back to en-US when the OS has
    /// no model for it (Apple's STT coverage varies — Punjabi in particular
    /// may be unavailable; the fallback keeps voice input working).
    /// SFSpeechRecognizer(locale:) returns nil for unsupported locales;
    /// isAvailable can be transiently false (network), so nil is the only
    /// signal we act on here.
    var recognizer: SFSpeechRecognizer? {
        if let r = SFSpeechRecognizer(locale: Locale(identifier: rawValue)) {
            return r
        }
        DebugLogger.log("LANG", "no STT for \(rawValue) — falling back to en-US")
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// TTS voice — picks the HIGHEST-QUALITY installed voice for this language
    /// (premium > enhanced > default). The default compact voices sound
    /// robotic / wrong-accented, especially for Hindi; a premium Siri voice is
    /// far better but must be downloaded by the user (see `voiceQualityHint`).
    /// nil lets AVSpeech fall back to the system default.
    var voice: AVSpeechSynthesisVoice? {
        let prefix = String(rawValue.prefix(2))  // "hi", "pa", "en"
        let matching = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
        guard !matching.isEmpty else {
            DebugLogger.log("TTS", "no installed voice for \(rawValue) — using system default")
            return AVSpeechSynthesisVoice(language: rawValue)
        }
        // Rank by quality: .premium (3) > .enhanced (2) > .default (1).
        let best = matching.max { rank($0.quality) < rank($1.quality) }
        if let best = best {
            DebugLogger.log("TTS", "voice for \(rawValue): '\(best.name)' quality=\(qualityName(best.quality))")
        }
        return best
    }

    private func rank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
        switch q {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    private func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return "default(compact)"
        }
    }

    /// True when only the low-quality compact voice is installed for this
    /// language — the panel can then prompt the user to download a better one.
    var hasOnlyCompactVoice: Bool {
        let prefix = String(rawValue.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        return !voices.isEmpty && voices.allSatisfy { $0.quality == .default }
    }
}
