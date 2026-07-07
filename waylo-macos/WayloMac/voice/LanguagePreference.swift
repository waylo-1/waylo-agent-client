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
    var recognizer: SFSpeechRecognizer? {
        if let r = SFSpeechRecognizer(locale: Locale(identifier: rawValue)), r.isAvailable || r.supportsOnDeviceRecognition || true {
            // SFSpeechRecognizer(locale:) returns nil for unsupported locales;
            // isAvailable can be transiently false (network) — accept non-nil.
            return r
        }
        DebugLogger.log("LANG", "no STT for \(rawValue) — falling back to en-US")
        return SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// TTS voice; nil lets AVSpeech pick the system default (utterances with a
    /// nil voice still speak, so an unsupported language degrades gracefully).
    var voice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: rawValue)
    }
}
