import AppKit

/// Agent mode: Waylo DOES the task instead of pointing. An observe → decide →
/// act → verify loop — each turn the model sees the REAL accessibility tree as
/// a numbered list and picks one action (press #7 / type / shortcut / menu
/// path), which we execute directly on the element handle. No upfront plan to
/// go stale, no description→screen fuzzy matching to miss.
///
/// Safety: any action the model flags `confirm` (send / delete / empty / pay /
/// post) — or whose target matches the local destructive list — pauses for an
/// explicit "Do it" click from the user. Personal choices (which chat, which
/// photo) come back as ask_user and hand control to the user. Hard cap on
/// actions per task; every action is narrated as it happens.
@MainActor
final class AgentEngine: ObservableObject {
    static let shared = AgentEngine()
    private init() {}

    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = ""

    private var runToken = 0
    private static let maxActions = 16

    /// Local safety net on top of the server's `confirm` flag.
    private static let dangerWords = ["empty", "delete", "erase", "remove", "discard",
                                      "uninstall", "format", "don't save", "dont save",
                                      "send", "pay", "buy", "purchase", "post", "publish",
                                      "share", "shut down", "restart", "log out", "sign out"]

    func stop() {
        runToken += 1
        isRunning = false
        HelperButtonController.shared.hide()
        statusMessage = ""
    }

    func run(task: String) async {
        guard !GuidanceEngine.shared.isRunning else {
            Speaker.shared.speak("Please finish or stop the current guide first.")
            return
        }
        stop()
        runToken += 1
        let token = runToken
        isRunning = true
        DebugLogger.log("AGENT", "run start: '\(task)'")
        OverlayWindowController.shared.showBanner("Doing it: “\(task)”…")
        Speaker.shared.speak("On it.")

        var history: [String] = []
        var lastFingerprint: Int? = nil

        for actionIndex in 1...Self.maxActions {
            guard token == runToken else { return }

            // OBSERVE — settle, then snapshot the real tree.
            try? await Task.sleep(nanoseconds: actionIndex == 1 ? 200_000_000 : 900_000_000)
            var snapshot = AgentSnapshot.capture()

            // Tell the model whether its LAST action visibly changed anything.
            if let last = lastFingerprint, !history.isEmpty {
                let changed = snapshot.fingerprint != last
                history[history.count - 1] += changed ? " → screen changed" : " → no visible change"
            }

            // DECIDE
            let context = ScreenContextBuilder.build()
            let action: WayloAPIClient.AgentAction
            do {
                action = try await WayloAPIClient.shared.agentAct(
                    task: task, appName: snapshot.appName, context: context,
                    elements: snapshot.payload, history: history)
            } catch {
                guard token == runToken else { return }
                let detail = (error as? APIError).flatMap { if case let .serverMessage(d) = $0 { return d } else { return nil } }
                    ?? "I lost connection while working on that."
                finish(spoken: detail, token: token)
                return
            }
            guard token == runToken else { return }

            if let say = action.say, !say.isEmpty {
                statusMessage = say
                OverlayWindowController.shared.showBanner(say)
                Speaker.shared.speak(say)
            }
            DebugLogger.log("AGENT", "step \(actionIndex): \(describe(action))")

            // TERMINALS
            switch action.act {
            case "done":
                finish(spoken: action.summary ?? "Done.", token: token)
                return
            case "ask_user":
                finish(spoken: action.question ?? "I need your help to continue.", token: token)
                return
            default: break
            }

            // CONFIRM GATE — server flag OR local danger match on the target.
            if needsConfirmation(action, snapshot: snapshot) {
                let target = targetLabel(of: action, in: snapshot)
                let approved = await requestConfirmation(for: target, token: token)
                guard token == runToken else { return }
                guard approved else {
                    finish(spoken: "Okay, I stopped before doing that.", token: token)
                    return
                }
            }

            // ACT
            lastFingerprint = snapshot.fingerprint
            let executed = execute(action, snapshot: &snapshot)
            history.append(describe(action) + (executed ? "" : " (FAILED to execute)"))

            // wait/open_app get extra settle time before the next observation.
            if action.act == "open_app" { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            if action.act == "wait", let s = action.seconds, s > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(s, 15) * 1_000_000_000))
            }
        }

        finish(spoken: "That's taking more steps than expected — I've stopped so we don't go in circles. Try breaking the task into smaller parts.", token: token)
    }

    // MARK: - Execution

    private func execute(_ a: WayloAPIClient.AgentAction, snapshot: inout AgentSnapshot) -> Bool {
        switch a.act {
        case "press":
            guard let id = a.id, let info = snapshot.element(for: id) else {
                DebugLogger.log("AGENT", "press: id \(a.id.map(String.init) ?? "nil") not in snapshot")
                return false
            }
            return AgentExecutor.press(info)
        case "type":
            let field = a.id.flatMap { snapshot.element(for: $0) }
            return AgentExecutor.type(a.text ?? "", into: field, submit: a.submit ?? false)
        case "key":
            return AgentExecutor.key(combo: a.combo ?? "")
        case "menu":
            return AgentExecutor.menu(path: a.path ?? [])
        case "open_app":
            guard let name = a.name, let url = AppLauncher.resolveApp(named: name) else { return false }
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            return true
        case "scroll":
            return AgentExecutor.scroll(direction: a.direction ?? "down")
        case "wait":
            return true
        default:
            return false
        }
    }

    // MARK: - Confirmation

    private func needsConfirmation(_ a: WayloAPIClient.AgentAction, snapshot: AgentSnapshot) -> Bool {
        if a.confirm == true { return true }
        let label = targetLabel(of: a, in: snapshot).lowercased()
        return Self.dangerWords.contains { label.contains($0) }
    }

    private func targetLabel(of a: WayloAPIClient.AgentAction, in snapshot: AgentSnapshot) -> String {
        switch a.act {
        case "press":
            guard let id = a.id, let info = snapshot.element(for: id) else { return "" }
            return info.title.isEmpty ? info.description : info.title
        case "menu":
            return a.path?.last ?? ""
        default:
            return ""
        }
    }

    /// Speaks the warning and waits for an explicit button click. Anything
    /// else (timeout ~25s) counts as NO — the safe default.
    private func requestConfirmation(for target: String, token: Int) async -> Bool {
        let what = target.isEmpty ? "this" : "“\(target)”"
        Speaker.shared.speak("This will \(what.isEmpty ? "do something I can't undo" : "press \(what)"), which I can't undo. Click the button if you want me to continue.")
        statusMessage = "Waiting for your OK…"
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            HelperButtonController.shared.show(title: "Yes — do it") {
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                guard !resumed else { return }
                resumed = true
                HelperButtonController.shared.hide()
                cont.resume(returning: false)
            }
        }
    }

    // MARK: - Helpers

    private func finish(spoken: String, token: Int) {
        guard token == runToken else { return }
        isRunning = false
        statusMessage = spoken
        OverlayWindowController.shared.showBanner(spoken, autoDismissAfter: 8)
        Speaker.shared.speak(spoken)
        DebugLogger.log("AGENT", "finish: \(spoken)")
    }

    private func describe(_ a: WayloAPIClient.AgentAction) -> String {
        switch a.act {
        case "press":    return "press #\(a.id ?? -1)"
        case "type":     return "type \"\((a.text ?? "").prefix(30))\"\(a.submit == true ? " + return" : "")"
        case "key":      return "key \(a.combo ?? "?")"
        case "menu":     return "menu \((a.path ?? []).joined(separator: " > "))"
        case "open_app": return "open app '\(a.name ?? "?")'"
        case "scroll":   return "scroll \(a.direction ?? "down")"
        case "wait":     return "wait \(Int(a.seconds ?? 0))s"
        default:         return a.act
        }
    }
}
