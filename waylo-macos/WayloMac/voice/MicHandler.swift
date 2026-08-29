import Speech
import AVFoundation

/// Speech-to-text using SFSpeechRecognizer for voice input.
///
/// On macOS, capturing audio needs BOTH Speech-Recognition authorization AND
/// Microphone (TCC) access. We request both up front, report partial results so
/// a transcript survives even if no "final" arrives, and log every stage so the
/// "empty transcript" failure mode is debuggable.
final class MicHandler: NSObject, SFSpeechRecognizerDelegate {

    /// Words users commonly say to Waylo — supplied as `contextualStrings` so the
    /// recognizer biases toward them (big accuracy win for short domain words).
    static let vocabulary: [String] = [
        // formatting
        "bold", "italic", "italicize", "underline", "bigger", "smaller", "font",
        "font size", "text size", "color", "colour", "highlight", "bullet",
        "bullet list", "numbered list", "indent", "outdent", "align", "center",
        "heading", "title", "strikethrough", "superscript", "subscript",
        // actions
        "open", "close", "save", "new document", "undo", "redo", "copy", "paste",
        "cut", "delete", "select all", "share", "export", "print", "find",
        "replace", "insert", "table", "image", "comment", "zoom",
        // apps / places
        "Pages", "Numbers", "Keynote", "Safari", "Mail", "Notes", "Reminders",
        "Calendar", "Messages", "Photos", "Finder", "System Settings", "Spotify",
        "Preview", "Contacts", "Maps", "Music", "Dark Mode", "Wi-Fi", "Bluetooth",
        // control words for the follow-up loop
        "done", "finished", "next", "back", "repeat", "stop", "yes", "no",
        "that's wrong", "wrong spot", "make it bigger", "make it bold",
    ]

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
    /// True while a hold-to-talk capture is running (no fixed 6s window).
    private var pushToTalkActive = false

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

    /// Push-to-talk: start listening now and keep going until `endPushToTalk()`
    /// is called (on hotkey RELEASE). The whole held utterance becomes the
    /// transcript — no fixed window. A 30s safety cap prevents a stuck key from
    /// recording forever.
    func startPushToTalk(completion: @escaping (String?) -> Void) {
        listen(completion: completion, pushToTalk: true)
    }

    /// Stops a push-to-talk capture and finalizes whatever was heard.
    func endPushToTalk() {
        guard pushToTalkActive else { return }
        pushToTalkActive = false
        DebugLogger.log("MIC", "push-to-talk released — finalizing (buffers=\(bufferCount), partial='\(latestTranscript)')")
        recognitionRequest?.endAudio()
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        let session = sessionID
        // Give the recognizer up to ~1s to emit a final result, else use the partial.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, session == self.sessionID, !self.didComplete else { return }
            self.finish(self.latestTranscript.isEmpty ? nil : self.latestTranscript, session: session)
        }
    }

    /// Listens for a single utterance and calls `completion` with the transcript.
    /// `pushToTalk`: when true, there is no fixed 6s window — capture runs until
    /// `endPushToTalk()` (with a 30s safety cap).
    func listen(completion: @escaping (String?) -> Void, pushToTalk: Bool = false) {
        stopListening()
        sessionID += 1
        let session = sessionID
        pushToTalkActive = pushToTalk

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
        // Prefer Apple's SERVER recognizer — markedly more accurate than the
        // on-device model (which mis-hears domain words like "italic"). Falls
        // back to on-device automatically when offline.
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        // Bias recognition toward the words users actually say to Waylo, so
        // "italic", "bigger", "Pages" etc. are far less likely to be mis-heard.
        request.contextualStrings = MicHandler.vocabulary
        if #available(macOS 13.0, *) { request.addsPunctuation = false }
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

        // Tap mode: fixed 6s window. Hold mode: no window (endPushToTalk stops
        // it), but a 30s safety cap so a stuck key can't record forever.
        let cap: Double = pushToTalk ? 30 : 6
        DispatchQueue.main.asyncAfter(deadline: .now() + cap) { [weak self] in
            guard let self = self, session == self.sessionID,
                  self.audioEngine.isRunning, !self.didComplete else { return }
            DebugLogger.log("MIC", "\(Int(cap))s cap — finalizing (buffers=\(self.bufferCount), partial='\(self.latestTranscript)')")
            self.pushToTalkActive = false
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
