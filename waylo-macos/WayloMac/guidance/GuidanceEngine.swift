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
    case teach    // point + explain; the user clicks
    case assist   // planned steps; Waylo performs safe clicks itself
    case agent    // observe→act loop; Waylo does the whole task (AgentEngine)
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
    /// Teach (point, the user clicks & learns) vs assist (Waylo clicks) vs agent
    /// (Waylo does the whole task). Persisted across launches.
    /// DEFAULT IS TEACH: Waylo's mission is teaching people to do things
    /// themselves, so it points and guides while the USER clicks — but it still
    /// auto-handles the plumbing (launching apps) where a dot would be pointless.
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
    /// Target-app windows at the moment the user completed the last click.
    /// Diffed on the next step: a window that appeared (Trash window, dialog,
    /// preferences panel) is where the next target almost certainly lives.
    private var windowSnapshot: [AXUIElement] = []
    /// Frame of the newly-appeared window, used to narrow AX + OCR search.
    private var preferredWindowFrame: CGRect?
    /// Screen fingerprint at the moment of the last completed action, and
    /// whether the screen visibly changed after it. When an action had NO
    /// visible effect and the next step then can't be found, recovery is told
    /// so — it stops assuming the click worked.
    private var signatureBeforeAction: String?
    private var lastActionChangedScreen = true

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
        TrainingHarvest.shared.beginGuide(task: plan.task)
        currentStepIndex = 0
        isRunning = true
        installDebugHotkey()
        if planLocked { DebugLogger.log("ENGINE", "plan LOCKED (demo) — corrections relabel only, no replan") }

        // Collapse the panel to the notch pill — the guide lives in the notch now.
        NotchPanelController.expansion.expanded = false

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
        HelperButtonController.shared.hide()
        Speaker.shared.stop()
        currentTargetAX = nil
        windowSnapshot = []
        preferredWindowFrame = nil
        signatureBeforeAction = nil
        lastActionChangedScreen = true
        state = .idle
        statusMessage = ""
        currentInstruction = ""
        currentStepIndex = 0
        planLocked = false
    }

    // MARK: - New-window tracking

    /// Remember the app's windows right when a click lands (before whatever it
    /// opens has appeared), plus the screen fingerprint for the verification
    /// signal.
    private func snapshotWindows() {
        windowSnapshot = AccessibilityReader.shared.targetWindowList().map(\.element)
        signatureBeforeAction = AccessibilityReader.shared.targetScreenSignature()
    }

    /// Called at the start of the next step: any window not in the snapshot
    /// just opened — focus detection inside it.
    private func updatePreferredWindow() {
        preferredWindowFrame = nil
        guard !windowSnapshot.isEmpty else { return }
        let current = AccessibilityReader.shared.targetWindowList()
        let fresh = current.filter { c in !windowSnapshot.contains { CFEqual($0, c.element) } }
        if let new = fresh.first {
            preferredWindowFrame = new.frame
            DebugLogger.log("WINDOW", "new window appeared (\(new.subrole.isEmpty ? "?" : new.subrole) \(Int(new.frame.width))x\(Int(new.frame.height))) — focusing detection inside it")
        }
    }

    func stopGuidance() {
        isRunning = false
        state = .idle
        locateToken += 1
        OverlayWindowController.shared.hideDot()
        HelperButtonController.shared.hide()
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
        statusMessage = L10n.t("paused")
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
        HelperButtonController.shared.hide()
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

        // "Open <app>" / "click the Bin in the Dock" is a solved problem: the OS
        // launches it directly. Dock icons carry NO text, so vision is doing its
        // hardest work for something we can just ask macOS to do.
        if effective.action == .click, let launch = AppLauncher.target(for: effective) {
            await runLauncherStep(effective, launch: launch)
            return
        }

        switch effective.action {
        case .click:
            // A user-choice step ("click the photo you just took", "pick a
            // chat") has NO single correct target — only the user knows which
            // item they mean. Running the detector risks pointing at the wrong
            // thing (e.g. the colour layer grabbing the red camera button on
            // the "click your new photo" step). Skip detection entirely:
            // describe it and advance on any click.
            if isUserChoiceStep(effective) {
                presentUserChoiceStep(effective)
            } else {
                await locateAndShow(step: effective)
            }
        case .type, .key, .info:
            presentNonClickStep(effective)
        }
    }

    /// Present a user-choice step WITHOUT running detection: show the
    /// instruction, drop no dot (there is no single right target), and advance
    /// on any click. Keeps Waylo from confidently pointing at the wrong item.
    private func presentUserChoiceStep(_ step: Step) {
        locateToken += 1
        removeClickMonitor()
        OverlayWindowController.shared.hideDot()
        currentTargetAX = nil
        state = .showing
        statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click the one you want"
        // A short dwell so the click that COMPLETED the previous step doesn't
        // instantly satisfy this one.
        installAnyClickAdvance(forStep: currentStepIndex, bufferSeconds: 1.2)
    }

    // MARK: - Launcher steps (open an app / the Trash — no vision needed)

    /// Opening an app or the Trash is the "plumbing" of a task, not a skill worth
    /// teaching — and a Dock icon is textless, so pointing a dot at it is exactly
    /// the awkward, error-prone case. So in EVERY mode (teach included) we just
    /// open it via NSWorkspace and move straight to the first real in-app step,
    /// which teach mode then teaches. Seamless, and never a wrong Dock dot.
    private func runLauncherStep(_ step: Step, launch: AppLauncher.Target) async {
        locateToken += 1
        let token = locateToken
        removeClickMonitor()
        currentTargetAX = nil
        HelperButtonController.shared.hide()
        OverlayWindowController.shared.hideDot()
        state = .showing

        DebugLogger.log("LAUNCH", "auto-opening '\(launch.displayName)' (\(mode.rawValue) mode — no Dock dot)")
        let spoken = AppLauncher.open(launch)
        Speaker.shared.speak(spoken)
        statusMessage = spoken
        snapshotWindows()

        let idx = currentStepIndex
        Task { @MainActor in
            await ScreenCapturer.shared.settleAfterAction()
            guard self.isRunning, self.currentStepIndex == idx, token == self.locateToken else { return }
            await self.executeStep(index: idx + 1)
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
                self.snapshotWindows()
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
        statusMessage = L10n.t("finding")

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

        // Did the last click open a new window? If so, search inside it first.
        updatePreferredWindow()

        // Verification signal: did the last action visibly change anything?
        // (Coarse by design — a toggle changes nothing and that's fine; this
        // only matters when the next step ALSO can't be found.)
        if let before = signatureBeforeAction {
            let now = AccessibilityReader.shared.targetScreenSignature()
            lastActionChangedScreen = now != before
            DebugLogger.log("VERIFY", "screen \(lastActionChangedScreen ? "CHANGED" : "unchanged") since last action")
            signatureBeforeAction = nil
        } else {
            lastActionChangedScreen = true
        }

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
            anchorPosition: step.anchorPosition,
            preferRect: preferredWindowFrame
        )
        guard token == locateToken, isRunning else { return }

        // Retry ONCE after 400ms — the app may be mid-animation (a menu opening,
        // a window appearing) so the AX tree / screenshot are momentarily stale.
        // The retry is LOCAL-ONLY (AX + OCR): if the target became visible after
        // the animation, those fast layers catch it in ~0.5s. Re-running the
        // slow YOLO+Nova (≈13s each) a second time on a now-stable screen almost
        // never succeeds and used to DOUBLE the wait before the describe/recover
        // fallback. So a genuine vision miss goes straight to recovery.
        if resolution == nil {
            DebugLogger.log("ENGINE", "RETRY (local-only) after 400ms (step \(currentStepIndex + 1)) — layers missed")
            try? await Task.sleep(nanoseconds: 400_000_000)
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
                    localOnly: true,
                    targetType: step.targetType,
                    controlKind: step.controlKind,
                    anchorText: step.anchorText,
                    anchorPosition: step.anchorPosition,
                    preferRect: preferredWindowFrame
                )
                guard token == locateToken, isRunning else { return }
            }
        }

        if let resolution = resolution {
            // ALREADY DONE? If this step opens/shows/selects a toggle that is
            // already ON (e.g. Pages' Format panel is already open), clicking
            // it would turn it back OFF. Skip straight to the next step.
            if let el = resolution.axElement, stepIsAlreadySatisfied(step, element: el) {
                DebugLogger.log("ENGINE", "step \(currentStepIndex + 1) already satisfied (toggle on) — skipping without clicking")
                Speaker.shared.speak("That's already open, moving on.")
                let next = currentStepIndex + 1
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard token == locateToken, isRunning else { return }
                await executeStep(index: next)
                return
            }

            reportSuccess(step: step, resolution: resolution)
            applyUpdatedInstruction(resolution.updatedInstruction)

            // Several confident, distinct matches — never guess. Show numbered
            // badges on all of them and let the user click the right one.
            if !resolution.alternates.isEmpty {
                presentAmbiguity(step: step, primary: resolution.axPoint, alternates: resolution.alternates)
                return
            }

            // A USER-CHOICE step (pick which chat / which file / which contact):
            // don't point at one specific item — let the user choose any and
            // advance on their click. Detected from the description.
            if isUserChoiceStep(step) {
                currentTargetAX = resolution.axPoint
                presentTargetVisual(resolution)
                state = .showing
                statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click the one you want"
                installAnyClickAdvance(forStep: currentStepIndex, bufferSeconds: 2.0)
                return
            }

            // Assist mode: perform safe clicks ourselves (destructive steps
            // still fall back to point-and-confirm inside autoPerform).
            if mode == .assist && step.action == .click {
                await autoPerform(step: step, resolution: resolution, stepIndex: currentStepIndex, token: token)
                return
            }

            showTarget(resolution, step: step)
            return
        }

        // Before giving up, self-heal. RECOVERY runs FIRST: the most common
        // failure is a planner label that differs from the visible one (step
        // says "Empty Trash", the real button is "Empty") — /recover relabels
        // that in ~2s. The old order sent the user scrolling for ~18s even
        // when the element was already on screen under a different name.
        guard token == locateToken, isRunning else { return }
        // Recovery (attemptRecovery) already triggers scroll assist itself when
        // the /recover model says the element is genuinely off-screen (it
        // returns a scrollDirection). We do NOT scroll-assist as a blind
        // fallback just because a scroll area exists — the element is usually
        // on screen and simply unnamed, and a pointless scroll prompt is worse
        // than an honest description (user feedback: scroll must be necessary,
        // not a catch-all).
        if await attemptRecovery(step: step, capture: capture, token: token) { return }
        guard token == locateToken, isRunning else { return }
        // TEACH/ASSIST HYBRID: this step can't be outlined (every layer missed).
        // Before asking the user to hunt for it, let the AGENT do just this one
        // step through the AX tree — one cheap text-only model call, no
        // screenshots. Teaching stays the core; the agent fills the gaps so the
        // guide keeps flowing. Destructive steps are never auto-performed.
        if step.action == .click, !isDestructiveStep(step),
           await attemptAgentStep(step: step, token: token) { return }
        guard token == locateToken, isRunning else { return }
        describeTargetInstead(step: step)
    }

    /// Performs ONE unlocatable step via the agent decider (AX element list →
    /// single action). Returns true when the step visibly worked and the guide
    /// advanced. Cheap: text-only call, no vision.
    private func attemptAgentStep(step: Step, token: Int) async -> Bool {
        let snap = AgentSnapshot.capture()
        guard !snap.entries.isEmpty else { return false }

        statusMessage = "This one's hard to point at — doing it for you…"
        Speaker.shared.speak("This one is hard to point at, so I'll do it for you.")

        var context = ScreenContextBuilder.build()
        if !snap.menuTitles.isEmpty {
            context += "\nMenu bar (menu action + path): \(snap.menuTitles.joined(separator: ", "))"
        }
        let singleTask = "Do EXACTLY this one step of a guide, nothing else: \(step.instruction)"
        guard let action = try? await WayloAPIClient.shared.agentAct(
            task: singleTask, appName: snap.appName, context: context,
            elements: snap.payload, history: []),
            token == locateToken, isRunning else { return false }

        // Only safe, immediate actions — a single step never opens apps,
        // finishes tasks, or asks questions.
        let before = snap.fingerprint
        let executed: Bool
        switch action.act {
        case "press":
            guard let id = action.id, let info = snap.element(for: id),
                  !isDestructiveStep(step) else { return false }
            executed = AgentExecutor.press(info)
        case "menu":
            executed = AgentExecutor.menu(path: action.path ?? [])
        case "key":
            executed = AgentExecutor.key(combo: action.combo ?? "")
        default:
            return false
        }
        guard executed else { return false }

        try? await Task.sleep(nanoseconds: 900_000_000)
        guard token == locateToken, isRunning else { return false }
        let after = AgentSnapshot.capture().fingerprint
        guard after != before else {
            DebugLogger.log("ENGINE", "agent step fallback: no visible effect — describing instead")
            return false
        }

        DebugLogger.log("ENGINE", "agent step fallback DID the step (\(describeAgentAction(action))) — advancing")
        OverlayWindowController.shared.showBanner("Done — that one's handled. Next step…", autoDismissAfter: 4)
        snapshotWindows()
        let idx = currentStepIndex
        Task { @MainActor in
            await ScreenCapturer.shared.settleAfterAction()
            guard self.isRunning, self.currentStepIndex == idx else { return }
            await self.executeStep(index: idx + 1)
        }
        return true
    }

    private func describeAgentAction(_ a: WayloAPIClient.AgentAction) -> String {
        switch a.act {
        case "press": return "press #\(a.id ?? -1)"
        case "menu":  return "menu \((a.path ?? []).joined(separator: " > "))"
        case "key":   return "key \(a.combo ?? "?")"
        default:      return a.act
        }
    }

    /// Nothing could locate the target CONFIDENTLY. Rather than plant a dot on
    /// a guess — which sends the user to the wrong control and cascades through
    /// the rest of the guide — describe the target in words, name the region it
    /// lives in, and advance as soon as the user clicks anything. An honest
    /// "in the Text panel, look for the small colour wheel" beats a wrong dot.
    private func describeTargetInstead(step: Step) {
        OverlayWindowController.shared.hideDot()
        // MUST be .showing: the any-click advance monitor only fires in the
        // .showing state, so using .manual here (the old bug) meant the user's
        // clicks were ignored and the guide never advanced.
        state = .showing

        let what = [step.elementDescription, step.findDescription, step.instruction]
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? step.instruction
        let whereText = regionPhrase(step.screenRegion)
        let base = whereText.isEmpty
            ? "I can't point to it exactly. Find \(what) yourself"
            : "I can't point to it exactly. \(whereText), find \(what)"
        let spoken = "\(base). Click it, or press Control Option Command N when you've found it, and I'll continue."

        currentInstruction = spoken
        statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click it (or ⌃⌥⌘N) and I'll continue"
        OverlayWindowController.shared.showBanner(spoken)
        Speaker.shared.speak(spoken)
        DebugLogger.log("DESCRIBE", "not confident — describing instead of guessing: '\(what)'")
        // Advance when the user clicks the thing themselves…
        installAnyClickAdvance(forStep: currentStepIndex, bufferSeconds: 2.0)
        // …or when they press ⌃⌥⌘N to say "found it, continue".
        installManualAdvanceHotkey(forStep: currentStepIndex)
    }

    /// In describe mode, ⌃⌥⌘N means "I found it, move on" (as well as its
    /// normal re-detect role). Registered transiently for the current step.
    private func installManualAdvanceHotkey(forStep stepIndex: Int) {
        keyObserverId = HotkeyManager.shared.addKeyObserver(keyCode: 45, flags: HotkeyManager.cmdOptCtrl) { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isRunning, self.state == .showing,
                      self.currentStepIndex == stepIndex else { return }
                DebugLogger.log("DESCRIBE", "user pressed ⌃⌥⌘N — advancing from described step \(stepIndex + 1)")
                self.removeClickMonitor()
                self.removeKeyAdvanceMonitor()
                let next = stepIndex + 1
                await ScreenCapturer.shared.settleAfterAction()
                guard self.isRunning, self.currentStepIndex == stepIndex else { return }
                await self.executeStep(index: next)
            }
        }
    }

    /// True when the step wants to OPEN/SHOW/SELECT a toggle that is already on
    /// — clicking it again would undo it. Only for activate-intent steps; a
    /// "turn off"/"close"/"uncheck" step legitimately clicks an on toggle.
    private func stepIsAlreadySatisfied(_ step: Step, element: AXUIElement) -> Bool {
        guard AccessibilityReader.shared.isToggleOn(element) == true else { return false }
        let t = "\(step.instruction) \(step.elementDescription)".lowercased()
        let deactivate = ["turn off", "close", "hide", "uncheck", "deselect", "disable", "collapse"]
        if deactivate.contains(where: { t.contains($0) }) { return false }
        let activate = ["open", "show", "select", "click", "go to", "switch to", "enable", "turn on", "expand", "reveal"]
        return activate.contains { t.contains($0) }
    }

    /// Human phrasing for where a region is, used by the describe fallback.
    private func regionPhrase(_ region: ScreenRegion) -> String {
        switch region {
        case .menuBar:     return "In the menu bar at the very top"
        case .ribbon:      return "In the toolbar at the top of the window"
        case .sidebar:     return "In the panel on the side of the window"
        case .dialog:      return "In the box that just opened"
        case .statusBar:   return "At the bottom of the window"
        case .spreadsheet: return "In the main area of the window"
        case .fullScreen:  return ""
        }
    }

    // MARK: - Target presentation (dotted region highlight, dot fallback)

    /// Shows the located target and arms click-to-advance. When the resolving
    /// layer knows the element's bounds, a dotted region highlight is drawn
    /// around it (HeyClicky-style — a clickable AREA beats a bare point);
    /// otherwise the classic pulsing dot.
    private func showTarget(_ resolution: CoordinateResolver.Resolution, step: Step) {
        currentTargetAX = resolution.axPoint
        presentTargetVisual(resolution)
        state = .showing
        statusMessage = L10n.step(currentStepIndex + 1, steps.count) + L10n.t("click_highlight")
        installClickMonitor(target: resolution.axPoint, targetRect: highlightableFrame(resolution.targetFrame),
                            forStep: currentStepIndex, secondary: isSecondaryClickStep(step))
    }

    /// Draws the highlight box (when bounds are known and sane) or the dot.
    private func presentTargetVisual(_ resolution: CoordinateResolver.Resolution) {
        if let frame = highlightableFrame(resolution.targetFrame) {
            OverlayWindowController.shared.showHighlight(axRect: frame, caption: currentInstruction)
        } else {
            OverlayWindowController.shared.showDot(at: resolution.axPoint, caption: currentInstruction)
        }
    }

    /// A frame is highlightable when it looks like a CONTROL, not a container.
    /// Wide-but-short things (a browser address/search bar, a full-width text
    /// field) are legit controls and SHOULD get the outline — the old 480pt
    /// width cap wrongly demoted them to a bare dot. A panel/window is rejected
    /// by height (tall) or sheer area, not width alone.
    private func highlightableFrame(_ frame: CGRect?) -> CGRect? {
        guard let f = frame, f.width >= 8, f.height >= 8,
              f.width <= 900, f.height <= 160,
              f.width * f.height <= 90_000       // reject big panels (e.g. 700×300)
        else { return nil }
        return f
    }

    // MARK: - Assist mode ("do it with me")

    /// Performs the click for the user: AXPress on the resolved element when
    /// available (works for menus/buttons without moving the mouse), else a
    /// synthetic click at the resolved point. Destructive steps are never
    /// auto-clicked — they show the dot and wait for the user's own click.
    private func autoPerform(step: Step, resolution: CoordinateResolver.Resolution, stepIndex: Int, token: Int) async {
        currentTargetAX = resolution.axPoint
        presentTargetVisual(resolution)
        state = .showing

        if isDestructiveStep(step) {
            statusMessage = "Step \(stepIndex + 1) of \(steps.count) — this one changes things; click it yourself to confirm"
            Speaker.shared.speak(L10n.t("spoken_destructive"))
            DebugLogger.log("ASSIST", "destructive step \(stepIndex + 1) — falling back to point-and-confirm")
            installClickMonitor(target: resolution.axPoint, targetRect: highlightableFrame(resolution.targetFrame),
                                forStep: stepIndex, secondary: isSecondaryClickStep(step))
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
        // NOTE: assist mode deliberately does NOT mark the example verified —
        // Waylo clicked its own prediction, so a "success" here would just be
        // the model agreeing with itself. Only a human click is ground truth.
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
    /// True when the step asks the user to pick among equivalent items only
    /// they can choose (which chat/contact/file/conversation). Waylo can't
    /// know which one — point loosely and advance on any click. The planner
    /// may also mark these `advanceOnAnyClick`; this catches the ones it misses.
    private func isUserChoiceStep(_ step: Step) -> Bool {
        if step.advanceOnAnyClick { return true }
        let t = "\(step.instruction) \(step.elementDescription)".lowercased()
        let chooseWords = ["which chat", "the chat", "a chat", "choose a", "select the chat",
                           "which contact", "the contact", "which conversation", "the person",
                           "which file", "the file you", "which photo", "the photo you",
                           "the photo you took", "photo that just appeared", "just appeared",
                           "you just took", "thumbnail", "photo strip", "in the strip",
                           "photo you captured", "the picture you"]
        // Only when the target has no exact label of its own (a specific button
        // like "Send" is NOT a free choice).
        let noFixedLabel = step.targetLabel.trimmingCharacters(in: .whitespaces).isEmpty
        return noFixedLabel && chooseWords.contains { t.contains($0) }
    }

    private func isDestructiveStep(_ step: Step) -> Bool {
        // Gate on WHAT IS CLICKED (targetLabel / element), NOT the instruction:
        // the instruction narrates the goal and often names the destructive
        // verb on a perfectly safe intermediate step ("click the chat you want
        // to SEND the photo to" clicks a chat, sends nothing). Judging the
        // whole sentence wrongly gated every step of a "send…" task.
        let t = "\(step.targetLabel) \(step.elementDescription)".lowercased()
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

        // Every-layer miss: report it (with the screenshot recovery is about
        // to use anyway) so the failure set is analyzable and trainable.
        WayloAPIClient.shared.reportDetectionEvent(
            source: "auto_miss",
            task: taskName,
            stepNumber: step.index,
            findDescription: step.findDescription,
            elementType: step.controlKind,
            screenRegion: step.screenRegion.rawValue,
            appName: TargetAppTracker.shared.targetName,
            layerReached: -1,
            screenshotBase64: base64,
            screenWidth: Int(size.width),
            screenHeight: Int(size.height)
        )

        // Verification signal → recovery: when the previous action visibly did
        // nothing AND we now can't find this step's target, the model should
        // not assume the click worked (the wrong thing may have been pressed,
        // or the press was a silent no-op).
        var recoveryMessage = userMessage
        if recoveryMessage.isEmpty && !lastActionChangedScreen && currentStepIndex > 0 {
            recoveryMessage = "Note: the previous step's click appears to have had no visible effect — the screen looks the same as before it."
            DebugLogger.log("VERIFY", "recovery informed: previous action had no visible effect")
        }

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
                userMessage: recoveryMessage
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
                statusMessage = L10n.t("manual_fallback")
                Speaker.shared.speak(L10n.t("spoken_not_found"))
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
                showTarget(retry, step: step)
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
                showTarget(resolution, step: step)
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
        HelperButtonController.shared.hide()
        statusMessage = L10n.t("task_complete")
        currentInstruction = "All done! You've completed the task."
        Speaker.shared.speak(L10n.t("spoken_done"))
        removeDebugHotkey()
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        isRunning = false

        // Record the finished guide so the user can rate it (✓ caches it as
        // correct, ✗ forgets it) from the panel's history list.
        if !taskName.isEmpty, !steps.isEmpty {
            TaskHistory.shared.record(task: taskName, steps: steps)
        }

        // Reopen the panel so the completion banner + rating are actually
        // visible — with isRunning false and the panel collapsed, it would
        // otherwise hide entirely and the ✓/✗ feedback loop would be lost.
        NotchPanelController.expansion.expanded = true
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
            Speaker.shared.speak(L10n.t("spoken_going_back"))
            previousStep(); return
        }
        if lower.contains("skip") || lower.contains("next step") || lower == "next" {
            Speaker.shared.speak(L10n.t("spoken_skipping"))
            nextStep(); return
        }
        if lower.contains("repeat") || lower.contains("say again") || lower.contains("show me again") {
            Speaker.shared.speak(L10n.t("spoken_again"))
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
    private func installClickMonitor(target: CGPoint, targetRect: CGRect? = nil, forStep stepIndex: Int, secondary: Bool) {
        removeClickMonitor()
        clickObserverId = HotkeyManager.shared.addClickObserver { [weak self] axPoint, isRight in
            Task { @MainActor in
                self?.handleGlobalClick(atAX: axPoint, target: target, targetRect: targetRect,
                                        stepIndex: stepIndex, secondary: secondary, isRight: isRight)
            }
        }
    }

    private func handleGlobalClick(atAX clickAX: CGPoint, target: CGPoint, targetRect: CGRect?,
                                   stepIndex: Int, secondary: Bool, isRight: Bool) {
        guard isRunning, state == .showing, currentStepIndex == stepIndex else { return }
        guard !clickIsOnWayloUI(clickAX) else { return }

        let dx = clickAX.x - target.x
        let dy = clickAX.y - target.y
        let dist = (dx * dx + dy * dy).squareRoot()
        // Always log while showing — makes "clicked but nothing happened"
        // diagnosable from the debug log (distance vs tolerance).
        DebugLogger.log("CLICK", String(format: "%@ at (%.0f,%.0f) target=(%.0f,%.0f) dist=%.0f tol=%.0f",
            isRight ? "right" : "left", clickAX.x, clickAX.y, target.x, target.y, dist, clickToleranceAX))

        // A click anywhere inside the highlighted REGION (when known) counts —
        // that's the point of the region box — else within the classic radius
        // of the dot. This is the PRIMARY path for every step, left-click
        // included: the previous code required a right-click for "secondary"
        // steps and so a normal left-click on the dot never advanced them.
        let insideRect = targetRect.map { $0.insetBy(dx: -12, dy: -12).contains(clickAX) } ?? false
        let inTarget = insideRect || dist <= clickToleranceAX
        if inTarget {
            // The user clicked where we pointed → any staged training example
            // for this step was a correct prediction.
            TrainingHarvest.shared.markVerified(stepIndex: stepIndex)
            advanceAfterClick(stepIndex: stepIndex)
            return
        }

        // Right-click steps ALSO complete on a right-click anywhere (the user
        // opens a context menu away from the dot) — an extra path, not the only one.
        if secondary && isRight {
            DebugLogger.log("ENGINE", "right-click detected → advancing step \(stepIndex + 1)")
            advanceAfterClick(stepIndex: stepIndex)
            return
        }

        // OFF-TARGET click: maybe the USER knows better than the dot. If the
        // screen visibly changes right after their click, their element was
        // the real target — learn it and move on.
        if !isRight {
            watchOffTargetClick(at: clickAX, stepIndex: stepIndex)
        }
    }

    // MARK: - Detection analytics (fire-and-forget, no screenshots on success)

    /// Reports which layer resolved a step — two weeks of this shows exactly
    /// where accuracy is won and lost.
    private func reportSuccess(step: Step, resolution: CoordinateResolver.Resolution) {
        let layerName = DebugState.shared.layerResolved
        var box: [String: Any] = ["x": Int(resolution.axPoint.x), "y": Int(resolution.axPoint.y)]
        if let f = resolution.targetFrame {
            box["bounds"] = ["x": Int(f.minX), "y": Int(f.minY), "w": Int(f.width), "h": Int(f.height)]
        }
        box["layer"] = layerName
        WayloAPIClient.shared.reportDetectionEvent(
            source: "auto_success",
            task: taskName,
            stepNumber: step.index,
            findDescription: step.findDescription,
            elementType: step.controlKind,
            screenRegion: step.screenRegion.rawValue,
            appName: TargetAppTracker.shared.targetName,
            layerReached: Self.layerIndex(layerName),
            chosenBox: box
        )
    }

    /// "L0 AX" → 0, "OCR" → 1, "cache→L0 AX" → 2, "L2.5 …" → 3, "L3 …" → 4.
    private static func layerIndex(_ name: String) -> Int {
        if name.contains("cache") { return 2 }
        if name.contains("L0") { return 0 }
        if name.contains("OCR") { return 1 }
        if name.contains("L2.5") { return 3 }
        if name.contains("L3") || name.contains("Nova") { return 4 }
        return -1
    }

    // MARK: - Learning from the user's clicks (self-supervised correction)

    /// The user clicked somewhere OTHER than where Waylo pointed while a dot/
    /// highlight was showing. If the screen visibly changes within ~1.3s, the
    /// click did something — treat the clicked element as ground truth:
    /// cache its label for this step, report a user_correction event, and
    /// advance (the user just did the step their own way).
    private func watchOffTargetClick(at clickAX: CGPoint, stepIndex: Int) {
        let token = locateToken
        let before = AccessibilityReader.shared.targetScreenSignature()
        DebugLogger.log("CORRECT", "off-target click at (\(Int(clickAX.x)),\(Int(clickAX.y))) — watching for effect")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard self.isRunning, self.state == .showing,
                  self.currentStepIndex == stepIndex, token == self.locateToken,
                  stepIndex < self.steps.count else { return }
            let after = AccessibilityReader.shared.targetScreenSignature()
            guard after != before else { return } // click did nothing visible — ignore

            let step = self.steps[stepIndex]
            let appName = TargetAppTracker.shared.targetName
            let element = AccessibilityReader.shared.elementAt(axPoint: clickAX)
            let label = element.map { $0.title.isEmpty ? $0.description : $0.title } ?? ""
            DebugLogger.log("CORRECT", "user's click WORKED — learning '\(label)' as the real target for step \(stepIndex + 1)")

            // Our predicted box was WRONG — never train on it. (The corrected
            // target is reported below as ground truth instead.)
            TrainingHarvest.shared.discard(stepIndex: stepIndex)

            // 1. Label cache: next run of this step resolves to the user's
            //    element via AX and skips vision entirely.
            if !label.isEmpty, !step.labelCacheKey.isEmpty {
                WayloAPIClient.shared.storeLabel(appName: appName,
                                                 stepDescription: step.labelCacheKey,
                                                 axLabel: label)
            }
            // 2. Analytics: a user_correction event carrying the true target.
            var corrected: [String: Any] = ["x": Int(clickAX.x), "y": Int(clickAX.y)]
            if let el = element {
                corrected["text"] = label
                corrected["bounds"] = ["x": Int(el.frame.minX), "y": Int(el.frame.minY),
                                       "w": Int(el.frame.width), "h": Int(el.frame.height)]
            }
            WayloAPIClient.shared.reportDetectionEvent(
                source: "user_correction",
                task: self.taskName,
                stepNumber: stepIndex + 1,
                findDescription: step.findDescription,
                elementType: step.controlKind,
                screenRegion: step.screenRegion.rawValue,
                appName: appName,
                correctedTarget: corrected
            )
            // 3. The user completed the step their own way — advance.
            self.currentTargetAX = clickAX
            self.advanceAfterClick(stepIndex: stepIndex)
        }
    }

    /// Shared "click landed → move on" handler. Shows an immediate spinner at
    /// the target so the user KNOWS the click registered, then advances after
    /// a short settle (lets the next screen/dialog open before we screenshot).
    private func advanceAfterClick(stepIndex: Int) {
        removeClickMonitor()
        // Snapshot the app's windows NOW — anything that appears between this
        // click and the next locate is "the window that just opened".
        snapshotWindows()
        if let target = currentTargetAX {
            OverlayWindowController.shared.showLoading(at: target)
        } else {
            OverlayWindowController.shared.hideDot()
        }
        let next = stepIndex + 1
        Task { @MainActor in
            // Settle until the screen stops changing (animations/window opens)
            // instead of a fixed delay — faster when quick, safer when slow.
            await ScreenCapturer.shared.settleAfterAction()
            guard self.isRunning, self.currentStepIndex == stepIndex else { return }
            await self.executeStep(index: next)
        }
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
        // Number after a modifier — e.g. screenshot shortcuts ⌘⇧3 / ⌘⇧4 / ⌘⇧5.
        if !flags.isEmpty, let code = Self.numberKeyCode(in: text) { return (code, flags) }
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

    /// Finds a digit (0–9) mentioned in a shortcut and returns its US-ANSI
    /// keycode — for screenshot combos like ⌘⇧3, ⌘⇧4, ⌘⇧5.
    private static func numberKeyCode(in text: String) -> CGKeyCode? {
        // US-ANSI keycodes: 1..9,0 → 18,19,20,21,23,22,26,28,25,29.
        let map: [Character: CGKeyCode] = [
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
            "6": 22, "7": 26, "8": 28, "9": 25, "0": 29
        ]
        // Prefer a digit that follows a modifier word/symbol ("shift 4", "⌘⇧3").
        if let letter = letterAfterModifier(in: text), let c = map[letter] { return c }
        for ch in text where map[ch] != nil { return map[ch] }
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
        // A keypress (Return in a dialog, ⌘N…) can open a window too — snapshot
        // so the next step can detect it, same as the click path.
        snapshotWindows()
        OverlayWindowController.shared.hideDot()
        let next = stepIndex + 1
        Task { @MainActor in
            await ScreenCapturer.shared.settleAfterAction()
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
