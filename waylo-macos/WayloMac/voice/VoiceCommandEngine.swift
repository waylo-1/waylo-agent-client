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

    /// Hold-to-talk START (⌃⌥⌘V held): begin capturing until release.
    func beginPushToTalk() {
        guard state == .idle else { return }
        state = .listening

        // Don't fight the guide's dot for screen space while listening.
        OverlayWindowController.shared.hideDot()
        Speaker.shared.stop()
        let running = GuidanceEngine.shared.isRunning
        OverlayWindowController.shared.showBanner(running
            ? "Listening… hold and speak, release when done"
            : "Listening… hold ⌃⌥⌘V and speak, release when done")
        DebugLogger.log("VOICE", "push-to-talk begin (guideRunning=\(running))")

        MicHandler.shared.startPushToTalk { [weak self] transcript in
            DispatchQueue.main.async {
                Task { @MainActor in await self?.handle(transcript) }
            }
        }
    }

    /// Hold-to-talk END (⌃⌥⌘V released): finalize and process the transcript.
    func endPushToTalk() {
        guard state == .listening else { return }
        OverlayWindowController.shared.showBanner("Got it, thinking…", autoDismissAfter: 4)
        MicHandler.shared.endPushToTalk()
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
        // In a LEARNING session every request routes through the planner so it
        // is TAUGHT (with session memory), not silently done — the instant
        // shortcuts would hijack follow-ups like "search for it on Google".
        let learning = SkillSession.shared.active != nil

        // Direct intents (open a site, web search, launch an app) execute
        // instantly — no plan, no dot, no cost.
        if !learning, let intent = IntentShortcuts.match(task) {
            let spoken = IntentShortcuts.perform(intent)
            OverlayWindowController.shared.showBanner(spoken, autoDismissAfter: 5)
            Speaker.shared.speak(spoken)
            state = .idle
            return
        }

        // Autonomous app control ("play drake on spotify", "pause the music",
        // "directions to the airport") — driven via AppleScript / URI schemes,
        // not the vision pipeline. Also instant, no plan, no cost.
        if !learning, let action = AppActions.match(task) {
            let spoken = await AppActions.perform(action)
            OverlayWindowController.shared.showBanner(spoken, autoDismissAfter: 5)
            Speaker.shared.speak(spoken)
            state = .idle
            return
        }

        // Agent mode: no plan — the observe→act loop does the task itself.
        if GuidanceEngine.shared.mode == .agent {
            await AgentEngine.shared.run(task: task)
            state = .idle
            return
        }

        OverlayWindowController.shared.showBanner("Planning: “\(task)”…")
        Speaker.shared.speak("Okay, let me figure that out.")
        do {
            let context = ScreenContextBuilder.build()
            DebugLogger.log("PLAN", "screenContext \(context.count) chars")
            let plan = try await WayloAPIClient.shared.generatePlan(
                task: task, screenContext: context,
                sessionContext: SkillSession.shared.contextForPlan())
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
