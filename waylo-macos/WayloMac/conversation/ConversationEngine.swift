import Foundation
import AppKit

enum ConversationState {
    case idle
    case listening
    case processing
    case awaitingResume
}

/// Mid-session voice Q&A. Press the Ask hotkey (⌃⌥⌘A) during a guide to
/// ask a question by voice. Concept questions get a spoken answer; "where is X"
/// questions place the red dot; "continue / back / repeat" resume the guide.
@MainActor
final class ConversationEngine: ObservableObject {
    static let shared = ConversationEngine()

    @Published var state: ConversationState = .idle
    @Published var lastQuestion = ""
    @Published var lastAnswer = ""

    private let classifier = QuestionClassifier()

    private init() {}

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
            OverlayWindowController.shared.showBanner("I didn't catch that. Press ⌃⌥⌘A to try again.", autoDismissAfter: 6)
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
        if direction.contains("continue") || direction.contains("carry on") {
            Speaker.shared.speak("Continuing.")
            finishAndResume()
        } else if direction.contains("back") || direction.contains("previous") {
            Speaker.shared.speak("Going back.")
            state = .idle
            OverlayWindowController.shared.hideDot()
            GuidanceEngine.shared.previousStep()
        } else if direction.contains("repeat") || direction.contains("again") || direction.contains("one more time") {
            Speaker.shared.speak("Here it is again.")
            state = .idle
            OverlayWindowController.shared.hideDot()
            GuidanceEngine.shared.relocate()
        } else if direction.contains("next") || direction.contains("skip") {
            // "Next step" must ADVANCE, not just resume the same step (the old
            // code routed it to resume, which re-showed the step being skipped).
            Speaker.shared.speak("Skipping ahead.")
            state = .idle
            OverlayWindowController.shared.hideDot()
            GuidanceEngine.shared.nextStep()
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
        showAnswerBanner(answer)
        Speaker.shared.speak(answer)
        state = .awaitingResume
    }

    /// Shows an answer banner that dismisses itself, with a resume hint when a
    /// guide is paused underneath (otherwise the guide looked stuck after Q&A).
    private func showAnswerBanner(_ answer: String) {
        var text = answer
        if GuidanceEngine.shared.isRunning {
            text += "\n\nSay “continue” (⌃⌥⌘A) or press Resume to keep going."
        }
        OverlayWindowController.shared.showBanner(text, autoDismissAfter: 14)
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

    // MARK: - Screen Q&A (Ctrl+Option+Cmd+Q) — vision answer, no pointer

    /// Ask a free-form question answered from what's on screen (for learning).
    /// Listens for the question, screenshots the screen, and speaks/shows the
    /// answer. Does not place a dot or touch a running guide.
    func askAboutScreen() {
        guard state == .idle || state == .awaitingResume else { return }
        state = .listening
        OverlayWindowController.shared.showBanner("Listening… ask about what's on your screen")
        Speaker.shared.stop()
        DebugLogger.log("QA", "screen question — listening")

        MicHandler.shared.listen { [weak self] transcript in
            DispatchQueue.main.async {
                Task { @MainActor in await self?.handleScreenQuestion(transcript) }
            }
        }
    }

    private func handleScreenQuestion(_ transcript: String?) async {
        guard state == .listening else { return }
        let q = (transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            state = .awaitingResume
            OverlayWindowController.shared.showBanner("I didn't catch that. Press ⌃⌥⌘Q to try again.", autoDismissAfter: 6)
            return
        }
        state = .processing
        lastQuestion = q
        OverlayWindowController.shared.showBanner("“\(q)”  — looking at your screen…")
        DebugLogger.log("QA", "screen question: '\(q)'")

        guard ScreenRecordingPermission.isGranted,
              let capture = await ScreenCapturer.shared.captureActiveScreen(),
              let (b64, _) = ScreenCapturer.compressedJPEGBase64(capture.image, maxWidth: 1280) else {
            Speaker.shared.speak("I couldn't read your screen. Please try again.")
            OverlayWindowController.shared.showBanner("I couldn't read your screen.", autoDismissAfter: 6)
            state = .awaitingResume
            return
        }

        let appName = TargetAppTracker.shared.targetName
        let answer: String
        do {
            answer = try await WayloAPIClient.shared.askScreen(question: q, imageBase64: b64, appName: appName)
        } catch {
            answer = "I had trouble answering that. Please try again."
            DebugLogger.log("QA", "ask-screen failed: \(error.localizedDescription)")
        }
        lastAnswer = answer
        showAnswerBanner(answer)
        Speaker.shared.speak(answer)
        state = .awaitingResume
    }
}
