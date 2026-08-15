import AVFoundation

/// Spoken step instructions. Two engines:
///   • "google" (remote-config voiceEngine) → natural Google Cloud TTS via the
///     backend /tts, played as MP3. Cached per phrase so repeats are instant.
///   • otherwise → on-device AVSpeechSynthesizer, using the best installed voice.
/// Google always falls back to on-device on any failure — TTS never blocks a guide.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = Speaker()

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    /// Bumped on every speak()/stop() so a slow /tts response for an old line
    /// can't play over a newer one.
    private var speakToken = 0
    /// In-memory MP3 cache keyed by "lang|text" (demo phrases repeat; also lets a
    /// warm-up run make the real take instant).
    private var audioCache: [String: Data] = [:]
    private let lock = NSLock()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        lock.lock(); speakToken += 1; let token = speakToken; lock.unlock()

        let language = (LanguagePreference.current.voice?.language) ?? "en-US"
        let useGoogle = (WayloConfig.remoteConfig("voiceEngine") as? String) == "google"

        guard useGoogle else { speakOnDevice(trimmed, language: language); return }

        // Cached audio → play immediately, no network.
        if let cached = cachedAudio(trimmed, language) {
            play(cached, token: token, fallbackText: trimmed, language: language)
            return
        }
        // Fetch from Google TTS; fall back to on-device on any miss.
        Task { [weak self] in
            guard let self else { return }
            let audio = await WayloAPIClient.shared.fetchTTS(text: trimmed, language: language)
            guard self.isCurrent(token) else { return }
            if let audio {
                self.storeAudio(audio, trimmed, language)
                self.play(audio, token: token, fallbackText: trimmed, language: language)
            } else {
                DebugLogger.log("TTS", "Google TTS unavailable — on-device fallback")
                self.speakOnDevice(trimmed, language: language)
            }
        }
    }

    func stop() {
        lock.lock(); speakToken += 1; lock.unlock()
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
    }

    var isSpeaking: Bool { synthesizer.isSpeaking || (player?.isPlaying ?? false) }

    // MARK: - Google MP3 playback

    private func play(_ data: Data, token: Int, fallbackText: String, language: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            do {
                let p = try AVAudioPlayer(data: data)
                p.volume = 1.0
                p.prepareToPlay()
                p.play()
                self.player = p
            } catch {
                DebugLogger.log("TTS", "MP3 play failed (\(error)) — on-device fallback")
                self.speakOnDevice(fallbackText, language: language)
            }
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return token == speakToken
    }

    private func cachedAudio(_ text: String, _ lang: String) -> Data? {
        lock.lock(); defer { lock.unlock() }; return audioCache["\(lang)|\(text)"]
    }
    private func storeAudio(_ data: Data, _ text: String, _ lang: String) {
        lock.lock(); audioCache["\(lang)|\(text)"] = data; lock.unlock()
    }

    // MARK: - On-device voice

    private func speakOnDevice(_ text: String, language: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        // Best-quality installed voice (premium/enhanced/Siri) for the language,
        // not the tinny compact default; falls back to the language default.
        utterance.voice = Self.bestVoice(forLanguage: language)
            ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    /// The best-sounding installed voice for a language: prefer premium, then
    /// enhanced, then Siri, then anything but the low-quality compact/novelty
    /// voices. Cached per language.
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
            case .premium:  s += 300
            case .enhanced: s += 200
            default:        s += 0
            }
            if v.language.lowercased() == lang { s += 20 }
            if v.identifier.lowercased().contains("siri") { s += 50 }
            if v.identifier.lowercased().contains("eloquence") { s -= 100 }
            if v.identifier.contains("speech.synthesis.voice") { s -= 100 } // novelty set
            return s
        }
        let best = candidates.max { score($0) < score($1) }
        if let best { voiceCache[lang] = best }
        return best
    }
}
