import Speech
import AVFoundation

/// Speech-to-text using SFSpeechRecognizer for voice input.
///
/// On macOS, capturing audio needs BOTH Speech-Recognition authorization AND
/// Microphone (TCC) access. We request both up front, report partial results so
/// a transcript survives even if no "final" arrives, and log every stage so the
/// "empty transcript" failure mode is debuggable.
final class MicHandler: NSObject, SFSpeechRecognizerDelegate {
    static let shared = MicHandler()

    /// Rebuilt when the user's language preference changes (en/hi/pa).
    private var recognizer = LanguagePreference.current.recognizer
    private var recognizerLanguage = LanguagePreference.current
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var latestTranscript = ""
    private var didComplete = false
    private var completion: ((String?) -> Void)?
    private var bufferCount = 0
    /// Incremented per listen() call. Timers and recognizer callbacks from an
    /// older session carry their session id and are ignored, so a stale 6s
    /// timeout (or a cancelled task's error callback) can never finalize a
    /// NEWER listening session early.
    private var sessionID = 0

    override private init() {
        super.init()
    }

    /// Request BOTH speech recognition and microphone authorization up front.
    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            DebugLogger.log("MIC", "speech auth = \(status.rawValue) (\(Self.speechAuthName(status)))")
        }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DebugLogger.log("MIC", "microphone access granted = \(granted)")
        }
    }

    /// Listens for a single utterance and calls `completion` with the transcript.
    func listen(completion: @escaping (String?) -> Void) {
        stopListening()
        sessionID += 1
        let session = sessionID

        // Pick up a language change made in the panel since the last listen.
        let pref = LanguagePreference.current
        if pref != recognizerLanguage {
            recognizerLanguage = pref
            recognizer = pref.recognizer
            DebugLogger.log("MIC", "recognizer language → \(pref.rawValue)")
        }
        self.completion = completion
        self.latestTranscript = ""
        self.didComplete = false
        self.bufferCount = 0

        // --- Authorization checks (fail loud, not silent) ---
        let speechAuth = SFSpeechRecognizer.authorizationStatus()
        guard speechAuth == .authorized else {
            DebugLogger.log("MIC", "BLOCKED: speech auth = \(Self.speechAuthName(speechAuth)). Requesting…")
            SFSpeechRecognizer.requestAuthorization { _ in }
            finish(nil, session: session)
            return
        }
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micAuth == .authorized else {
            DebugLogger.log("MIC", "BLOCKED: microphone auth = \(micAuth.rawValue). Requesting…")
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            finish(nil, session: session)
            return
        }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            DebugLogger.log("MIC", "BLOCKED: recognizer unavailable (offline?)")
            finish(nil, session: session)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        DebugLogger.log("MIC", "input format sampleRate=\(Int(format.sampleRate)) channels=\(format.channelCount)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            DebugLogger.log("MIC", "BLOCKED: invalid input format (mic busy or no device)")
            finish(nil, session: session)
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.bufferCount += 1
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            DebugLogger.log("MIC", "listening… (engine started)")
        } catch {
            DebugLogger.log("MIC", "ERROR: audioEngine.start failed: \(error.localizedDescription)")
            finish(nil, session: session)
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, session == self.sessionID else { return }
            if let result = result {
                self.latestTranscript = result.bestTranscription.formattedString
                if result.isFinal {
                    DebugLogger.log("MIC", "final transcript: '\(self.latestTranscript)'")
                    self.finish(self.latestTranscript, session: session)
                }
            }
            if let error = error {
                DebugLogger.log("MIC", "recognition ended (\(error.localizedDescription)); buffers=\(self.bufferCount) partial='\(self.latestTranscript)'")
                self.finish(self.latestTranscript.isEmpty ? nil : self.latestTranscript, session: session)
            }
        }

        // Stop capturing after 6s and let the recognizer finalize the partial.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self = self, session == self.sessionID,
                  self.audioEngine.isRunning, !self.didComplete else { return }
            DebugLogger.log("MIC", "6s timeout — finalizing (buffers=\(self.bufferCount), partial='\(self.latestTranscript)')")
            self.recognitionRequest?.endAudio()
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            // Give the recognizer ~1s to emit a final result; else use the partial.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self = self, session == self.sessionID, !self.didComplete else { return }
                self.finish(self.latestTranscript.isEmpty ? nil : self.latestTranscript, session: session)
            }
        }
    }

    private func finish(_ transcript: String?, session: Int) {
        guard session == sessionID, !didComplete else { return }
        didComplete = true
        let cb = completion
        completion = nil
        stopListening()
        cb?(transcript)
    }

    func stopListening() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    private static func speechAuthName(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}
