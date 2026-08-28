import Foundation
import AppKit

/// All Things Agentic Hackathon — drives the macOS app from the LIVE Google Cloud
/// agent (`/agent/next` on Cloud Run: Gemini 3.5 + Genkit + Firestore). Unlike the
/// shipping GuidanceEngine (which follows a whole plan decided up front), this runs
/// the agent as a LOOP with the AI always in the conversation:
///
///   read the current screen → ask the cloud agent for the single next decision →
///   show the red dot (fast, on-device detection) → the user either DOES it (a click
///   advances) or HOLDS RIGHT ⌘ and speaks — to answer a question, correct a wrong
///   dot ("no, it's the button top-right"), or add a follow-up — → repeat.
///
/// When the agent thinks the task is finished it doesn't just quit: it asks the user
/// to press **1** to finish, or hold **Right ⌘** to say what else they need. The whole
/// running conversation (steps done, corrections, answers, follow-ups) is accumulated
/// and sent back every turn, and answers persist across sessions (Firestore memory).
///
/// Reuses the app's existing screen-read, resolver, dot overlay, voice and click
/// observers. Lives on the `agent-cloud-demo` branch only — shipping path untouched.
@MainActor
final class CloudAgentEngine: ObservableObject {
    static let shared = CloudAgentEngine()

    @Published private(set) var isRunning = false

    /// Stable per-device id so Firestore remembers this user's answers across runs.
    private let userId = "mac-demo-user"

    // One user "event" the loop waits on after each decision.
    private enum UserInput { case click; case voice(String); case confirmDone }
    private var pending: CheckedContinuation<UserInput, Never>?
    private var acceptsVoice = false
    private var queuedVoice: String?       // voice heard while the agent was thinking
    private var clickId: UUID?
    private var keyMonitor: Any?

    private init() {}

    func run(goal: String) {
        guard !isRunning else { return }
        isRunning = true
        queuedVoice = nil
        NotchPanelController.expansion.expanded = false   // collapse to the notch pill, like a normal guide
        DebugLogger.log("CLOUD", "▶ agent start — goal='\(goal)' userId=\(userId)")
        Task { await loop(goal: goal) }
    }

    func stop() {
        isRunning = false
        removeClick(); removeKey()
        // Unblock any await so the loop can unwind cleanly (e.g. Esc mid-step).
        if let p = pending { pending = nil; acceptsVoice = false; p.resume(returning: .confirmDone) }
        queuedVoice = nil
        OverlayWindowController.shared.hideDot()
        NotchPanelController.expansion.expanded = true    // bring the panel back
        DebugLogger.log("CLOUD", "■ agent stopped")
    }

    // MARK: - The loop

    private func loop(goal: String) async {
        var history: [WayloAgentClient.HistoryItem] = []
        var answers: [WayloAgentClient.Answer] = []
        var step = 0

        while isRunning && step < 40 {
            step += 1
            let screen = ScreenContextBuilder.build()
            let appName = TargetAppTracker.shared.targetName

            let decision: WayloAgentClient.Decision
            do {
                decision = try await WayloAgentClient.shared.nextStep(
                    goal: goal, appName: appName, screen: screen,
                    userId: userId, history: history, answers: answers)
            } catch {
                DebugLogger.log("CLOUD", "agent call FAILED: \(error.localizedDescription)")
                Speaker.shared.speak("Sorry, I lost the connection. Let's try again.")
                break
            }
            guard isRunning else { break }
            DebugLogger.log("CLOUD", "decision #\(step): status=\(decision.status) memoryUsed=\(decision.memoryUsed ?? 0) — \(decision.reasoning ?? "")")

            switch decision.status {

            // ── The agent thinks it's finished — confirm, don't just quit. ──────
            case "done":
                OverlayWindowController.shared.hideDot()
                let msg = decision.reasoning ?? "I think that's everything."
                Speaker.shared.speak("\(msg) Press 1 if that's all. Or hold the right command key and tell me what else you need.")
                OverlayWindowController.shared.showBanner("✅ \(msg)\nPress 1 to finish  ·  hold Right ⌘ to ask for more")
                DebugLogger.log("CLOUD", "✓ agent thinks DONE — awaiting confirm (1 = finish, Right ⌘ = more)")
                let input = await awaitUserInput(click: false, voice: true, confirmKey: true)
                switch input {
                case .confirmDone:
                    Speaker.shared.speak("Great — all done.")
                    DebugLogger.log("CLOUD", "→ user confirmed DONE")
                    stop(); return
                case .voice(let text):
                    DebugLogger.log("CLOUD", "→ follow-up: '\(text)'")
                    OverlayWindowController.shared.showBanner("“\(text)”", autoDismissAfter: 2)
                    history.append(.init(instruction: "the task looked complete",
                                         outcome: "the user now ALSO wants: \(text) — keep guiding."))
                case .click:
                    break   // stray click during the done prompt — ignore, ask again
                }

            // ── Ambiguous goal — ask, and let the user ANSWER BY VOICE. ─────────
            case "clarify":
                guard let q = decision.question else { break }
                OverlayWindowController.shared.hideDot()
                let optsText = q.options.isEmpty ? "" : "  (\(q.options.joined(separator: "  /  ")))"
                Speaker.shared.speak("\(q.prompt) Hold the right command key and tell me.")
                OverlayWindowController.shared.showBanner("❓ \(q.prompt)\(optsText)\nHold Right ⌘ and answer out loud")
                DebugLogger.log("CLOUD", "❓ CLARIFY: \(q.prompt) options=\(q.options)")
                let input = await awaitUserInput(click: false, voice: true, confirmKey: false)
                if case .voice(let text) = input {
                    DebugLogger.log("CLOUD", "→ answer: '\(text)'")
                    OverlayWindowController.shared.showBanner("“\(text)”", autoDismissAfter: 2)
                    answers.append(.init(question: q.prompt, answer: text))
                }
                // Screen is unchanged — loop again WITH the new answer.

            // ── Next step — show the dot, wait for a click OR a voice correction. ─
            default: // "continue" / "recover"
                guard let action = decision.action else {
                    Speaker.shared.speak(decision.reasoning ?? "Let me look again.")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                let shown = await showAction(action)
                if !shown { Speaker.shared.speak(action.instruction) }
                let input = await awaitUserInput(click: true, voice: true, confirmKey: false)
                guard isRunning else { break }
                switch input {
                case .click:
                    history.append(.init(instruction: action.instruction, outcome: "user did it"))
                case .voice(let text):
                    // The dot was wrong / the user wants to redirect — feed it back
                    // so the agent RE-POINTS this same step (screen unchanged).
                    DebugLogger.log("CLOUD", "→ correction: '\(text)'")
                    OverlayWindowController.shared.showBanner("“\(text)”", autoDismissAfter: 2)
                    history.append(.init(instruction: action.instruction,
                                         outcome: "the red dot was NOT right — the user says: \(text). Re-point to the correct place; do not repeat the same spot."))
                case .confirmDone:
                    break   // came from stop()
                }
            }
        }
        stop()
    }

    // MARK: - Show the next action as a red dot (on-device resolver)

    /// Resolves the agent's action on the current screen and shows the dot.
    /// Returns true when a dot/region was drawn.
    private func showAction(_ a: WayloAgentClient.Action) async -> Bool {
        guard let capture = await ScreenCapturer.shared.captureActiveScreen() else { return false }
        let isIcon = (a.elementType ?? "").uppercased().contains("ICON")
        let res = await CoordinateResolver.shared.resolve(
            capture: capture,
            targetLabel: a.alternateLabels?.first ?? "",
            elementDescription: a.visualDescription ?? a.findDescription ?? a.instruction,
            stepInstruction: a.instruction,
            findDescription: a.findDescription ?? a.visualDescription ?? a.instruction,
            screenRegion: Self.mapRegion(a.screenRegion),
            task: "cloud-agent",
            stepIndex: 1, totalSteps: 1,
            targetType: isIcon ? .icon : .text,
            controlKind: Self.mapControl(a.elementType))
        guard isRunning, let res else { return false }
        OverlayWindowController.shared.showDot(at: res.axPoint, caption: a.instruction)
        Speaker.shared.speak(a.instruction)
        return true
    }

    // MARK: - Wait for the next user event (click · voice · press-1)

    /// Blocks until the user acts. `voice` inputs arrive via `receiveVoice(_:)`
    /// (Right ⌘ push-to-talk, routed here by VoiceCommandEngine while running).
    private func awaitUserInput(click: Bool, voice: Bool, confirmKey: Bool) async -> UserInput {
        // A correction/answer spoken while the agent was still thinking.
        if voice, let q = queuedVoice { queuedVoice = nil; return .voice(q) }
        return await withCheckedContinuation { cont in
            pending = cont
            acceptsVoice = voice
            if click {
                clickId = HotkeyManager.shared.addClickObserver { [weak self] _, _ in
                    Task { @MainActor in self?.resume(.click) }
                }
            }
            if confirmKey {
                keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
                    guard (ev.charactersIgnoringModifiers ?? "") == "1" else { return }
                    Task { @MainActor in self?.resume(.confirmDone) }
                }
            }
        }
    }

    private func resume(_ input: UserInput) {
        guard let p = pending else { return }
        pending = nil
        acceptsVoice = false
        removeClick(); removeKey()
        p.resume(returning: input)
    }

    /// Called by VoiceCommandEngine when Right ⌘ push-to-talk yields a transcript
    /// while the cloud agent is running — an answer, a correction, or a follow-up.
    func receiveVoice(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRunning, !t.isEmpty else { return }
        if pending != nil && acceptsVoice { resume(.voice(t)) }
        else { queuedVoice = t }   // consumed at the next await
    }

    private func removeClick() { HotkeyManager.shared.removeClickObserver(clickId); clickId = nil }
    private func removeKey() { if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil } }

    // MARK: - Map the agent's fields to the resolver's

    static func mapRegion(_ s: String?) -> ScreenRegion {
        let x = (s ?? "").lowercased()
        if x.contains("menu") { return .menuBar }
        if x.contains("dialog") || x.contains("popup") || x.contains("sheet") { return .dialog }
        if x.contains("sidebar") || x.contains("nav") { return .sidebar }
        if x.contains("toolbar") || x.contains("ribbon") { return .ribbon }
        if x.contains("status") { return .statusBar }
        return .fullScreen
    }

    static func mapControl(_ t: String?) -> String {
        switch (t ?? "").uppercased() {
        case let x where x.contains("BUTTON") || x.contains("FAB"): return "button"
        case "TOGGLE": return "checkbox"
        case "TAB": return "tab"
        case "TEXT_INPUT": return "field"
        default: return ""
        }
    }
}
