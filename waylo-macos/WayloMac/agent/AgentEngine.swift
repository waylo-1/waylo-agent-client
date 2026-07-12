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
    private var clickObserverId: UUID?
    private static let maxActions = 16
    /// How many times per task the agent may hand a step to the user before
    /// concluding the task is better done in guide mode.
    private static let maxHandoffs = 3
    /// Below this many actionable AX elements, treat the app as AX-hostile and
    /// switch that turn to the Set-of-Mark vision observation.
    private static let minAXElements = 3
    /// Experimental: use Gemini's computer-use tool on AX-hostile turns
    /// (plain screenshot → grounded action). Toggled in Dev Tools; any error
    /// falls back to Set-of-Mark, so enabling it can't reduce reliability.
    static let computerUseKey = "waylo.computerUse"
    static var computerUseEnabled: Bool { UserDefaults.standard.bool(forKey: computerUseKey) }

    /// Local safety net on top of the server's `confirm` flag.
    private static let dangerWords = ["empty", "delete", "erase", "remove", "discard",
                                      "uninstall", "format", "don't save", "dont save",
                                      "send", "pay", "buy", "purchase", "post", "publish",
                                      "share", "shut down", "restart", "log out", "sign out"]

    func stop() {
        runToken += 1
        isRunning = false
        HelperButtonController.shared.hide()
        OverlayWindowController.shared.hideDot()
        HotkeyManager.shared.removeClickObserver(clickObserverId)
        clickObserverId = nil
        statusMessage = ""
    }

    /// Waits for the user's next real click (the CGEventTap observer sees
    /// clicks in any app). A short dwell ignores the click that may have
    /// triggered this state. Returns false on timeout or cancellation.
    private func waitForUserClick(token: Int, timeout: TimeInterval) async -> Bool {
        let started = Date()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resumed = false
            let finish: (Bool) -> Void = { [weak self] ok in
                guard !resumed else { return }
                resumed = true
                HotkeyManager.shared.removeClickObserver(self?.clickObserverId)
                self?.clickObserverId = nil
                cont.resume(returning: ok)
            }
            clickObserverId = HotkeyManager.shared.addClickObserver { _, _ in
                guard Date().timeIntervalSince(started) > 0.8 else { return }
                DispatchQueue.main.async { finish(true) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if self?.runToken != token { finish(false); return }
                finish(false)
            }
        }
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
        var userHandoffs = 0
        var lastBrokenKey: String? = nil

        for actionIndex in 1...Self.maxActions {
            guard token == runToken else { return }

            // OBSERVE — snapshot the AX tree. If it's too thin (an AX-hostile
            // app: Spotify, WhatsApp, some Electron apps) also grab a
            // Set-of-Mark VISION observation so this turn can act on pixels.
            try? await Task.sleep(nanoseconds: actionIndex == 1 ? 200_000_000 : 900_000_000)
            var axSnap = AgentSnapshot.capture()
            let axActionable = axSnap.entries.filter {
                $0.info.role != "AXStaticText" && $0.info.role != "AXRow"
            }.count
            var visSnap: VisionSnapshot? = nil
            var computerCap: ScreenCapturer.Capture? = nil
            if axActionable < Self.minAXElements {
                if Self.computerUseEnabled {
                    // Experimental: Gemini's computer-use tool grounds actions
                    // directly on a plain screenshot — no YOLO, no badges.
                    computerCap = await ScreenCapturer.shared.captureActiveScreen()
                }
                if computerCap == nil {
                    DebugLogger.log("AGENT", "AX tree thin (\(axActionable) actionable) — falling back to vision")
                    visSnap = await VisionSnapshot.capture()
                }
                guard token == runToken else { return }
            }

            // Change signal from the AX fingerprint (meaningful for the last
            // action even on a vision turn). Keyboard shortcuts (⌘S, ⌘C…) often
            // succeed with NO visible change — a blunt "no visible change" pushes
            // the model to retry a shortcut that already worked, so soften it.
            if let last = lastFingerprint, !history.isEmpty {
                let changed = axSnap.fingerprint != last
                let lastWasKey = history[history.count - 1].hasPrefix("key ")
                history[history.count - 1] += changed
                    ? " → screen changed"
                    : (lastWasKey
                       ? " → screen unchanged (shortcuts often work silently — do NOT repeat it; verify another way or move on)"
                       : " → no visible change")
            }

            // DECIDE — computer-use when enabled (falls back to Set-of-Mark on
            // any error), else SoM vision, else the AX-tree decider.
            var action: WayloAPIClient.AgentAction? = nil
            if let cap = computerCap,
               let (b64, _) = ScreenCapturer.compressedJPEGBase64(cap.image, maxWidth: 1280) {
                do {
                    action = try await WayloAPIClient.shared.agentActComputer(
                        task: task, appName: axSnap.appName, imageBase64: b64, history: history)
                    DebugLogger.log("AGENT", "computer-use decided: \(action!.act)")
                } catch {
                    DebugLogger.log("AGENT", "computer-use failed (\(error.localizedDescription)) — falling back to Set-of-Mark")
                    computerCap = nil
                    visSnap = await VisionSnapshot.capture()
                    guard token == runToken else { return }
                }
            }
            if action == nil {
            do {
                if let vs = visSnap {
                    action = try await WayloAPIClient.shared.agentActVision(
                        task: task, appName: vs.appName, imageBase64: vs.annotatedBase64,
                        marks: vs.payload, history: history)
                } else {
                    var context = ScreenContextBuilder.build()
                    if !axSnap.menuTitles.isEmpty {
                        context += "\nMenu bar (invoke with the menu action + a path): \(axSnap.menuTitles.joined(separator: ", "))"
                    }
                    if axSnap.dialogOpen {
                        context += "\nIMPORTANT: a modal dialog/sheet is OPEN — its elements are flagged \"dialog\":true and listed first. Interact with THOSE; menus and background buttons will not respond until it is dealt with."
                    }
                    action = try await WayloAPIClient.shared.agentAct(
                        task: task, appName: axSnap.appName, context: context,
                        elements: axSnap.payload, history: history)
                }
            } catch {
                guard token == runToken else { return }
                let detail = (error as? APIError).flatMap { if case let .serverMessage(d) = $0 { return d } else { return nil } }
                    ?? "I lost connection while working on that."
                finish(spoken: detail, token: token)
                return
            }
            }
            guard token == runToken, let action else { return }

            // Snapshot-agnostic accessors for the rest of the turn.
            let frameForID: (Int) -> CGRect? = { id in
                if let vs = visSnap { return vs.mark(for: id)?.frame }
                return axSnap.element(for: id)?.frame
            }

            if let say = action.say, !say.isEmpty {
                statusMessage = say
                OverlayWindowController.shared.showBanner(say)
                Speaker.shared.speak(say)
            }
            DebugLogger.log("AGENT", "step \(actionIndex): \(describe(action))")

            // TERMINAL
            if action.act == "done" {
                finish(spoken: action.summary ?? "Done.", token: token)
                return
            }

            // HYBRID HANDOFFS — the agent hands one step to the user and the
            // loop RESUMES after their click. This is the teach/agent blend:
            // "point" outlines the element the USER should click (their
            // choice); "ask_user" asks them to do something the agent can't.
            if action.act == "point" || action.act == "ask_user" {
                userHandoffs += 1
                guard userHandoffs <= Self.maxHandoffs else {
                    finish(spoken: "I need your help too often for this one — let's finish it together in guide mode.", token: token)
                    return
                }
                let question = action.question ?? "Please do this part yourself."
                if action.act == "point", let id = action.id, let frame = frameForID(id) {
                    OverlayWindowController.shared.showHighlight(axRect: frame, caption: question)
                } else {
                    OverlayWindowController.shared.showBanner("\(question) — click it and I'll carry on.")
                }
                Speaker.shared.speak("\(question) I'll carry on after you click.")
                statusMessage = "Waiting for you…"
                let acted = await waitForUserClick(token: token, timeout: 60)
                OverlayWindowController.shared.hideDot()
                guard token == runToken else { return }
                guard acted else {
                    finish(spoken: "No problem — I've stopped. Ask me again when you're ready.", token: token)
                    return
                }
                history.append("\(action.act == "point" ? "pointed" : "asked user"): \"\(question.prefix(60))\" → user did it")
                lastFingerprint = nil   // the user changed the screen; don't judge it
                continue
            }

            // REPEAT GUARDS. The model (esp. smaller ones) re-issues an action
            // when a countdown/loading state is invisible to the AX tree.
            // Re-pressing cancels countdowns and re-fires menus, so this is
            // enforced deterministically, never left to the prompt:
            //   1st repeat  → convert to a 3s wait (the app is mid-process)
            //   2nd repeat  → hand the step to the user and resume after
            let desc = describe(action)
            let key = Self.guardKey(desc)
            let executedBefore = history.filter { Self.guardKey($0).hasPrefix(key) }.count
            let dampedBefore = history.contains { Self.guardKey($0).contains("repeat of '\(key)'") }
            if action.act != "wait", executedBefore >= 1, !dampedBefore {
                DebugLogger.log("AGENT", "repeat damper: '\(desc)' again — waiting 3s instead")
                history.append("(blocked repeat of '\(desc)' — waited 3s; do something DIFFERENT next)")
                lastFingerprint = nil
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }

            // LOOP BREAKER — damped once already and the model STILL wants the
            // same action (or has genuinely run it twice). A third go never
            // helps (AXPress "succeeds" on disabled items), so hand this step
            // to the user and resume — ONCE. If the model comes back with the
            // very same action even after the user stepped in, more handoffs
            // just repeat the monologue; stop honestly instead.
            if (action.act != "wait" && dampedBefore && executedBefore >= 1) || executedBefore >= 2 {
                if lastBrokenKey == key {
                    finish(spoken: "This one isn't working in Do-it-for-me mode — switch to Do it with me and I'll walk you through it.", token: token)
                    return
                }
                lastBrokenKey = key
                DebugLogger.log("AGENT", "loop breaker: '\(desc)' already tried twice — handing to user")
                userHandoffs += 1
                guard userHandoffs <= Self.maxHandoffs else {
                    finish(spoken: "I keep going in circles on this one — I've stopped. Try guide mode for this task.", token: token)
                    return
                }
                let ask = "I'm stuck on this part. Please do the next step yourself"
                OverlayWindowController.shared.showBanner("\(ask) — click when done and I'll carry on.")
                Speaker.shared.speak("\(ask). Click anywhere when you've done it and I'll carry on.")
                statusMessage = "Waiting for you…"
                let acted = await waitForUserClick(token: token, timeout: 60)
                guard token == runToken else { return }
                guard acted else {
                    finish(spoken: "Okay, I've stopped. Ask me again when you're ready.", token: token)
                    return
                }
                history.append("STUCK (repeated '\(desc)') → user did the step manually")
                lastFingerprint = nil
                continue
            }

            // CONFIRM GATE — server flag OR local danger match on the target.
            // (Vision turns have no element labels, so they rely on the
            // server's confirm flag alone.)
            let dangerLabel = visSnap == nil ? targetLabel(of: action, in: axSnap) : ""
            let mustConfirm = action.confirm == true
                || Self.dangerWords.contains { dangerLabel.lowercased().contains($0) }
            if mustConfirm {
                let approved = await requestConfirmation(for: dangerLabel, token: token)
                guard token == runToken else { return }
                guard approved else {
                    finish(spoken: "Okay, I stopped before doing that.", token: token)
                    return
                }
            }

            // ACT
            lastFingerprint = axSnap.fingerprint
            let executed: Bool
            if let cap = computerCap {
                executed = executeComputer(action, screen: cap.screen)
            } else if let vs = visSnap {
                executed = executeVision(action, vs)
            } else {
                executed = execute(action, snapshot: &axSnap)
            }
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

    /// Computer-use execution: the model returns 0-999 grid coordinates on the
    /// captured screen; convert via the screen's frame and click/type there.
    private func executeComputer(_ a: WayloAPIClient.AgentAction, screen: NSScreen) -> Bool {
        func axPoint(_ gx: Int, _ gy: Int) -> CGPoint {
            let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
            return CGPoint(x: screen.frame.minX + CGFloat(gx) / 1000.0 * screen.frame.width,
                           y: axTop + CGFloat(gy) / 1000.0 * screen.frame.height)
        }
        // Flash the dot where the agent is about to click — the user should
        // SEE each action land (trust + debuggability), briefly, no lingering.
        func flash(_ p: CGPoint) {
            OverlayWindowController.shared.showDot(at: p, caption: "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if !GuidanceEngine.shared.isRunning { OverlayWindowController.shared.hideDot() }
            }
        }
        switch a.act {
        case "press_at":
            guard let x = a.x, let y = a.y else { return false }
            let p = axPoint(x, y)
            flash(p)
            usleep(250_000)   // let the flash appear before the click
            return AgentExecutor.syntheticClick(at: p)
        case "type_at":
            guard let x = a.x, let y = a.y else { return false }
            let p = axPoint(x, y)
            flash(p)
            usleep(250_000)
            _ = AgentExecutor.syntheticClick(at: p)
            usleep(200_000)
            return AgentExecutor.type(a.text ?? "", into: nil, submit: a.submit ?? false)
        case "type":
            return AgentExecutor.type(a.text ?? "", into: nil, submit: a.submit ?? false)
        case "key":
            return AgentExecutor.key(combo: a.combo ?? "")
        case "menu":
            return AgentExecutor.menu(path: a.path ?? [])
        case "scroll":
            return AgentExecutor.scroll(direction: a.direction ?? "down")
        case "wait":
            return true
        default:
            return false
        }
    }

    /// Vision-turn execution: presses click the CENTRE of the chosen badge's
    /// box (no AX handle exists in an AX-hostile app). Typing/keys/menu/scroll
    /// go through the same executor.
    private func executeVision(_ a: WayloAPIClient.AgentAction, _ vs: VisionSnapshot) -> Bool {
        switch a.act {
        case "press":
            guard let id = a.id, let m = vs.mark(for: id) else {
                DebugLogger.log("AGENT", "vision press: badge \(a.id.map(String.init) ?? "nil") unknown")
                return false
            }
            return AgentExecutor.syntheticClick(at: m.center)
        case "type":
            return AgentExecutor.type(a.text ?? "", into: nil, submit: a.submit ?? false)
        case "key":
            return AgentExecutor.key(combo: a.combo ?? "")
        case "menu":
            return AgentExecutor.menu(path: a.path ?? [])
        case "scroll":
            return AgentExecutor.scroll(direction: a.direction ?? "down")
        case "wait":
            return true
        default:
            return false
        }
    }

    // MARK: - Confirmation

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

    /// Normalizes an action descriptor / history entry for repeat detection:
    /// "menu File > Export…" and "menu File > Export..." must count as the
    /// SAME action or the guards can be sidestepped by spelling variants.
    private static func guardKey(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func describe(_ a: WayloAPIClient.AgentAction) -> String {
        switch a.act {
        case "press":    return "press #\(a.id ?? -1)"
        // Field id included so typing the same text into TWO fields (name +
        // confirm-name) isn't misread as a repeat by the guards.
        case "type":     return "type \"\((a.text ?? "").prefix(30))\"\(a.id.map { " into #\($0)" } ?? "")\(a.submit == true ? " + return" : "")"
        case "key":      return "key \(a.combo ?? "?")"
        case "menu":     return "menu \((a.path ?? []).joined(separator: " > "))"
        case "open_app": return "open app '\(a.name ?? "?")'"
        case "scroll":   return "scroll \(a.direction ?? "down")"
        case "wait":     return "wait \(Int(a.seconds ?? 0))s"
        case "point":    return "point #\(a.id ?? -1)"
        case "press_at": return "press at (\(a.x ?? -1),\(a.y ?? -1))"
        case "type_at":  return "type \"\((a.text ?? "").prefix(30))\" at (\(a.x ?? -1),\(a.y ?? -1))"
        default:         return a.act
        }
    }
}
