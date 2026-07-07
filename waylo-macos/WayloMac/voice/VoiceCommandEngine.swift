import Foundation
import AppKit

/// Unified voice command on **⌃⌥⌘V** (registered in AppDelegate via HotkeyManager).
///
/// - If no guide is running, the spoken phrase is treated as a new task: a plan
///   is generated and the guide starts.
/// - If a guide IS running, the phrase is treated as a follow-up / correction
///   (e.g. "that's the wrong button, this icon doesn't exist here", or "now also
///   do X"). It is sent to the recovery model with a fresh screenshot so Waylo
///   can relabel the step, replan the rest, and continue from there.
@MainActor
final class VoiceCommandEngine: ObservableObject {
    static let shared = VoiceCommandEngine()

    enum VState { case idle, listening, working }
    @Published private(set) var state: VState = .idle

    private init() {}

    /// Begin listening for a spoken command (invoked by the ⌃⌥⌘V hotkey).
    func activate() {
        guard state == .idle else { return }
        state = .listening

        // Don't fight the guide's dot for screen space while listening.
        OverlayWindowController.shared.hideDot()
        Speaker.shared.stop()
        let running = GuidanceEngine.shared.isRunning
        OverlayWindowController.shared.showBanner(running
            ? "Listening… tell me what to fix or do next"
            : "Listening… what would you like to do?")
        DebugLogger.log("VOICE", "listening (guideRunning=\(running))")

        MicHandler.shared.listen { [weak self] transcript in
            DispatchQueue.main.async {
                Task { @MainActor in await self?.handle(transcript) }
            }
        }
    }

    private func handle(_ transcript: String?) async {
        guard state == .listening else { return }
        let text = (transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state = .idle
            OverlayWindowController.shared.showBanner("I didn't catch that. Press ⌃⌥⌘V to try again.", autoDismissAfter: 6)
            DebugLogger.log("VOICE", "empty transcript")
            return
        }

        state = .working
        DebugLogger.log("VOICE", "heard: '\(text)'")

        if GuidanceEngine.shared.isRunning {
            // Mid-guide: spoken correction / follow-up → recover & continue.
            OverlayWindowController.shared.showBanner("“\(text)”")
            GuidanceEngine.shared.applyVoiceCorrection(text)
            state = .idle
        } else {
            // No guide: start a new task from the spoken phrase.
            await startNewTask(text)
        }
    }

    private func startNewTask(_ task: String) async {
        OverlayWindowController.shared.showBanner("Planning: “\(task)”…")
        Speaker.shared.speak("Okay, let me figure that out.")
        do {
            let context = ScreenContextBuilder.build()
            DebugLogger.log("PLAN", "screenContext \(context.count) chars")
            let plan = try await WayloAPIClient.shared.generatePlan(task: task, screenContext: context)
            OverlayWindowController.shared.hideDot()
            GuidanceEngine.shared.startGuidance(plan: plan)
            DebugLogger.log("VOICE", "started guide for '\(task)' (\(plan.steps.count) steps)")
        } catch {
            if case let APIError.serverMessage(detail) = error {
                OverlayWindowController.shared.showBanner("I couldn't plan that: \(detail)", autoDismissAfter: 10)
            } else {
                OverlayWindowController.shared.showBanner("I couldn't plan that. Press ⌃⌥⌘V to try again.", autoDismissAfter: 8)
            }
            Speaker.shared.speak("Sorry, I couldn't plan that. Please try again.")
            DebugLogger.log("VOICE", "plan failed: \(error.localizedDescription)")
        }
        state = .idle
    }
}
