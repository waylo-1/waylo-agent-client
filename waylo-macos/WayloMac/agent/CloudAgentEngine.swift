import Foundation
import AppKit

/// All Things Agentic Hackathon — drives the macOS app from the LIVE Google Cloud
/// agent (`/agent/next` on Cloud Run: Gemini 3.5 + Genkit + Firestore). Unlike the
/// shipping GuidanceEngine (which follows a whole plan decided up front), this runs
/// the agent as a LOOP: read the current screen → ask the cloud agent for the single
/// next decision → show the red dot, or ask a clarifying question → wait for the user
/// → repeat. Answers persist across sessions (server-side Firestore memory).
///
/// Reuses the app's existing screen-read, resolver, dot overlay, and voice. Lives on
/// the `agent-cloud-demo` branch only — the shipping guidance path is untouched.
@MainActor
final class CloudAgentEngine: ObservableObject {
    static let shared = CloudAgentEngine()

    @Published private(set) var isRunning = false

    /// Stable per-device id so Firestore remembers this user's answers across runs.
    private let userId = "mac-demo-user"
    private var clickId: UUID?
    private var keyMonitor: Any?

    private init() {}

    func run(goal: String) {
        guard !isRunning else { return }
        isRunning = true
        DebugLogger.log("CLOUD", "▶ agent start — goal='\(goal)' userId=\(userId)")
        Task { await loop(goal: goal) }
    }

    func stop() {
        isRunning = false
        removeClick(); removeKey()
        OverlayWindowController.shared.hideDot()
        DebugLogger.log("CLOUD", "■ agent stopped")
    }

    // MARK: - The loop

    private func loop(goal: String) async {
        var history: [WayloAgentClient.HistoryItem] = []
        var answers: [WayloAgentClient.Answer] = []
        var step = 0

        while isRunning && step < 25 {
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
            case "done":
                OverlayWindowController.shared.hideDot()
                Speaker.shared.speak("All done!")
                DebugLogger.log("CLOUD", "✓ DONE")
                isRunning = false
                return

            case "clarify":
                guard let q = decision.question else { break }
                let chosen = await askUser(q)
                guard isRunning else { break }
                answers.append(.init(question: q.prompt, answer: chosen))
                // Screen is unchanged — loop again WITH the new answer (no history entry).

            default: // "continue" / "recover"
                guard let action = decision.action else {
                    Speaker.shared.speak(decision.reasoning ?? "Let me look again.")
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                let shown = await showAction(action)
                if !shown { Speaker.shared.speak(action.instruction) }
                await waitForClick()
                guard isRunning else { break }
                history.append(.init(instruction: action.instruction, outcome: "user did it"))
            }
        }
        stop()
    }

    // MARK: - Show the next action as a red dot

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

    // MARK: - Clarify (the Collaborative Partner moment)

    /// Speaks the question, shows the numbered options, and captures the user's
    /// choice via number keys (1–N). Returns the chosen option text.
    private func askUser(_ q: WayloAgentClient.Question) async -> String {
        OverlayWindowController.shared.hideDot()
        let opts = q.options.isEmpty ? ["Yes", "No"] : q.options
        let numbered = opts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "   ")
        OverlayWindowController.shared.showBanner("\(q.prompt)\n\(numbered)")
        let spoken = opts.enumerated().map { "press \($0.offset + 1) for \($0.element)" }.joined(separator: ", ")
        Speaker.shared.speak("\(q.prompt) — \(spoken).")
        DebugLogger.log("CLOUD", "❓ CLARIFY: \(q.prompt)  options=\(opts)")

        let chosen: String = await withCheckedContinuation { cont in
            var resumed = false
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
                guard let self, !resumed,
                      let n = Int(ev.charactersIgnoringModifiers ?? ""), n >= 1, n <= opts.count else { return }
                resumed = true
                self.removeKey()
                cont.resume(returning: opts[n - 1])
            }
        }
        DebugLogger.log("CLOUD", "→ user chose: \(chosen)")
        OverlayWindowController.shared.showBanner("You chose: \(chosen)", autoDismissAfter: 2)
        return chosen
    }

    // MARK: - Wait for the user to act

    private func waitForClick() async {
        await withCheckedContinuation { cont in
            var resumed = false
            clickId = HotkeyManager.shared.addClickObserver { [weak self] _, _ in
                guard let self, !resumed else { return }
                resumed = true
                Task { @MainActor in self.removeClick(); cont.resume() }
            }
        }
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
