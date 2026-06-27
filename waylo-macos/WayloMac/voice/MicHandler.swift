import Speech
import AVFoundation

/// Speech-to-text using SFSpeechRecognizer for voice task input.
final class MicHandler: NSObject, SFSpeechRecognizerDelegate {
    static let shared = MicHandler()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    override private init() {
        super.init()
    }

    /// Requests speech recognition authorization.
    func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    /// Listens for a single utterance and calls `completion` with the transcript.
    /// Apple's SFSpeechRecognizer API is callback-based, so this is an allowed
    /// exception to the async/await-everywhere rule.
    func listen(completion: @escaping (String?) -> Void) {
        stopListening()

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { completion(nil); return }
        request.shouldReportPartialResults = false

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            completion(nil)
            stopListening()
            return
        }

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            if let result = result, result.isFinal {
                completion(result.bestTranscription.formattedString)
                self?.stopListening()
            } else if error != nil {
                completion(nil)
                self?.stopListening()
            }
        }

        // Auto-stop after 8 seconds if no final result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, self.audioEngine.isRunning else { return }
            self.stopListening()
            completion(nil)
        }
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
}
