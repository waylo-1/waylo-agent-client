import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// High-level state of a running guide.
enum GuidanceState {
    case idle
    case locating   // taking a screenshot / asking the vision model
    case showing    // dot is on screen, waiting for the user to press Next
    case manual     // couldn't locate; user does it themselves then presses Next
    case paused
    case complete
}

/// How the guide interacts with the screen.
/// `.teach`  — point with the dot; the user clicks (the classic mode).
/// `.assist` — "do it with me": Waylo performs safe clicks itself (AXPress
///             when the element is known, else a synthetic click) and narrates.
///             Destructive steps (delete/empty/send/pay…) are NEVER auto-
///             clicked — they fall back to point-and-confirm.
enum GuideMode: String {
    case teach
    case assist
}

/// The orchestrator. Walks through steps one at a time. For each step it shows a
/// screenshot to the vision model (POINT-style), places the red dot at the exact
/// coordinates the model returns, speaks the instruction, and then waits for the
/// user to press Next (button or global hotkey) before advancing.
@MainActor
final class GuidanceEngine: ObservableObject {
    static let shared = GuidanceEngine()

    @Published var isRunning = false
    @Published var state: GuidanceState = .idle
    /// Teach (point) vs assist (do it for me). Persisted across launches.
    @Published var mode: GuideMode = GuideMode(rawValue: UserDefaults.standard.string(forKey: "waylo.guideMode") ?? "") ?? .teach {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "waylo.guideMode") }
    }
    @Published var currentStepIndex = 0
    @Published var stepCount = 0
    @Published var currentInstruction = ""
    @Published var statusMessage = ""

    private var steps: [Step] = []
    private var taskName = ""
    /// When true, the running plan is a locked demo: corrections only relabel the
    /// current step, never replan (so the curated step sequence stays intact).
    private var planLocked = false
    private var debugKeyMonitor: Any?
    /// CGEventTap click observer (observe-only). NSEvent global monitors miss
    /// clicks consumed by menu/Dock tracking loops; the tap sees them all.
    private var clickObserverId: UUID?
    private var keyAdvanceMonitor: Any?
    /// Transient HotkeyManager observer for a "press this combo" step (e.g. ⌘Space).
    private var keyObserverId: UUID?
    /// Current target in AX global coords (for click-to-advance).
    private var currentTargetAX: CGPoint?
    /// How close (in points) a click must be to the dot to count as a hit.
    private let clickToleranceAX: CGFloat = 60
    /// Bumped every time we (re)enter a step so a stale async locate can bail out.
    private var locateToken = 0

    private init() {}

    // MARK: - Lifecycle

    func startGuidance(plan: GuidePlan) {
        NSLog("[Waylo] startGuidance: %d steps, task='%@'", plan.steps.count, plan.task)
        DebugLogger.log("ENGINE", "startGuidance steps=\(plan.steps.count) task='\(plan.task)'")

        // Full reset so a second guide starts clean. onTaskComplete() leaves the
        // engine partially dirty (state=.complete, indices/monitors not cleared);
        // without this reset re-entry would stall.
        resetForNewRun()

        steps = plan.steps
        stepCount = plan.steps.count
        taskName = plan.task
        planLocked = plan.demo
        currentStepIndex = 0
        isRunning = true
        installDebugHotkey()
        if planLocked { DebugLogger.log("ENGINE", "plan LOCKED (demo) — corrections relabel only, no replan") }

        // Retract the panel up into the notch — the guide lives in the notch now.
        NotchPanelController.expansion.pinned = false
        NotchPanelController.expansion.hovering = false
        NotchPanelController.expansion.recompute()

        Task { await executeStep(index: 0) }
    }

    /// Tears down all transient state from any prior run (monitors, dot, timers,
    /// target, tokens) and returns the engine to idle. Shared by stop + start.
    private func resetForNewRun() {
        locateToken += 1
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        removeDebugHotkey()
        OverlayWindowController.shared.hideDot()
        Speaker.shared.stop()
        currentTargetAX = nil
        state = .idle
        statusMessage = ""
        currentInstruction = ""
        currentStepIndex = 0
        planLocked = false
    }

    func stopGuidance() {
        isRunning = false
        state = .idle
        locateToken += 1
        OverlayWindowController.shared.hideDot()
        Speaker.shared.stop()
        removeDebugHotkey()
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        currentTargetAX = nil
        statusMessage = ""
        currentInstruction = ""
        currentStepIndex = 0
        stepCount = 0
    }

    // MARK: - Navigation (Next / Back / Pause / Re-locate)

    /// Advance to the next step. Ignored while a locate is in flight. Allowed
    /// from a paused guide (voice "skip"/"next step" arrives paused, because the
    /// conversation engine pauses before listening) — symmetric with previousStep.
    func nextStep() {
        guard isRunning, state != .locating else { return }
        let target = currentStepIndex + 1
        OverlayWindowController.shared.hideDot()
        Task { await executeStep(index: target) }
    }

    /// Go back one step.
    func previousStep() {
        guard isRunning, state != .locating, currentStepIndex > 0 else { return }
        let target = currentStepIndex - 1
        OverlayWindowController.shared.hideDot()
        Task { await executeStep(index: target) }
    }

    /// Re-run the current step (take a fresh screenshot and re-locate).
    func relocate() {
        guard isRunning, state != .locating else { return }
        let target = currentStepIndex
        OverlayWindowController.shared.hideDot()
        Task { await executeStep(index: target) }
    }

    func pauseGuide() {
        guard isRunning, state != .paused else { return }
        state = .paused
        locateToken += 1
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        OverlayWindowController.shared.hideDot()
        Speaker.shared.stop()
        statusMessage = "Paused"
    }

    func resumeGuide() {
        guard isRunning, state == .paused else { return }
        let target = currentStepIndex
        Task { await executeStep(index: target) }
    }

    // MARK: - Step execution

    private func executeStep(index: Int) async {
        guard isRunning else { return }
        guard index >= 0 else { return }
        guard index < steps.count else {
            await onTaskComplete()
            return
        }

        let step = steps[index]
        currentStepIndex = index
        currentInstruction = step.instruction
        statusMessage = "Step \(index + 1) of \(steps.count)"
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        currentTargetAX = nil

        if step.silent {
            Speaker.shared.stop() // pure-wait step (e.g. countdown): show, don't narrate
        } else {
            Speaker.shared.speak(step.instruction)
        }

        // Defensive: a planner sometimes emits a keyboard shortcut as a "click"
        // step (e.g. targetLabel "Press Command+Space"). Don't run the locator on
        // that forever — reroute it to a key/info step that just shows a banner.
        let effective = keystrokeRerouted(step) ?? step
        switch effective.action {
        case .click:
            await locateAndShow(step: effective)
        case .type, .key, .info:
            presentNonClickStep(effective)
        }
    }

    /// If a `.click` step is really a keyboard instruction ("Press Command+Space"),
    /// returns a rerouted key/info step; otherwise nil (it's a genuine click).
    private func keystrokeRerouted(_ step: Step) -> Step? {
        guard step.action == .click else { return nil }
        let text = "\(step.instruction) \(step.targetLabel) \(step.elementDescription)".lowercased()
        guard text.contains("press ") || text.contains("hold ") else { return nil }
        let keyWords = ["command", "cmd", "⌘", "control", "ctrl", "⌃", "option", "⌥",
                        "return", "enter", "spacebar", "space", "spotlight", "escape", " esc", "tab"]
        guard keyWords.contains(where: { text.contains($0) }) else { return nil }

        let hasModifier = ["command", "cmd", "⌘", "control", "ctrl", "⌃",
                           "option", "opt", "⌥", "shift", "⇧"].contains { text.contains($0) }

        let key: String?
        if hasModifier, Self.letterAfterModifier(in: text) != nil {
            // A modifier+letter combo ("Command+T") — leave key nil so
            // keyComboForStep parses the exact combo. Scanning named keys here
            // would misfire on incidental words ("…to open a new tab").
            key = nil
        }
        // "backspace"/"delete" must be checked BEFORE "space" — "backspace"
        // contains "space" and used to parse as the spacebar.
        else if text.contains("backspace") || text.contains("delete") { key = "delete" }
        else if text.contains("space") || text.contains("spotlight") { key = "space" }
        else if text.contains("return") || text.contains("enter") { key = "return" }
        else if text.contains("escape") || text.contains(" esc") { key = "escape" }
        else if text.contains("tab") { key = "tab" }
        else { key = nil } // a modifier+letter combo — keyComboForStep parses it

        // If there's a modifier (⌘/⌥/⌃/⇧) we can still detect the exact combo even
        // without a named key, so route to .key; only fall back to .info when
        // there's nothing detectable to listen for.
        let action: StepAction = (key != nil || hasModifier) ? .key : .info

        DebugLogger.log("ENGINE", "rerouting keystroke step '\(step.instruction)' → \(action == .key ? "key=\(key ?? "combo")" : "info")")
        return Step(
            index: step.index, instruction: step.instruction, findDescription: step.findDescription,
            targetLabel: "", elementDescription: step.elementDescription,
            action: action, key: key, screenRegion: step.screenRegion,
            targetType: .text, controlKind: step.controlKind,
            anchorText: step.anchorText, anchorPosition: step.anchorPosition
        )
    }

    /// Non-click steps (type text / press a key / informational). Shows a banner
    /// and advances when the user commits (Return, or the specified key).
    private func presentNonClickStep(_ step: Step) {
        locateToken += 1
        state = .showing
        OverlayWindowController.shared.showBanner(step.instruction)

        switch step.action {
        case .info:
            if step.advanceOnAnyClick {
                statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click it and I'll continue"
                installAnyClickAdvance(forStep: currentStepIndex, bufferSeconds: 3.0)
            } else if step.autoAdvanceSeconds > 0 {
                statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — continuing automatically…"
                scheduleAutoAdvance(after: step.autoAdvanceSeconds, forStep: currentStepIndex)
            } else {
                statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — press Next when ready"
            }
        case .key:
            // A "press this key/combo" step. Detect the EXACT combo (incl. system
            // shortcuts like ⌘Space) and advance the instant the user presses it.
            if let combo = keyComboForStep(step) {
                statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — press \(comboDisplayName(combo)) (or Next)"
                installKeyComboAdvance(forStep: currentStepIndex, combo: combo)
            } else {
                statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — do it, then press \(keyName(for: step))"
                installKeyAdvanceMonitor(forStep: currentStepIndex, step: step)
            }
        default:
            statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — do it, then press \(keyName(for: step))"
            installKeyAdvanceMonitor(forStep: currentStepIndex, step: step)
        }
    }

    /// Advances when Waylo senses ANY left-click (used for steps it can't point to
    /// but the user can click themselves, e.g. a search result). After the click it
    /// waits `bufferSeconds` so the next screen can load before the next prompt.
    private func installAnyClickAdvance(forStep stepIndex: Int, bufferSeconds: Double) {
        removeClickMonitor()
        clickObserverId = HotkeyManager.shared.addClickObserver { [weak self] axPoint, _ in
            Task { @MainActor in
                guard let self = self, self.isRunning, self.state == .showing,
                      self.currentStepIndex == stepIndex,
                      !self.clickIsOnWayloUI(axPoint) else { return }
                self.removeClickMonitor()
                DebugLogger.log("ENGINE", "any-click sensed → advancing step \(stepIndex + 1) after \(bufferSeconds)s buffer")
                OverlayWindowController.shared.hideDot()
                try? await Task.sleep(nanoseconds: UInt64(bufferSeconds * 1_000_000_000))
                guard self.isRunning, self.currentStepIndex == stepIndex else { return }
                await self.executeStep(index: stepIndex + 1)
            }
        }
    }

    /// True when the click landed on one of Waylo's own interactive windows
    /// (the notch panel). The event tap sees ALL clicks — including ours —
    /// unlike the old NSEvent global monitor which excluded our app.
    private func clickIsOnWayloUI(_ axPoint: CGPoint) -> Bool {
        let cocoa = ScreenCoordinates.axToCocoa(axPoint)
        return NSApp.windows.contains {
            $0.isVisible && !$0.ignoresMouseEvents && $0.frame.contains(cocoa)
        }
    }

    /// Auto-advances the current info step after `seconds`, unless the user has
    /// moved on / corrected / paused in the meantime (guarded by the locate token).
    private func scheduleAutoAdvance(after seconds: Double, forStep stepIndex: Int) {
        let token = locateToken
        DebugLogger.log("ENGINE", "auto-advance armed: \(seconds)s for step \(stepIndex + 1)")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard self.isRunning, self.state == .showing,
                  self.currentStepIndex == stepIndex, token == self.locateToken else { return }
            DebugLogger.log("ENGINE", "auto-advance firing → step \(stepIndex + 2)")
            OverlayWindowController.shared.hideDot()
            await self.executeStep(index: stepIndex + 1)
        }
    }

    private func keyName(for step: Step) -> String {
        switch (step.key ?? "").lowercased() {
        case "tab": return "Tab"
        case "space": return "Space"
        case "escape", "esc": return "Esc"
        case "delete", "backspace": return "Delete"
        default: return "Enter"
        }
    }

    /// Layered locating: capture screen → OCR → YOLO → AX → Nova → dot.
    private func locateAndShow(step: Step) async {
        locateToken += 1
        let token = locateToken
        removeClickMonitor()
        currentTargetAX = nil

        state = .locating
        statusMessage = "Finding it on screen..."

        guard ScreenRecordingPermission.isGranted else {
            // Screen capture (and thus OCR) needs Screen Recording.
            NSLog("[Waylo] locate: Screen Recording NOT granted")
            state = .manual
            statusMessage = "Enable Screen Recording for Waylo, then press Next."
            ScreenRecordingPermission.openSettings()
            Speaker.shared.speak("Please enable screen recording for Waylo in System Settings, then press Next.")
            return
        }

        // Capture the active display (excludes Waylo's own windows).
        guard let firstCapture = await ScreenCapturer.shared.captureActiveScreen() else {
            NSLog("[Waylo] locate: captureActiveScreen returned nil")
            guard token == locateToken, isRunning else { return }
            state = .manual
            statusMessage = "I couldn't read the screen. Do it yourself, then press Next."
            return
        }
        var capture = firstCapture
        NSLog("[Waylo] locate: captured screen %dx%d, resolving step %d", capture.image.width, capture.image.height, currentStepIndex + 1)
        guard token == locateToken, isRunning else { return }

        var resolution = await CoordinateResolver.shared.resolve(
            capture: capture,
            targetLabel: step.targetLabel,
            elementDescription: step.elementDescription,
            stepInstruction: step.instruction,
            findDescription: step.findDescription,
            screenRegion: step.screenRegion,
            task: taskName,
            stepIndex: step.index,
            totalSteps: steps.count,
            cacheKey: step.labelCacheKey,
            targetType: step.targetType,
            controlKind: step.controlKind,
            anchorText: step.anchorText,
            anchorPosition: step.anchorPosition
        )
        guard token == locateToken, isRunning else { return }

        // Retry ONCE after 800ms — the app may be mid-animation (a menu opening,
        // a window appearing) so the AX tree / screenshot are momentarily stale.
        if resolution == nil {
            DebugLogger.log("ENGINE", "RETRY after 800ms (step \(currentStepIndex + 1)) — all layers missed")
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard token == locateToken, isRunning else { return }
            if let fresh = await ScreenCapturer.shared.captureActiveScreen() {
                guard token == locateToken, isRunning else { return }
                capture = fresh
                resolution = await CoordinateResolver.shared.resolve(
                    capture: capture,
                    targetLabel: step.targetLabel,
                    elementDescription: step.elementDescription,
                    stepInstruction: step.instruction,
                    findDescription: step.findDescription,
                    screenRegion: step.screenRegion,
                    task: taskName,
                    stepIndex: step.index,
                    totalSteps: steps.count,
                    cacheKey: step.labelCacheKey,
                    targetType: step.targetType,
                    controlKind: step.controlKind,
                    anchorText: step.anchorText,
                    anchorPosition: step.anchorPosition
                )
                guard token == locateToken, isRunning else { return }
            }
        }

        if let resolution = resolution {
            applyUpdatedInstruction(resolution.updatedInstruction)

            // Several confident, distinct matches — never guess. Show numbered
            // badges on all of them and let the user click the right one.
            if !resolution.alternates.isEmpty {
                presentAmbiguity(step: step, primary: resolution.axPoint, alternates: resolution.alternates)
                return
            }

            // Assist mode: perform safe clicks ourselves (destructive steps
            // still fall back to point-and-confirm inside autoPerform).
            if mode == .assist && step.action == .click {
                await autoPerform(step: step, resolution: resolution, stepIndex: currentStepIndex, token: token)
                return
            }

            currentTargetAX = resolution.axPoint
            OverlayWindowController.shared.showDot(at: resolution.axPoint, caption: currentInstruction)
            state = .showing
            statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click the dot to continue"
            // Seamless: clicking on/near the dot advances to the next step.
            installClickMonitor(target: resolution.axPoint, forStep: currentStepIndex, secondary: isSecondaryClickStep(step))
            return
        }

        // Before giving up, self-heal. RECOVERY runs FIRST: the most common
        // failure is a planner label that differs from the visible one (step
        // says "Empty Trash", the real button is "Empty") — /recover relabels
        // that in ~2s. The old order sent the user scrolling for ~18s even
        // when the element was already on screen under a different name.
        guard token == locateToken, isRunning else { return }
        if await attemptRecovery(step: step, capture: capture, token: token) { return }
        guard token == locateToken, isRunning else { return }
        // Recovery produced nothing usable — the element may genuinely be off
        // screen. Only offer to scroll when the screen ACTUALLY has a
        // scrollable area (a long settings/list pane). Menus, the menu bar,
        // and small dialogs can't scroll.
        if AccessibilityReader.shared.targetHasScrollArea() {
            if await beginScrollAssist(step: step, token: token) { return }
            guard token == locateToken, isRunning else { return }
        }
        OverlayWindowController.shared.hideDot()
        state = .manual
        statusMessage = "I couldn't find it. Do it yourself, then press Next."
        Speaker.shared.speak("I couldn't find that one. Please do it yourself, then press Next.")
    }

    // MARK: - Assist mode ("do it with me")

    /// Performs the click for the user: AXPress on the resolved element when
    /// available (works for menus/buttons without moving the mouse), else a
    /// synthetic click at the resolved point. Destructive steps are never
    /// auto-clicked — they show the dot and wait for the user's own click.
    private func autoPerform(step: Step, resolution: CoordinateResolver.Resolution, stepIndex: Int, token: Int) async {
        currentTargetAX = resolution.axPoint
        OverlayWindowController.shared.showDot(at: resolution.axPoint, caption: currentInstruction)
        state = .showing

        if isDestructiveStep(step) {
            statusMessage = "Step \(stepIndex + 1) of \(steps.count) — this one changes things; click it yourself to confirm"
            Speaker.shared.speak("This one deletes or changes things, so you click it yourself — I'll continue right after.")
            DebugLogger.log("ASSIST", "destructive step \(stepIndex + 1) — falling back to point-and-confirm")
            installClickMonitor(target: resolution.axPoint, forStep: stepIndex, secondary: isSecondaryClickStep(step))
            return
        }

        statusMessage = "Step \(stepIndex + 1) of \(steps.count) — doing it for you…"
        // Brief pause so the user sees WHERE before the click happens —
        // assist mode should still teach, not teleport.
        try? await Task.sleep(nanoseconds: 900_000_000)
        guard token == locateToken, isRunning, currentStepIndex == stepIndex else { return }

        var pressed = false
        if let el = resolution.axElement {
            pressed = AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
            DebugLogger.log("ASSIST", "AXPress \(pressed ? "OK" : "failed → synthetic click")")
        }
        if !pressed { performSyntheticClick(at: resolution.axPoint) }
        advanceAfterClick(stepIndex: stepIndex)
    }

    /// Posts a real left-click at the point (Quartz global coords, which is
    /// exactly what the resolver returns).
    private func performSyntheticClick(at axPoint: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: axPoint, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: axPoint, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DebugLogger.log("ASSIST", "synthetic click at (\(Int(axPoint.x)),\(Int(axPoint.y)))")
    }

    /// True when auto-clicking this step could destroy/commit something the
    /// user didn't explicitly confirm. Over-gating is safe (the user just
    /// clicks it themselves); under-gating is not.
    private func isDestructiveStep(_ step: Step) -> Bool {
        let t = "\(step.instruction) \(step.targetLabel) \(step.elementDescription)".lowercased()
        let danger = ["empty", "delete", "erase", "remove", "discard", "uninstall",
                      "format", "don't save", "dont save", "send", "pay", "buy",
                      "purchase", "shut down", "restart", "log out", "sign out"]
        return danger.contains { t.contains($0) }
    }

    // MARK: - Ambiguity ("Empty" in three places — ask, don't guess)

    /// Shows numbered badges over every confident match; the user's click on
    /// any of them completes the step.
    private func presentAmbiguity(step: Step, primary: CGPoint, alternates: [CGPoint]) {
        let all = [primary] + alternates
        state = .showing
        statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — I see \(all.count) matches; click the right one"
        OverlayWindowController.shared.showCandidateBadges(at: all, caption: currentInstruction)
        Speaker.shared.speak("I found \(all.count) places that look right. Click the correct one and I'll continue.")
        installMultiClickMonitor(targets: all, forStep: currentStepIndex)
    }

    /// Click monitor accepting a click near ANY of the candidate targets.
    private func installMultiClickMonitor(targets: [CGPoint], forStep stepIndex: Int) {
        removeClickMonitor()
        clickObserverId = HotkeyManager.shared.addClickObserver { [weak self] axPoint, _ in
            Task { @MainActor in
                guard let self = self, self.isRunning, self.state == .showing,
                      self.currentStepIndex == stepIndex,
                      !self.clickIsOnWayloUI(axPoint) else { return }
                guard let hit = targets.first(where: {
                    hypot($0.x - axPoint.x, $0.y - axPoint.y) <= self.clickToleranceAX
                }) else {
                    DebugLogger.log("CLICK", "ambiguity: click missed all \(targets.count) candidates")
                    return
                }
                self.currentTargetAX = hit
                DebugLogger.log("ENGINE", "ambiguity resolved by user click at (\(Int(hit.x)),\(Int(hit.y))) → advancing")
                self.advanceAfterClick(stepIndex: stepIndex)
            }
        }
    }

    /// Self-healing: screenshot → backend `/recover`. The model can correct the
    /// element label (then we retry OCR/AX) or replan all remaining steps.
    /// Returns true if it handled the step (showed a dot or replanned).
    private func attemptRecovery(step: Step, capture: ScreenCapturer.Capture, token: Int, userMessage: String = "") async -> Bool {
        state = .locating
        statusMessage = userMessage.isEmpty ? "Let me take a closer look..." : "Got it — let me fix that..."
        let spinnerPoint = ScreenCoordinates.cocoaToAX(NSEvent.mouseLocation)
        OverlayWindowController.shared.showLoading(at: spinnerPoint)

        guard let (base64, size) = ScreenCapturer.compressedJPEGBase64(capture.image) else { return false }

        let result: RecoverResult
        do {
            result = try await WayloAPIClient.shared.recover(
                screenshotBase64: base64,
                imageWidth: Int(size.width),
                imageHeight: Int(size.height),
                task: taskName,
                stepIndex: step.index,
                totalSteps: steps.count,
                instruction: step.instruction,
                targetLabel: step.targetLabel,
                userMessage: userMessage
            )
        } catch {
            print("[Engine] recover failed: \(error)")
            return false
        }

        guard token == locateToken, isRunning else { return true }
        OverlayWindowController.shared.hideDot()

        // 1. Replan: replace remaining steps and continue from here.
        //    Suppressed for locked demo plans — a correction must never rewrite
        //    the curated step sequence; it should only re-point the current step.
        if result.replan, !result.steps.isEmpty, !planLocked {
            print("[Engine] replanning \(result.steps.count) steps from index \(currentStepIndex)")
            replacePlan(from: currentStepIndex, with: result.steps)
            await executeStep(index: currentStepIndex)
            return true
        }
        if result.replan, planLocked {
            DebugLogger.log("ENGINE", "replan IGNORED (plan locked) — will relabel current step instead")
        }

        // 2. Scroll assist: the element is off-screen but would appear on scroll.
        if !result.scrollDirection.isEmpty {
            let found = await beginScrollAssist(step: step, token: token,
                                                direction: result.scrollDirection,
                                                instruction: result.updatedInstruction)
            if !found {
                // Timed out: clear the arrow and hand over to the user instead
                // of leaving a stale scroll prompt on screen.
                guard token == locateToken, isRunning else { return true }
                OverlayWindowController.shared.hideDot()
                state = .manual
                statusMessage = "I couldn't find it. Do it yourself, then press Next."
                Speaker.shared.speak("I couldn't find that one. Please do it yourself, then press Next.")
            }
            return true
        }

        // 2. Relabel: retry the resolver with the model's corrected label. For a
        //    locked demo plan, if the model gave no clean label, fall back to the
        //    user's own spoken words as the target hint (Nova handles a
        //    natural-language target), so a correction always re-points the dot.
        var relabel = result.visibleLabel
        if relabel.isEmpty, planLocked, !userMessage.isEmpty {
            relabel = userMessage
            DebugLogger.log("ENGINE", "locked plan: using spoken correction as target hint → '\(relabel)'")
        }
        if !relabel.isEmpty {
            let retry = await CoordinateResolver.shared.resolve(
                capture: capture,
                targetLabel: relabel,
                elementDescription: relabel,
                stepInstruction: step.instruction,
                findDescription: relabel,
                screenRegion: step.screenRegion,
                task: taskName,
                stepIndex: step.index,
                totalSteps: steps.count,
                targetType: step.targetType,
                controlKind: step.controlKind
            )
            guard token == locateToken, isRunning else { return true }
            if let retry = retry {
                // Cache only a clean model label (not a fallback sentence) so
                // future runs skip recovery/Nova.
                if !result.visibleLabel.isEmpty {
                    WayloAPIClient.shared.storeLabel(
                        appName: TargetAppTracker.shared.targetName,
                        stepDescription: step.labelCacheKey,
                        axLabel: result.visibleLabel
                    )
                    DebugLogger.log("RESOLVE", "LABEL_CACHE_STORED (relabel): '\(result.visibleLabel)' for key '\(step.labelCacheKey)'")
                    DebugState.shared.update(cache: "STORED \(result.visibleLabel)")
                }
                applyUpdatedInstruction(result.updatedInstruction)
                if !retry.alternates.isEmpty {
                    presentAmbiguity(step: step, primary: retry.axPoint, alternates: retry.alternates)
                    return true
                }
                if mode == .assist && step.action == .click {
                    await autoPerform(step: step, resolution: retry, stepIndex: currentStepIndex, token: token)
                    return true
                }
                currentTargetAX = retry.axPoint
                OverlayWindowController.shared.showDot(at: retry.axPoint, caption: currentInstruction)
                state = .showing
                statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click the dot to continue"
                installClickMonitor(target: retry.axPoint, forStep: currentStepIndex, secondary: isSecondaryClickStep(step))
                return true
            }
        }

        return false
    }

    /// The element isn't on screen — it's probably off the visible area. Show a
    /// bouncing arrow at the scroll bar and ask the user to scroll, polling
    /// (AX + OCR only — fast, free) until it appears. Returns true if found.
    @discardableResult
    private func beginScrollAssist(step: Step, token: Int, direction: String = "", instruction: String = "") async -> Bool {
        let label = step.targetLabel.isEmpty ? step.instruction : step.targetLabel
        // Scroll-bar anchor: right edge of the target app's window, vertically
        // centered. Falls back to the right edge of the primary screen.
        func scrollAnchor() -> CGPoint {
            if let f = AccessibilityReader.shared.targetFocusedWindowFrame() {
                return CGPoint(x: f.maxX - 22, y: f.midY)
            }
            let s = ScreenCoordinates.primaryScreen?.frame ?? .zero
            return CGPoint(x: s.width - 22, y: ScreenCoordinates.primaryHeight / 2)
        }

        // Direction: honor an explicit hint, else start downward (most common).
        var down = direction.lowercased() != "up"
        let baseText = instruction.isEmpty
            ? "I can't see \(label) yet — scroll to find it and I'll point to it."
            : instruction
        DebugLogger.log("ENGINE", "scroll assist: arrow for '\(label)' (start down=\(down))")

        state = .manual
        currentInstruction = baseText

        // Poll up to ~18s. Flip the arrow direction halfway so the user tries
        // both ways if the first doesn't reveal it.
        let attempts = 12
        for attempt in 0..<attempts {
            if attempt == attempts / 2 && direction.isEmpty { down.toggle() }
            statusMessage = "Scroll \(down ? "down" : "up") to find it…"
            OverlayWindowController.shared.showScrollArrow(
                at: scrollAnchor(), down: down,
                caption: "Scroll \(down ? "down" : "up") to find \(label)")
            if attempt == 0 { Speaker.shared.speak(baseText) }

            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard token == locateToken, isRunning else { return false }
            guard let capture = await ScreenCapturer.shared.captureActiveScreen() else { continue }
            guard token == locateToken, isRunning else { return false }

            let resolution = await CoordinateResolver.shared.resolve(
                capture: capture,
                targetLabel: step.targetLabel,
                elementDescription: step.elementDescription,
                stepInstruction: step.instruction,
                findDescription: step.findDescription,
                screenRegion: step.screenRegion,
                task: taskName,
                stepIndex: step.index,
                totalSteps: steps.count,
                cacheKey: step.labelCacheKey,
                localOnly: true,
                targetType: step.targetType,
                controlKind: step.controlKind,
                anchorText: step.anchorText,
                anchorPosition: step.anchorPosition
            )
            guard token == locateToken, isRunning else { return false }

            if let resolution = resolution {
                DebugLogger.log("ENGINE", "scroll assist: found after \(attempt + 1) checks")
                currentTargetAX = resolution.axPoint
                OverlayWindowController.shared.showDot(at: resolution.axPoint, caption: currentInstruction)
                state = .showing
                statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click the dot to continue"
                installClickMonitor(target: resolution.axPoint, forStep: currentStepIndex, secondary: isSecondaryClickStep(step))
                return true
            }
        }

        guard token == locateToken, isRunning else { return false }
        DebugLogger.log("ENGINE", "scroll assist: timed out for '\(label)'")
        return false
    }

    /// Replaces steps from `index` onward with a fresh plan, re-indexing them.
    private func replacePlan(from index: Int, with newSteps: [Step]) {
        let head = Array(steps.prefix(index))
        let renumbered = newSteps.enumerated().map { offset, s in
            Step(
                index: index + offset,
                instruction: s.instruction,
                findDescription: s.findDescription,
                targetLabel: s.targetLabel,
                elementDescription: s.elementDescription,
                action: s.action,
                key: s.key,
                screenRegion: s.screenRegion,
                targetType: s.targetType,
                controlKind: s.controlKind,
                anchorText: s.anchorText,
                anchorPosition: s.anchorPosition,
                autoAdvanceSeconds: s.autoAdvanceSeconds,
                silent: s.silent,
                advanceOnAnyClick: s.advanceOnAnyClick
            )
        }
        steps = head + renumbered
        stepCount = steps.count
    }

    private func applyUpdatedInstruction(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentInstruction else { return }
        currentInstruction = trimmed
        Speaker.shared.speak(trimmed)
    }

    private func onTaskComplete() async {
        state = .complete
        OverlayWindowController.shared.hideDot()
        statusMessage = "Task complete! 🎉"
        currentInstruction = "All done! You've completed the task."
        Speaker.shared.speak("All done! You've completed the task.")
        removeDebugHotkey()
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        isRunning = false

        // Record the finished guide so the user can rate it (✓ caches it as
        // correct, ✗ forgets it) from the panel's history list.
        if !taskName.isEmpty, !steps.isEmpty {
            TaskHistory.shared.record(task: taskName, steps: steps)
        }
    }

    // MARK: - Global debug hotkey (Ctrl+Option+N) — re-check / fix the step

    private func installDebugHotkey() {
        // Re-detect (⌃⌥⌘N) is now owned centrally by HotkeyManager via a
        // CGEventTap, so it works in any app and doesn't clash with system
        // shortcuts. Nothing to install here.
    }

    private func removeDebugHotkey() {
        if let monitor = debugKeyMonitor {
            NSEvent.removeMonitor(monitor)
            debugKeyMonitor = nil
        }
    }

    /// Debug / "that's wrong" action: re-screenshot the current step and run the
    /// recovery path (relabel or replan) so the AI can correct itself.
    func debugRelocate() {
        guard isRunning, state != .locating else {
            DebugLogger.log("ENGINE", "debugRelocate ignored (isRunning=\(isRunning) state=\(state))")
            return
        }
        DebugLogger.log("ENGINE", "debugRelocate → forcing fresh screenshot + Nova recovery for step \(currentStepIndex + 1)")
        let idx = currentStepIndex
        OverlayWindowController.shared.hideDot()
        Task { await forceRecover(stepIndex: idx) }
    }

    private func forceRecover(stepIndex: Int) async {
        guard isRunning, stepIndex >= 0, stepIndex < steps.count else { return }
        let step = steps[stepIndex]
        currentStepIndex = stepIndex
        currentInstruction = step.instruction

        locateToken += 1
        let token = locateToken
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        currentTargetAX = nil

        state = .locating
        statusMessage = "Re-checking the screen..."
        let spinner = ScreenCoordinates.cocoaToAX(NSEvent.mouseLocation)
        OverlayWindowController.shared.showLoading(at: spinner)

        guard ScreenRecordingPermission.isGranted,
              let capture = await ScreenCapturer.shared.captureActiveScreen() else {
            guard token == locateToken, isRunning else { return }
            OverlayWindowController.shared.hideDot()
            state = .manual
            statusMessage = "I couldn't read the screen. Do it yourself, then press Next."
            return
        }
        guard token == locateToken, isRunning else { return }

        // Force the recovery path (relabel / replan). Falls back to a normal
        // locate if recovery produced nothing usable.
        if await attemptRecovery(step: step, capture: capture, token: token) { return }
        guard token == locateToken, isRunning else { return }
        await locateAndShow(step: step)
    }

    // MARK: - Voice correction / follow-up

    /// Spoken feedback while a guide is running (Ctrl+Option+Space). The message
    /// is sent to the recovery model with a fresh screenshot so it can relabel
    /// the current step, replan the remaining steps, or otherwise correct itself,
    /// then continue from the corrected point. Simple navigation words are handled
    /// locally for an instant response.
    func applyVoiceCorrection(_ message: String) {
        guard isRunning else { return }
        let lower = message.lowercased()

        // Fast-path navigation so "next"/"go back"/"repeat" don't need a round trip.
        if lower.contains("go back") || lower.contains("previous") {
            Speaker.shared.speak("Going back.")
            previousStep(); return
        }
        if lower.contains("skip") || lower.contains("next step") || lower == "next" {
            Speaker.shared.speak("Skipping ahead.")
            nextStep(); return
        }
        if lower.contains("repeat") || lower.contains("say again") || lower.contains("show me again") {
            Speaker.shared.speak("Here it is again.")
            relocate(); return
        }

        DebugLogger.log("VOICE", "correction='\(message)' at step \(currentStepIndex)")
        let idx = currentStepIndex
        OverlayWindowController.shared.hideDot()
        Task { await runVoiceCorrection(stepIndex: idx, message: message) }
    }

    private func runVoiceCorrection(stepIndex: Int, message: String) async {
        guard isRunning, stepIndex >= 0, stepIndex < steps.count else { return }
        let step = steps[stepIndex]
        currentStepIndex = stepIndex
        currentInstruction = step.instruction

        locateToken += 1
        let token = locateToken
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        currentTargetAX = nil

        state = .locating
        statusMessage = "Got it — let me fix that..."
        let spinner = ScreenCoordinates.cocoaToAX(NSEvent.mouseLocation)
        OverlayWindowController.shared.showLoading(at: spinner)

        guard ScreenRecordingPermission.isGranted,
              let capture = await ScreenCapturer.shared.captureActiveScreen() else {
            guard token == locateToken, isRunning else { return }
            OverlayWindowController.shared.hideDot()
            state = .manual
            statusMessage = "I couldn't read the screen. Do it yourself, then press Next."
            return
        }
        guard token == locateToken, isRunning else { return }

        // Send the spoken feedback to the recovery model (relabel / replan).
        if await attemptRecovery(step: step, capture: capture, token: token, userMessage: message) { return }

        // Recovery produced nothing usable — fall back to a normal locate so the
        // guide still moves forward.
        guard token == locateToken, isRunning else { return }
        await locateAndShow(step: step)
    }

    // MARK: - Click-to-advance

    /// Installs a global click monitor. For a normal click step, a left-click
    /// on/near the dot advances. For a right-click ("Control-click") step, a
    /// right-click (or control-click) ANYWHERE advances — the user shouldn't have
    /// to also left-click the dot.
    private func installClickMonitor(target: CGPoint, forStep stepIndex: Int, secondary: Bool) {
        removeClickMonitor()
        clickObserverId = HotkeyManager.shared.addClickObserver { [weak self] axPoint, isRight in
            Task { @MainActor in
                self?.handleGlobalClick(atAX: axPoint, target: target, stepIndex: stepIndex,
                                        secondary: secondary, isRight: isRight)
            }
        }
    }

    private func handleGlobalClick(atAX clickAX: CGPoint, target: CGPoint, stepIndex: Int, secondary: Bool, isRight: Bool) {
        guard isRunning, state == .showing, currentStepIndex == stepIndex else { return }
        guard !clickIsOnWayloUI(clickAX) else { return }

        let dx = clickAX.x - target.x
        let dy = clickAX.y - target.y
        let dist = (dx * dx + dy * dy).squareRoot()
        // Always log while showing — makes "clicked but nothing happened"
        // diagnosable from the debug log (distance vs tolerance).
        DebugLogger.log("CLICK", String(format: "%@ at (%.0f,%.0f) target=(%.0f,%.0f) dist=%.0f tol=%.0f",
            isRight ? "right" : "left", clickAX.x, clickAX.y, target.x, target.y, dist, clickToleranceAX))

        if secondary {
            // A right-click (or control-click) anywhere completes a right-click step.
            guard isRight else { return }
            DebugLogger.log("ENGINE", "right-click detected → advancing step \(stepIndex + 1)")
            advanceAfterClick(stepIndex: stepIndex)
            return
        }

        // Normal step: a left-click must land on/near the dot.
        guard dist <= clickToleranceAX else { return }
        advanceAfterClick(stepIndex: stepIndex)
    }

    /// Shared "click landed → move on" handler. Shows an immediate spinner at
    /// the target so the user KNOWS the click registered, then advances after
    /// a short settle (lets the next screen/dialog open before we screenshot).
    private func advanceAfterClick(stepIndex: Int) {
        removeClickMonitor()
        if let target = currentTargetAX {
            OverlayWindowController.shared.showLoading(at: target)
        } else {
            OverlayWindowController.shared.hideDot()
        }
        let next = stepIndex + 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nextStepDelayNanos())
            guard self.isRunning, self.currentStepIndex == stepIndex else { return }
            await self.executeStep(index: next)
        }
    }

    /// Settle time between a registered click and the next step's locate —
    /// long enough for the resulting window/dialog to appear, short enough to
    /// feel responsive. (Was 1.8–2.0s, which read as "nothing happened".)
    private func nextStepDelayNanos() -> UInt64 {
        UInt64(Double.random(in: 1.0...1.2) * 1_000_000_000)
    }

    /// True when the step asks the user to right-click / Control-click / open a
    /// context menu — so a right-click should advance it.
    private func isSecondaryClickStep(_ step: Step) -> Bool {
        let t = "\(step.instruction) \(step.elementDescription)".lowercased()
        return t.contains("right click") || t.contains("right-click")
            || t.contains("control-click") || t.contains("control click")
            || t.contains("secondary click") || t.contains("context menu")
            || t.contains("two-finger") || t.contains("two finger")
    }

    private func removeClickMonitor() {
        if let id = clickObserverId {
            HotkeyManager.shared.removeClickObserver(id)
            clickObserverId = nil
        }
    }

    // MARK: - Key-to-advance (for type / key steps)

    /// Registers an observe-only matcher (via the CGEventTap) so the step advances
    /// the moment the user presses the exact key combo — works even for system
    /// shortcuts like ⌘Space that an NSEvent global monitor never receives.
    private func installKeyComboAdvance(forStep stepIndex: Int, combo: (keyCode: CGKeyCode, flags: CGEventFlags)) {
        removeKeyAdvanceMonitor()
        DebugLogger.log("ENGINE", "key-combo advance armed: \(comboDisplayName(combo)) for step \(stepIndex + 1)")
        keyObserverId = HotkeyManager.shared.addKeyObserver(keyCode: combo.keyCode, flags: combo.flags) { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isRunning, self.state == .showing,
                      self.currentStepIndex == stepIndex else { return }
                DebugLogger.log("ENGINE", "key combo pressed → advancing step \(stepIndex + 1)")
                self.advanceAfterKey(stepIndex: stepIndex)
            }
        }
    }

    /// Parses a `.key` step into the keycode + modifier flags to listen for.
    /// Reads modifiers from the instruction text and the main key from `step.key`
    /// (or the text). Returns nil if no key could be determined.
    private func keyComboForStep(_ step: Step) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        let text = "\(step.instruction) \(step.elementDescription) \(step.targetLabel)".lowercased()
        var flags: CGEventFlags = []
        if text.contains("command") || text.contains("cmd") || text.contains("⌘") { flags.insert(.maskCommand) }
        if text.contains("option") || text.contains("opt") || text.contains("⌥") || text.contains(" alt") { flags.insert(.maskAlternate) }
        if text.contains("control") || text.contains("ctrl") || text.contains("⌃") { flags.insert(.maskControl) }
        if text.contains("shift") || text.contains("⇧") { flags.insert(.maskShift) }

        // Main key: prefer the explicit `key` field, then a modifier+letter
        // combo (e.g. "Command + S"), then named keys in the text. The combo
        // letter must be checked before named-key words: "Press ⌘T to open a
        // new tab" is ⌘T, not ⌘Tab. Delete/backspace before space, because
        // "backspace" contains "space".
        if let code = Self.namedKeyCode(step.key ?? "") { return (code, flags) }
        if !flags.isEmpty, let letter = Self.letterAfterModifier(in: text),
           let code = Self.letterKeyCode(letter) {
            return (code, flags)
        }
        if text.contains("backspace") || text.contains("delete") { return (51, flags) }
        if text.contains("spotlight") || text.contains("space") { return (49, flags) }
        if text.contains("return") || text.contains("enter") { return (36, flags) }
        if text.contains("escape") || text.contains(" esc") { return (53, flags) }
        if text.contains("tab") { return (48, flags) }
        if let letter = Self.letterAfterModifier(in: text), let code = Self.letterKeyCode(letter) {
            return (code, flags)
        }
        return nil
    }

    /// Maps a named key string to its US-ANSI keycode.
    private static func namedKeyCode(_ raw: String) -> CGKeyCode? {
        switch raw.lowercased() {
        case "space", "spacebar", "spotlight": return 49
        case "return", "enter": return 36
        case "tab": return 48
        case "escape", "esc": return 53
        case "delete", "backspace": return 51
        default:
            if raw.count == 1, let c = raw.first { return letterKeyCode(c) }
            return nil
        }
    }

    /// Finds the single letter that follows a modifier word (e.g. "command + s",
    /// "command shift t"). Skips chained modifier words, and only accepts the
    /// token IMMEDIATELY after them — scanning further would latch onto stray
    /// articles ("…to open a file" must not become ⌘A). The old version took
    /// the first letter of the next word, so "Command+Option+N" parsed as ⌘O.
    private static func letterAfterModifier(in text: String) -> Character? {
        let modList = ["command", "cmd", "⌘", "control", "ctrl", "⌃",
                       "option", "opt", "⌥", "shift", "⇧", "alt"]
        let mods = Set(modList)
        outer: for mod in modList {
            guard let r = text.range(of: mod) else { continue }
            let tail = String(text[r.upperBound...])
            let tokens = tail.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            for token in tokens {
                if mods.contains(token) { continue }        // chained modifier
                if token.count == 1, let c = token.first, c.isLetter { return c }
                continue outer  // next word isn't a combo letter — try another modifier
            }
        }
        return nil
    }

    /// US-ANSI keycodes for letter keys.
    private static func letterKeyCode(_ ch: Character) -> CGKeyCode? {
        let map: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
            "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
            "n": 45, "m": 46
        ]
        return map[Character(ch.lowercased())]
    }

    /// Human-readable name for a combo, e.g. "⌘Space" or "⌃⌥Return".
    private func comboDisplayName(_ combo: (keyCode: CGKeyCode, flags: CGEventFlags)) -> String {
        var s = ""
        if combo.flags.contains(.maskControl) { s += "⌃" }
        if combo.flags.contains(.maskAlternate) { s += "⌥" }
        if combo.flags.contains(.maskShift) { s += "⇧" }
        if combo.flags.contains(.maskCommand) { s += "⌘" }
        let key: String
        switch combo.keyCode {
        case 49: key = "Space"
        case 36: key = "Return"
        case 48: key = "Tab"
        case 53: key = "Esc"
        case 51: key = "Delete"
        default:
            let names = Self.letterNames
            key = names[combo.keyCode] ?? "key"
        }
        return s + key
    }

    private static let letterNames: [CGKeyCode: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M"
    ]

    private func installKeyAdvanceMonitor(forStep stepIndex: Int, step: Step) {
        removeKeyAdvanceMonitor()
        keyAdvanceMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let chars = event.charactersIgnoringModifiers ?? ""
            Task { @MainActor in
                self?.handleKeyAdvance(code: code, chars: chars, stepIndex: stepIndex, step: step)
            }
        }
    }

    private func handleKeyAdvance(code: UInt16, chars: String, stepIndex: Int, step: Step) {
        guard isRunning, state == .showing, currentStepIndex == stepIndex else { return }

        // For a TYPE step, advance as soon as the user starts typing — the first
        // printable character (or Return/Tab) moves on so they can keep typing
        // while the next step appears.
        if step.action == .type {
            let isPrintable = chars.unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0)
                    || CharacterSet.punctuationCharacters.contains($0)
                    || CharacterSet.symbols.contains($0)
                    || $0 == " "
            }
            let returnOrTab: Set<UInt16> = [36, 76, 48]
            guard isPrintable || returnOrTab.contains(code) else { return }
            DebugLogger.log("ENGINE", "first keystroke on type step → advancing step \(stepIndex + 1)")
            advanceAfterKey(stepIndex: stepIndex)
            return
        }

        // For a KEY step, wait for the specific commit key.
        let commit: Set<UInt16>
        switch (step.key ?? "").lowercased() {
        case "tab": commit = [48]
        case "space": commit = [49]
        case "escape", "esc": commit = [53]
        case "delete", "backspace": commit = [51]
        default: commit = [36, 76] // Return and keypad Enter
        }
        guard commit.contains(code) else { return }
        advanceAfterKey(stepIndex: stepIndex)
    }

    private func advanceAfterKey(stepIndex: Int) {
        removeKeyAdvanceMonitor()
        OverlayWindowController.shared.hideDot()
        let next = stepIndex + 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nextStepDelayNanos())
            guard self.isRunning, self.currentStepIndex == stepIndex else { return }
            await self.executeStep(index: next)
        }
    }

    private func removeKeyAdvanceMonitor() {
        if let monitor = keyAdvanceMonitor {
            NSEvent.removeMonitor(monitor)
            keyAdvanceMonitor = nil
        }
        if let id = keyObserverId {
            HotkeyManager.shared.removeKeyObserver(id)
            keyObserverId = nil
        }
    }
}
