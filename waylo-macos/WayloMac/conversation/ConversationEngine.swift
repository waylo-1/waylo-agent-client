import Foundation
import AppKit

enum ConversationState {
    case idle
    case listening
    case processing
    case awaitingResume
}

/// Mid-session voice Q&A. Press the Ask hotkey (Ctrl+Option+A) during a guide to
/// ask a question by voice. Concept questions get a spoken answer; "where is X"
/// questions place the red dot; "continue / back / repeat" resume the guide.
@MainActor
final class ConversationEngine: ObservableObject {
    static let shared = ConversationEngine()

    @Published var state: ConversationState = .idle
    @Published var lastQuestion = ""
    @Published var lastAnswer = ""

    private let classifier = QuestionClassifier()
    private var askKeyMonitor: Any?

    private init() {}

    // MARK: - Hotkey

    /// Installs the global Ctrl+Option+A "ask" hotkey.
    func start() {
        guard askKeyMonitor == nil else { return }
        askKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Ctrl + Option + A (keyCode 0 = A)
            if event.modifierFlags.contains([.control, .option]) && event.keyCode == 0 {
                Task { @MainActor in self?.activate() }
            }
        }
    }

    // MARK: - Flow

    /// Begin listening for a question (pauses any running guide).
    func activate() {
        guard state == .idle || state == .awaitingResume else { return }
        if GuidanceEngine.shared.isRunning {
            GuidanceEngine.shared.pauseGuide()
        }
        state = .listening
        OverlayWindowController.shared.showBanner("Listening… ask your question")
        Speaker.shared.stop()

        MicHandler.shared.listen { [weak self] transcript in
            DispatchQueue.main.async {
                Task { @MainActor in await self?.handleTranscription(transcript) }
            }
        }
    }

    private func handleTranscription(_ text: String?) async {
        guard state == .listening else { return }
        guard let text = text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            state = .awaitingResume
            OverlayWindowController.shared.showBanner("I didn't catch that. Press ⌃⌥A to try again.")
            return
        }

        state = .processing
        lastQuestion = text
        OverlayWindowController.shared.showBanner("“\(text)”")

        switch classifier.classify(text) {
        case .navigation(let direction):
            await handleNavigation(direction)
        case .concept:
            await handleConcept(text)
        case .location(let target, let region):
            await handleLocation(targetLabel: target, region: region)
        case .unknown:
            Speaker.shared.speak("Sorry, I didn't understand. Please try again.")
            state = .awaitingResume
        }
    }

    // MARK: - Handlers

    private func handleNavigation(_ direction: String) async {
        if direction.contains("continue") || direction.contains("carry on") || direction.contains("next") {
            Speaker.shared.speak("Continuing.")
            finishAndResume()
        } else if direction.contains("back") || direction.contains("previous") {
            Speaker.shared.speak("Going back.")
            state = .idle
            OverlayWindowController.shared.hideDot()
            GuidanceEngine.shared.previousStep()
        } else if direction.contains("repeat") || direction.contains("again") {
            Speaker.shared.speak("Here it is again.")
            state = .idle
            OverlayWindowController.shared.hideDot()
            GuidanceEngine.shared.relocate()
        } else {
            state = .awaitingResume
        }
    }

    private func handleConcept(_ question: String) async {
        OverlayWindowController.shared.showBanner("Thinking…")
        let appName = TargetAppTracker.shared.targetName.isEmpty ? "this app" : TargetAppTracker.shared.targetName
        let answer: String
        do {
            answer = try await WayloAPIClient.shared.askConcept(question: question, appName: appName)
        } catch {
            answer = "I had trouble answering that. Please try again."
        }
        lastAnswer = answer
        OverlayWindowController.shared.showBanner(answer)
        Speaker.shared.speak(answer)
        state = .awaitingResume
    }

    private func handleLocation(targetLabel: String, region: ScreenRegion) async {
        OverlayWindowController.shared.showBanner("Looking for \(targetLabel)…")

        guard ScreenRecordingPermission.isGranted,
              let capture = await ScreenCapturer.shared.captureActiveScreen() else {
            Speaker.shared.speak("I couldn't read the screen. Please try again.")
            state = .awaitingResume
            return
        }

        let resolution = await CoordinateResolver.shared.resolve(
            capture: capture,
            targetLabel: targetLabel,
            elementDescription: targetLabel,
            stepInstruction: "User is asking where \(targetLabel) is",
            findDescription: targetLabel,
            screenRegion: region,
            task: "voice question",
            stepIndex: 0,
            totalSteps: 1
        )

        if let resolution = resolution {
            OverlayWindowController.shared.showDot(at: resolution.axPoint, caption: targetLabel)
            Speaker.shared.speak("There it is — look for the red dot.")
        } else {
            Speaker.shared.speak("I couldn't find \(targetLabel) on your screen right now.")
        }
        state = .awaitingResume
    }

    private func finishAndResume() {
        state = .idle
        OverlayWindowController.shared.hideDot()
        if GuidanceEngine.shared.isRunning {
            GuidanceEngine.shared.resumeGuide()
        }
    }
}
