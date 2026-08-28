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
    case teach     // point + explain; the user clicks
    case assist    // planned steps; Waylo performs safe clicks itself
    case agent     // observe→act loop; Waylo does the whole task (AgentEngine)
    case liveAgent // teach-style pointing, but each step comes LIVE from the Genkit cloud agent
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
    private var planAppName = ""   // the plan's target app, so a learned plan can auto-open it

    // HACKATHON (All Things Agentic): live-agent mode. Steps are fetched ONE AT A
    // TIME from the Genkit cloud agent (/agent/next) instead of a whole plan up
    // front; everything else (app-open, notch, dot, click-advance, voice) is the
    // same teach machinery. The running conversation accumulates in agentHistory.
    private var liveAgentActive = false
    private var liveAgentGoal = ""
    private var agentHistory: [WayloAgentClient.HistoryItem] = []
    private var agentAnswers: [WayloAgentClient.Answer] = []
    private var lastAgentInstruction: String? = nil     // the step the user is acting on now
    private var pendingClarify: WayloAgentClient.Question? = nil
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
    /// The screenshot used to locate the CURRENT step, kept so that when the
    /// user clicks the real icon (correcting us) we can crop its pixels from the
    /// BEFORE image — the icon is often gone from the after-screen (a deleted
    /// email's trash icon) — and remember them (IconMemory) for free next time.
    private var lastStepCapture: ScreenCapturer.Capture?
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
        planAppName = plan.app
        planLocked = plan.demo
        TrainingHarvest.shared.beginGuide(task: plan.task)
        currentStepIndex = 0
        isRunning = true
        installDebugHotkey()
        if planLocked { DebugLogger.log("ENGINE", "plan LOCKED (demo) — corrections relabel only, no replan") }

        // Collapse the panel to the notch pill — the guide lives in the notch now.
        NotchPanelController.expansion.expanded = false

        // GUARANTEE the plan's app is frontmost before step 1. The planner
        // sometimes omits the "open the app" step (it assumed WhatsApp was up
        // while the user sat in another app) — detection then runs against the
        // WRONG app's screen and points at whatever matched there. Deterministic
        // client-side guard: resolve the app, open/focus it, settle, then start.
        let planApp = plan.app.trimmingCharacters(in: .whitespaces)
        // Waylo OPENS the target app itself (native apps are a solved problem),
        // so skip any leading "open the app" steps the planner emitted — the
        // Spotlight dance (⌘Space → type its name → Return) or a Dock click.
        // Without this, "take a photo in Photo Booth" opened Photo Booth AND
        // then instructed the user to open it via Spotlight.
        let startIdx = firstInAppStepIndex(appName: planApp)
        if startIdx > 0 { DebugLogger.log("ENGINE", "skipping \(startIdx) leading 'open \(planApp)' step(s) — Waylo opens the app itself") }

        // Open the app when it's NOT frontmost, OR when it IS frontmost but has
        // NO window — a document app (Pages/Preview/…) left running with its window
        // closed needs a fresh window (the template chooser) before "New Document"
        // etc. exist. Without the no-window check, the guide went straight to step 1
        // and failed because there was nothing on screen to point at.
        let appIsFrontmost = TargetAppTracker.shared.targetName.caseInsensitiveCompare(planApp) == .orderedSame
        let appHasWindow = AccessibilityReader.shared.targetFocusedWindowFrame() != nil
        if !planApp.isEmpty, (!appIsFrontmost || !appHasWindow),
           let url = AppLauncher.resolveApp(named: planApp) {
            let why = !appIsFrontmost ? "not frontmost (\(TargetAppTracker.shared.targetName))" : "frontmost but has no window"
            DebugLogger.log("ENGINE", "plan app '\(planApp)' \(why) — opening it first")
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            Task {
                await ScreenCapturer.shared.settleAfterAction()
                guard self.isRunning else { return }
                await self.executeStep(index: startIdx)
            }
            return
        }

        Task { await executeStep(index: startIdx) }
    }

    /// The index of the first step that ACTS INSIDE the app, skipping any
    /// leading steps that merely OPEN the target app — Waylo opens it itself.
    /// Recognises the Spotlight open-dance (⌘Space, typing the app's name, the
    /// Return that launches it) and a Dock/"open <app>" launch. Conservative:
    /// stops at the first real in-app action and never skips the whole plan.
    private func firstInAppStepIndex(appName: String) -> Int {
        let app = appName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !app.isEmpty else { return 0 }
        var i = 0
        var inOpenDance = false
        while i < steps.count - 1 {          // never skip the final step
            let s = steps[i]
            let text = "\(s.instruction) \(s.elementDescription) \(s.targetLabel)".lowercased()
            let key = (s.key ?? "").lowercased()
            let isSpotlight = text.contains("spotlight")
                || (s.action == .key && key.contains("space"))
            let opensApp = AppLauncher.target(for: s) != nil
                || (text.contains("open") && text.contains(app))
            // Typing the app's name / pressing Return only count as the open
            // dance when we're ALREADY launching (after Spotlight/Dock), so a
            // legitimate leading type or key step is never mistaken for it.
            let typesAppName = inOpenDance && s.action == .type && text.contains(app)
            let launchReturn = inOpenDance && s.action == .key && key.contains("return")
            if isSpotlight || opensApp {
                inOpenDance = true; i += 1; continue
            }
            if typesAppName || launchReturn { i += 1; continue }
            break
        }
        return i
    }

    /// Tears down all transient state from any prior run (monitors, dot, timers,
    /// target, tokens) and returns the engine to idle. Shared by stop + start.
    private func resetForNewRun() {
        locateToken += 1
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        removeDebugHotkey()
        stagedStepLabels.removeAll()   // stale labels must never leak into a new run's ✓
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
        liveAgentActive = false
        pendingClarify = nil
        lastAgentInstruction = nil
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
            // Live-agent: ran out of pre-fetched steps → ask the cloud agent for
            // the next one (it may also say the task is done). Otherwise finish.
            if liveAgentActive { await fetchNextAgentStep(); return }
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

        // URL-GATED navigation: don't point at anything. The user was just told
        // how to get there (type it, use a bookmark, whatever); we simply WATCH
        // the browser URL and advance the moment it matches. Robust to how they
        // navigate — no brittle address-bar → type → Return sequence to mis-point.
        if !step.awaitURL.isEmpty {
            beginURLWait(step: step, index: index)
            return
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

    /// URL-GATED navigation step: no dot. Show the instruction, then poll the
    /// browser URL and advance the instant it matches the target domain — however
    /// the user got there (typing, bookmark, history, autocomplete). This is far
    /// more robust than pointing at the address bar and waiting for a Return.
    private func beginURLWait(step: Step, index: Int) {
        locateToken += 1
        let token = locateToken
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        currentTargetAX = nil
        state = .showing
        OverlayWindowController.shared.hideDot()
        OverlayWindowController.shared.showBanner(step.instruction)
        let target = Self.normalizeURLMatch(step.awaitURL)
        statusMessage = "Step \(index + 1) of \(steps.count) — I'll continue once you're on \(target)"
        DebugLogger.log("ENGINE", "URL-wait step \(index + 1): watching for URL to reach '\(target)'")
        // ⌃⌥⌘N lets the user skip ahead if they're already there / stuck.
        installManualAdvanceHotkey(forStep: index)
        Task { @MainActor in
            // Poll (local AX read of the address bar — free) until the URL matches.
            let deadline = Date().addingTimeInterval(180)
            while isRunning, currentStepIndex == index, token == locateToken, Date() < deadline {
                if Self.currentURLMatches(target) {
                    DebugLogger.log("ENGINE", "URL reached '\(target)' — advancing to step \(index + 2)")
                    await ScreenCapturer.shared.settleAfterAction()
                    guard isRunning, currentStepIndex == index, token == locateToken else { return }
                    await executeStep(index: index + 1)
                    return
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    /// Normalize a target URL to a bare host+path for matching ("https://www.
    /// leetcode.com/" → "leetcode.com").
    static func normalizeURLMatch(_ s: String) -> String {
        var t = s.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        while t.hasSuffix("/") { t = String(t.dropLast()) }
        return t
    }

    /// True when the frontmost browser's current URL is on the target domain.
    /// Matches on the HOST (not a raw substring) so a search query that happens to
    /// contain the domain doesn't false-trigger before the user actually gets there.
    static func currentURLMatches(_ target: String) -> Bool {
        guard !target.isEmpty, let urlStr = AccessibilityReader.shared.targetWebURL() else { return false }
        let targetHost = target.split(separator: "/").first.map(String.init) ?? target
        if let comps = URLComponents(string: urlStr), let host = comps.host?.lowercased() {
            let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if h == targetHost || h.hasSuffix("." + targetHost) { return true }
        }
        // Fallback for odd URL strings: substring on the host portion only.
        return urlStr.lowercased().contains(targetHost)
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

    /// The "never wrong, always learning" safety net. When EVERY layer misses we
    /// describe the target in words and ask the user to click it. That click is
    /// ground truth — so unlike `installAnyClickAdvance` (which just advances),
    /// this LEARNS from it: caches the clicked control's label, remembers the icon
    /// pixels + location, and uploads it to the fleet dataset. Next time (for this
    /// user AND everyone) Waylo points at it exactly. A total miss becomes a
    /// permanent lesson — the same self-improving loop as a correction, but for
    /// the case where we had nothing at all. Advances on any click regardless, so
    /// the user is never stuck; only learns when the click stayed in the app and
    /// landed on a real element.
    private func installDescribeClickAdvance(forStep stepIndex: Int, bufferSeconds: Double) {
        removeClickMonitor()
        let appBefore = TargetAppTracker.shared.targetName
        clickObserverId = HotkeyManager.shared.addClickObserver { [weak self] axPoint, _ in
            Task { @MainActor in
                guard let self = self, self.isRunning, self.state == .showing,
                      self.currentStepIndex == stepIndex,
                      !self.clickIsOnWayloUI(axPoint) else { return }
                self.removeClickMonitor()

                // Learn ONLY when the click stayed in the target app (a click into
                // another app / the desktop is not the target — don't cache junk).
                if TargetAppTracker.shared.targetName == appBefore, stepIndex < self.steps.count {
                    let step = self.steps[stepIndex]
                    let appName = TargetAppTracker.shared.targetName
                    let element = AccessibilityReader.shared.elementAt(axPoint: axPoint)
                    let clickedLabel = element.map { $0.title.isEmpty ? $0.description : $0.title } ?? ""
                    // HARVEST GUARD: cache the clicked control's label ONLY if it's
                    // a real, control-like label; else fall back to the planner's
                    // accessibleName (already clean). Either lets a future run
                    // resolve via deep AX. Never cache a text-blob the user hit.
                    let learned = Self.harvestableLabel(from: element) ?? step.accessibleName
                    DebugLogger.log("DESCRIBE", "user clicked the target at (\(Int(axPoint.x)),\(Int(axPoint.y))) — learning '\(learned.isEmpty ? "(pixels only)" : learned)' for next time")
                    if !learned.isEmpty, !step.labelCacheKey.isEmpty {
                        WayloAPIClient.shared.storeLabel(appName: appName,
                                                         stepDescription: step.labelCacheKey,
                                                         axLabel: learned)
                    }
                    // Textless icon → remember its PIXELS + LOCATION + fleet upload.
                    if step.targetType == .icon || step.targetLabel.isEmpty {
                        self.learnIconPixels(at: axPoint, step: step, element: element)
                    }
                    var corrected: [String: Any] = ["x": Int(axPoint.x), "y": Int(axPoint.y)]
                    if let el = element {
                        corrected["text"] = clickedLabel
                        corrected["bounds"] = ["x": Int(el.frame.minX), "y": Int(el.frame.minY),
                                               "w": Int(el.frame.width), "h": Int(el.frame.height)]
                    }
                    WayloAPIClient.shared.reportDetectionEvent(
                        source: "user_describe_click", task: self.taskName,
                        stepNumber: stepIndex + 1, findDescription: step.findDescription,
                        elementType: step.controlKind, screenRegion: step.screenRegion.rawValue,
                        appName: appName, correctedTarget: corrected)
                }

                DebugLogger.log("ENGINE", "describe: click sensed → advancing step \(stepIndex + 1) after \(bufferSeconds)s buffer")
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
        lastStepCapture = capture   // BEFORE image, for learning icon pixels from a correcting click
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
            accessibleName: step.accessibleName,
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
                lastStepCapture = capture
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
                    accessibleName: step.accessibleName,
                    preferRect: preferredWindowFrame
                )
                guard token == locateToken, isRunning else { return }
            }
        }

        if let resolution = resolution {
            // APPROXIMATE (region) result: we couldn't pin the exact icon but we
            // know the toolbar/panel it's in. Highlight that whole area and speak
            // the locator hint — coarsely-right + descriptive, never a wrong dot.
            if resolution.approximate {
                // If the hint says the element is OFF-SCREEN ("scroll down…") and the
                // app can scroll, run SCROLL ASSIST — a bouncing arrow that polls as
                // the user scrolls and auto-advances the moment the item appears —
                // instead of a static describe box the user has to decode. Fixes the
                // System Settings sidebar item below the fold ("Touch ID & Password").
                let hint = resolution.regionHint.lowercased()
                if hint.contains("scroll"), AccessibilityReader.shared.targetHasScrollArea() {
                    let dir = hint.contains("scroll up") || hint.contains("upward") ? "up" : "down"
                    DebugLogger.log("ENGINE", "approximate hint says scroll → scroll assist (\(dir)) for '\(step.targetLabel)'")
                    let found = await beginScrollAssist(step: step, token: token, direction: dir,
                                                        instruction: resolution.regionHint)
                    guard token == locateToken, isRunning else { return }
                    if found { return }
                    // Scroll assist timed out — fall back to the static describe box.
                }
                presentApproximateRegion(resolution, step: step)
                return
            }

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
            // badges on all of them and let the user click the right one (or
            // auto-resolve if the fleet already picked this step before).
            if !resolution.alternates.isEmpty {
                await PickMemory.shared.prefetch(app: TargetAppTracker.shared.targetName, stepKey: step.labelCacheKey)
                guard token == locateToken, isRunning else { return }
                await presentAmbiguity(step: step, primary: resolution.axPoint, alternates: resolution.alternates)
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
        if step.action == .click, !isDestructiveStep(step) {
            // C2: one cheap text-only agent call through the AX tree.
            if await attemptAgentStep(step: step, token: token) { return }
            guard token == locateToken, isRunning else { return }
            // C3 — LAST LAYER: Gemini computer-use on the raw pixels. The most
            // expensive call in the stack, which is exactly why it sits at the
            // very bottom: it only ever runs when every free/cheap layer AND
            // the AX agent have failed, and it means a guide never dead-ends.
            if await attemptComputerStep(step: step, token: token) { return }
            guard token == locateToken, isRunning else { return }
        }
        describeTargetInstead(step: step)
    }

    /// C3: performs ONE unlocatable step via Gemini computer-use (screenshot →
    /// grid-coordinate click). Verified by screen change before advancing.
    private func attemptComputerStep(step: Step, token: Int) async -> Bool {
        guard ScreenRecordingPermission.isGranted,
              let cap = await ScreenCapturer.shared.captureActiveScreen(),
              let (b64, _) = ScreenCapturer.compressedJPEGBase64(cap.image, maxWidth: 1280),
              token == locateToken, isRunning else { return false }

        statusMessage = "Using my eyes for this one…"
        Speaker.shared.speak("Still tricky — let me use my eyes and do it for you.")

        let before = AgentSnapshot.capture().fingerprint
        guard let action = try? await WayloAPIClient.shared.agentActComputer(
            task: "Do EXACTLY this one step of a guide, nothing else: \(step.instruction)",
            appName: TargetAppTracker.shared.targetName,
            imageBase64: b64, history: []),
            token == locateToken, isRunning else { return false }

        // A single step is only ever an immediate action — never done/ask_user.
        guard ["press_at", "type_at", "key", "menu"].contains(action.act) else {
            DebugLogger.log("ENGINE", "computer step returned '\(action.act)' — not actionable, describing instead")
            return false
        }
        guard AgentExecutor.computerAction(action, on: cap.screen) else { return false }

        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard token == locateToken, isRunning else { return false }
        guard AgentSnapshot.capture().fingerprint != before else {
            DebugLogger.log("ENGINE", "computer step: no visible effect — describing instead")
            return false
        }

        DebugLogger.log("ENGINE", "computer step DID it (\(action.act)) — advancing")
        // HARVEST: hit-test the AX element at the clicked point and cache its
        // label for this step — the NEXT run resolves via free AX (layer 1)
        // and never reaches this expensive layer again.
        if action.act == "press_at", let gx = action.x, let gy = action.y {
            let axTop = ScreenCoordinates.primaryHeight - cap.screen.frame.maxY
            let p = CGPoint(x: cap.screen.frame.minX + CGFloat(gx) / 1000.0 * cap.screen.frame.width,
                            y: axTop + CGFloat(gy) / 1000.0 * cap.screen.frame.height)
            if let el = AccessibilityReader.shared.elementAt(axPoint: p) {
                let label = el.title.isEmpty ? el.description : el.title
                let appName = TargetAppTracker.shared.targetName
                if !label.isEmpty, !appName.isEmpty, !step.labelCacheKey.isEmpty {
                    WayloAPIClient.shared.storeLabel(appName: appName,
                                                     stepDescription: step.labelCacheKey,
                                                     axLabel: label)
                    DebugLogger.log("ENGINE", "computer step harvested label '\(label)' → next run is free")
                }
            }
        }
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
        // Advance when the user clicks the thing themselves — AND learn from that
        // click so next time (for everyone) Waylo points at it exactly.
        installDescribeClickAdvance(forStep: currentStepIndex, bufferSeconds: 2.0)
        // …or when they press ⌃⌥⌘N to say "found it, continue".
        installManualAdvanceHotkey(forStep: currentStepIndex)
    }

    /// APPROXIMATE result: we know the toolbar/panel but not the exact icon.
    /// Highlight the whole containing area (a big box we're confident about) and
    /// speak Gemini's locator hint, so the user's eye finds the icon and their
    /// click inside the area advances. Coarsely-right + descriptive beats a
    /// confident wrong dot — the goal is to TEACH, and we can't be wrong.
    private func presentApproximateRegion(_ resolution: CoordinateResolver.Resolution, step: Step) {
        currentTargetAX = resolution.axPoint
        state = .showing

        let what = [step.elementDescription, step.findDescription, step.instruction]
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? step.instruction
        let locator = resolution.regionHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = locator.isEmpty
            ? "Look in the highlighted area for \(what), and click it — I'll continue."
            : "\(locator). It's in the highlighted area — click it and I'll continue."

        currentInstruction = spoken
        statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click it in the highlighted area"

        // Highlight the CONTAINING box directly — bypasses highlightableFrame's
        // small-control size cap, because a toolbar/panel is legitimately large.
        if let frame = resolution.targetFrame {
            OverlayWindowController.shared.showHighlight(axRect: frame, caption: spoken)
        } else {
            OverlayWindowController.shared.showDot(at: resolution.axPoint, caption: spoken)
        }
        Speaker.shared.speak(spoken)
        DebugLogger.log("DESCRIBE", "approximate region — highlighting group + hint: '\(locator.isEmpty ? what : locator)'")

        // A click anywhere INSIDE the highlighted area advances (that's the whole
        // point of the region), or ⌃⌥⌘N to say "found it".
        installClickMonitor(target: resolution.axPoint, targetRect: resolution.targetFrame,
                            forStep: currentStepIndex, secondary: false)
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
    private func presentAmbiguity(step: Step, primary: CGPoint, alternates: [CGPoint]) async {
        let all = [primary] + alternates
        state = .showing

        // LEARNED PICK: if the user already chose among these look-alikes on a
        // previous run, don't ask again — point at the candidate nearest where
        // they picked last time (position, remembered relative to the window).
        if let win = AccessibilityReader.shared.targetFocusedWindowFrame(),
           let remembered = PickMemory.shared.recall(app: TargetAppTracker.shared.targetName,
                                                     stepKey: step.labelCacheKey, window: win),
           let nearest = all.min(by: { hypot($0.x - remembered.x, $0.y - remembered.y)
                                     < hypot($1.x - remembered.x, $1.y - remembered.y) }) {
            DebugLogger.log("ENGINE", "PICK MEMORY hit — auto-pointing at remembered candidate (\(Int(nearest.x)),\(Int(nearest.y))), not asking")
            currentTargetAX = nearest
            OverlayWindowController.shared.showDot(at: nearest, caption: currentInstruction)
            statusMessage = "Step \(currentStepIndex + 1) of \(steps.count)"
            // Still accept any candidate (memory can be slightly off) and re-store
            // whichever they actually click, so the pick self-corrects.
            installMultiClickMonitor(targets: all, forStep: currentStepIndex, stepKey: step.labelCacheKey)
            return
        }

        // JUDGE MODE: instead of asking the user to pick among 2–3 look-alikes,
        // let Gemini CHOOSE (Set-of-Mark). We stamp numbered badges on the REAL
        // candidate points and ask which is the target — a reliable multiple-
        // choice, and the dot lands on a real element's exact centre. Only in
        // max-accuracy mode (extra Gemini call); falls back to badges on any miss.
        if WayloConfig.maxAccuracy, all.count >= 2 {
            let token = locateToken
            if let capture = await ScreenCapturer.shared.captureActiveScreen(),
               let annotated = CandidateStamp.stamp(points: all, on: capture.image, screen: capture.screen) {
                let target = step.targetLabel.isEmpty ? step.elementDescription : step.targetLabel
                let id = await WayloAPIClient.shared.pickElement(
                    imageBase64: annotated, target: target,
                    stepInstruction: step.instruction, count: all.count)
                guard token == locateToken, isRunning else { return }
                if id >= 1, id <= all.count {
                    let chosen = all[id - 1]
                    DebugLogger.log("ENGINE", "JUDGE disambiguation: Gemini picked candidate #\(id) at (\(Int(chosen.x)),\(Int(chosen.y))) — precise dot, no badges")
                    currentTargetAX = chosen
                    OverlayWindowController.shared.showDot(at: chosen, caption: currentInstruction)
                    statusMessage = "Step \(currentStepIndex + 1) of \(steps.count)"
                    // Still accept any candidate + remember the pick (self-correcting).
                    installMultiClickMonitor(targets: all, forStep: currentStepIndex, stepKey: step.labelCacheKey)
                    return
                }
                DebugLogger.log("ENGINE", "JUDGE disambiguation: Gemini returned \(id) (no confident pick) — falling back to badges")
            }
        }

        statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — I see \(all.count) matches; click the right one"
        OverlayWindowController.shared.showCandidateBadges(at: all, caption: currentInstruction)
        Speaker.shared.speak("I found \(all.count) places that look right. Click the correct one and I'll continue.")
        installMultiClickMonitor(targets: all, forStep: currentStepIndex, stepKey: step.labelCacheKey)
    }

    /// Click monitor accepting a click near ANY of the candidate targets. The
    /// clicked candidate is remembered (relative to the window) so the same
    /// ambiguous step auto-resolves next time — "ask once, never ask again".
    private func installMultiClickMonitor(targets: [CGPoint], forStep stepIndex: Int, stepKey: String) {
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
                if let win = AccessibilityReader.shared.targetFocusedWindowFrame() {
                    PickMemory.shared.remember(app: TargetAppTracker.shared.targetName,
                                               stepKey: stepKey, axPoint: hit, window: win)
                }
                DebugLogger.log("ENGINE", "ambiguity resolved by user click at (\(Int(hit.x)),\(Int(hit.y))) → advancing (remembered)")
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
        // GARBAGE GUARD: /recover reads OCR context and occasionally echoes a
        // garbled fragment back as visibleLabel. OCR will then happily
        // "confirm" it — the garbage came FROM the screen — repointing the dot
        // at noise. An implausible label is demoted to a description-only hint
        // (vision can still use it semantically); it is never OCR-exact-matched.
        let relabelIsClean = Self.isPlausibleVisibleLabel(relabel)
        if !relabel.isEmpty, !relabelIsClean {
            DebugLogger.log("ENGINE", "recover label '\(relabel)' looks like OCR garbage — demoting to description-only hint")
        }
        if !relabel.isEmpty {
            let retry = await CoordinateResolver.shared.resolve(
                capture: capture,
                targetLabel: relabelIsClean ? relabel : "",
                elementDescription: relabel,
                stepInstruction: step.instruction,
                findDescription: relabel,
                screenRegion: step.screenRegion,
                task: taskName,
                stepIndex: step.index,
                totalSteps: steps.count,
                targetType: step.targetType,
                controlKind: step.controlKind,
                accessibleName: step.accessibleName
            )
            guard token == locateToken, isRunning else { return true }
            if let retry = retry {
                // Cache only a clean model label that the AX tree itself just
                // confirmed (retry resolved to a real element). The cache is an
                // AX-ONLY lookup next run, so an OCR-only label is dead weight
                // there — and this fleet-wide store is exactly how one bad
                // voice correction used to poison a step for every user.
                if !result.visibleLabel.isEmpty, relabelIsClean, retry.axElement != nil {
                    WayloAPIClient.shared.storeLabel(
                        appName: TargetAppTracker.shared.targetName,
                        stepDescription: step.labelCacheKey,
                        axLabel: result.visibleLabel
                    )
                    DebugLogger.log("RESOLVE", "LABEL_CACHE_STORED (relabel): '\(result.visibleLabel)' for key '\(step.labelCacheKey)'")
                    DebugState.shared.update(cache: "STORED \(result.visibleLabel)")
                }
                applyUpdatedInstruction(result.updatedInstruction)
                if retry.approximate {
                    presentApproximateRegion(retry, step: step)
                    return true
                }
                if !retry.alternates.isEmpty {
                    await PickMemory.shared.prefetch(app: TargetAppTracker.shared.targetName, stepKey: step.labelCacheKey)
                    guard token == locateToken, isRunning else { return true }
                    await presentAmbiguity(step: step, primary: retry.axPoint, alternates: retry.alternates)
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

    /// Whether a /recover visibleLabel looks like real on-screen label text
    /// rather than a garbled OCR fragment or a whole spoken sentence: short
    /// (2–40 chars, ≤5 words) and mostly letters. Implausible labels are used
    /// as description hints only, never OCR-exact-matched or cached.
    static func isPlausibleVisibleLabel(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.count <= 40 else { return false }
        guard t.split(whereSeparator: { $0.isWhitespace }).count <= 5 else { return false }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return Double(letters) / Double(t.count) >= 0.5
    }

    /// HARVEST GUARD — the gate before a user's click teaches a TEXT LABEL to the
    /// fleet-wide cache. A click only yields a cacheable label when BOTH:
    ///  1. the text looks like a control label (isPlausibleVisibleLabel: short,
    ///     mostly letters, ≤5 words) — not an email body / stray value, and
    ///  2. the clicked element is a REAL control (button/menu/checkbox/tab/link/
    ///     field), not a static-text blob, row, or generic group.
    /// Without this, a mis-harvested neighbour poisoned the DB fleet-wide: a
    /// paperclip step cached "New Message", a "To" step cached a whole email
    /// preview line. Icons still learn via pixels/location separately — this only
    /// gates the TEXT-label store. Returns the clean label, or nil to skip caching.
    private static let harvestControlRoles: Set<String> =
        ["AXButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
         "AXRadioButton", "AXTab", "AXLink", "AXToolbarButton", "AXMenuBarItem", "AXTextField"]

    static func harvestableLabel(from element: AXElementInfo?) -> String? {
        guard let el = element else { return nil }
        let label = (el.title.isEmpty ? el.description : el.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleVisibleLabel(label) else { return nil }
        guard harvestControlRoles.contains(el.role) else { return nil }
        return label
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
                anchorPosition: step.anchorPosition,
                accessibleName: step.accessibleName
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

    // MARK: - Live agent (All Things Agentic hackathon)

    /// Run a task as a LIVE agent loop. Identical teach behavior to
    /// `startGuidance` — Waylo opens the target app, collapses to the notch,
    /// points with the red dot, advances on click, takes Right-⌘ voice
    /// corrections — but the steps are decided ONE AT A TIME by the Genkit cloud
    /// agent (`/agent/next`) from the current screen + the running conversation,
    /// instead of a whole plan generated up front.
    func startLiveAgent(goal: String) {
        NSLog("[Waylo] startLiveAgent: '%@'", goal)
        resetForNewRun()
        steps = []
        stepCount = 0
        currentStepIndex = 0
        taskName = goal
        liveAgentActive = true
        liveAgentGoal = goal
        agentHistory = []
        agentAnswers = []
        lastAgentInstruction = nil
        pendingClarify = nil
        isRunning = true
        installDebugHotkey()
        DebugLogger.log("LIVE", "▶ live agent start — goal='\(goal)'")

        // Collapse to the notch pill — the guide lives in the notch (same as teach).
        NotchPanelController.expansion.expanded = false

        // Open the target app first, inferred from the goal (Waylo opens native
        // apps itself — the agent then guides INSIDE it and never has to fumble
        // the Dock). Mirrors startGuidance's deterministic app-open guard.
        let app = Self.appFromGoal(goal)
        planAppName = app
        let appIsFrontmost = !app.isEmpty && TargetAppTracker.shared.targetName.caseInsensitiveCompare(app) == .orderedSame
        let appHasWindow = AccessibilityReader.shared.targetFocusedWindowFrame() != nil
        if !app.isEmpty, (!appIsFrontmost || !appHasWindow), let url = AppLauncher.resolveApp(named: app) {
            DebugLogger.log("LIVE", "opening target app '\(app)' first (frontmost=\(appIsFrontmost) window=\(appHasWindow))")
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            Task {
                await ScreenCapturer.shared.settleAfterAction()
                guard self.isRunning, self.liveAgentActive else { return }
                await self.fetchNextAgentStep()
            }
            return
        }
        Task { await fetchNextAgentStep() }
    }

    /// Ask the cloud agent for the next single step given the live screen + the
    /// running conversation, then feed it into the same step machinery as a plan.
    private func fetchNextAgentStep() async {
        guard isRunning, liveAgentActive else { return }

        // Record what the user just did (the step they were on) into the convo.
        if let last = lastAgentInstruction {
            agentHistory.append(.init(instruction: last, outcome: "user did it"))
            lastAgentInstruction = nil
        }

        state = .locating
        statusMessage = "Thinking about the next step…"
        let spinner = ScreenCoordinates.cocoaToAX(NSEvent.mouseLocation)
        OverlayWindowController.shared.showLoading(at: spinner)

        let screen = ScreenContextBuilder.build()
        let appName = TargetAppTracker.shared.targetName

        let decision: WayloAgentClient.Decision
        do {
            // userId nil ⇒ Firestore memory OFF for now (it was bleeding stale
            // answers across unrelated tasks); re-enable once scoped by goal.
            decision = try await WayloAgentClient.shared.nextStep(
                goal: liveAgentGoal, appName: appName, screen: screen,
                userId: nil, history: agentHistory, answers: agentAnswers)
        } catch {
            OverlayWindowController.shared.hideDot()
            DebugLogger.log("LIVE", "agent call FAILED: \(error.localizedDescription)")
            finishLiveAgent(spoken: "Sorry, I lost the connection. Let's try that again.")
            return
        }
        guard isRunning, liveAgentActive else { return }
        DebugLogger.log("LIVE", "decision status=\(decision.status) — \(decision.reasoning ?? "")")

        switch decision.status {
        case "done":
            await onTaskComplete()

        case "clarify":
            OverlayWindowController.shared.hideDot()
            guard let q = decision.question else { await onTaskComplete(); return }
            pendingClarify = q
            state = .showing
            statusMessage = q.prompt
            currentInstruction = q.prompt
            let opts = q.options.isEmpty ? "" : "  (\(q.options.joined(separator: "  /  ")))"
            OverlayWindowController.shared.showBanner("❓ \(q.prompt)\(opts)\nHold Right ⌘ and answer out loud")
            Speaker.shared.speak("\(q.prompt) Hold the right command key and tell me.")
            DebugLogger.log("LIVE", "❓ CLARIFY: \(q.prompt) options=\(q.options)")

        default: // "continue" / "recover"
            guard let action = decision.action else {
                OverlayWindowController.shared.hideDot()
                try? await Task.sleep(nanoseconds: 700_000_000)
                await fetchNextAgentStep()
                return
            }
            let step = Self.stepFromAction(action, index: steps.count)
            steps.append(step)
            stepCount = steps.count
            lastAgentInstruction = action.instruction
            await executeStep(index: steps.count - 1)
        }
    }

    /// Right-⌘ voice while a live-agent guide runs: either the ANSWER to a
    /// pending clarify, or a CORRECTION of the current dot — both fed back to the
    /// agent, which re-decides. (Plain nav — "next"/"back"/"repeat" — is handled
    /// by applyVoiceCorrection's fast-paths before this is called.)
    private func handleLiveAgentVoice(_ message: String) {
        OverlayWindowController.shared.hideDot()
        if let q = pendingClarify {
            pendingClarify = nil
            agentAnswers.append(.init(question: q.prompt, answer: message))
            OverlayWindowController.shared.showBanner("“\(message)”", autoDismissAfter: 2)
            DebugLogger.log("LIVE", "→ answer: '\(message)'")
            Task { await fetchNextAgentStep() }
            return
        }
        // A correction on the current dot — tell the agent it was wrong and
        // re-point THIS step (drop the wrong step, re-fetch a replacement).
        DebugLogger.log("LIVE", "→ correction: '\(message)'")
        OverlayWindowController.shared.showBanner("“\(message)”", autoDismissAfter: 2)
        let last = lastAgentInstruction ?? "(the current step)"
        lastAgentInstruction = nil
        agentHistory.append(.init(instruction: last,
            outcome: "the red dot was NOT right — the user says: \(message). Re-point to the correct place; do not repeat the same spot."))
        if !steps.isEmpty { steps.removeLast(); stepCount = steps.count }
        Task { await fetchNextAgentStep() }
    }

    private func finishLiveAgent(spoken: String) {
        liveAgentActive = false
        isRunning = false
        state = .complete
        locateToken += 1
        removeClickMonitor()
        removeKeyAdvanceMonitor()
        OverlayWindowController.shared.hideDot()
        statusMessage = spoken
        currentInstruction = spoken
        Speaker.shared.speak(spoken)
        NotchPanelController.expansion.expanded = true
        DebugLogger.log("LIVE", "■ \(spoken)")
    }

    /// Best-effort: the installed app whose name appears in the goal text.
    /// "make the text bold in pages" → "Pages"; "" when none matches. Longest
    /// name wins so "Google Chrome" beats "Chrome".
    static func appFromGoal(_ goal: String) -> String {
        let g = " " + goal.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ") + " "
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "/Applications/Utilities", ("~/Applications" as NSString).expandingTildeInPath]
        var names: [String] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            names += items.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        }
        for name in names.sorted(by: { $0.count > $1.count }) {
            let n = name.lowercased()
            guard n.count >= 3 else { continue }
            if g.contains(" \(n) ") { return name }
        }
        return ""
    }

    /// Convert a cloud-agent action into a teach Step (always a click target).
    static func stepFromAction(_ a: WayloAgentClient.Action, index: Int) -> Step {
        let isIcon = (a.elementType ?? "").uppercased().contains("ICON")
        return Step(
            index: index,
            instruction: a.instruction,
            findDescription: a.findDescription ?? a.visualDescription ?? a.instruction,
            targetLabel: a.alternateLabels?.first ?? "",
            elementDescription: a.visualDescription ?? a.findDescription ?? a.instruction,
            action: .click,
            key: nil,
            screenRegion: mapRegion(a.screenRegion),
            targetType: isIcon ? .icon : .text,
            controlKind: mapControl(a.elementType))
    }

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

        // A completed guide during a learning session becomes part of the
        // session's memory — the next follow-up plan knows what was just done.
        SkillSession.shared.recordCompleted(task: taskName)

        // Record the finished guide so the user can rate it (✓ caches it as
        // correct, ✗ forgets it) from the panel's history list.
        if !taskName.isEmpty, !steps.isEmpty {
            TaskHistory.shared.record(task: taskName, app: planAppName, steps: steps)
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
        // "That was the right spot, continue." If the user recently clicked AWAY
        // from the dot on THIS step, ⌃⌥⌘N means "you pointed wrong — it's where I
        // just clicked": confirm that click as ground truth (learn it fleet-wide)
        // and advance. This is the reliable, explicit correction the auto
        // screen-change detection can miss. No recent off-dot click → fall back to
        // the normal re-detect (fresh screenshot → recovery).
        if let last = lastOffTargetClick,
           last.stepIndex == currentStepIndex,
           Date().timeIntervalSince(last.at) < 30 {
            DebugLogger.log("ENGINE", "⌃⌥⌘N with a recent off-dot click → confirming it as the target + advancing")
            lastOffTargetClick = nil
            confirmClickAsTarget(at: last.point, stepIndex: currentStepIndex)
            return
        }
        DebugLogger.log("ENGINE", "debugRelocate → forcing fresh screenshot + Gemini recovery for step \(currentStepIndex + 1)")
        let idx = currentStepIndex
        OverlayWindowController.shared.hideDot()
        Task { await forceRecover(stepIndex: idx) }
    }

    /// EXPLICIT correction: the user clicked the real target themselves (the dot
    /// was wrong) and pressed ⌃⌥⌘N to confirm. Treat their click as ground truth —
    /// learn it (harvest-guarded label + icon pixels/location + fleet + analytics)
    /// and advance. Unlike `watchOffTargetClick` this needs NO screen-change
    /// signal: the keypress IS the confirmation, so it works even when the right
    /// control doesn't visibly change the screen (selecting an item, focusing a
    /// field). This is the user's "I fixed it, store my spot and move on" flow.
    private func confirmClickAsTarget(at clickAX: CGPoint, stepIndex: Int) {
        guard isRunning, stepIndex < steps.count else { return }
        let step = steps[stepIndex]
        let appName = TargetAppTracker.shared.targetName
        let element = AccessibilityReader.shared.elementAt(axPoint: clickAX)
        let label = Self.harvestableLabel(from: element)
        DebugLogger.log("CORRECT", "user confirmed click (⌃⌥⌘N) at (\(Int(clickAX.x)),\(Int(clickAX.y))) as target for step \(stepIndex + 1) — learning '\(label ?? "(pixels only)")'")
        // Our predicted box was wrong — don't train on it.
        TrainingHarvest.shared.discard(stepIndex: stepIndex)
        if let label = label, !step.labelCacheKey.isEmpty {
            WayloAPIClient.shared.storeLabel(appName: appName, stepDescription: step.labelCacheKey, axLabel: label)
        }
        if step.targetType == .icon || step.targetLabel.isEmpty {
            learnIconPixels(at: clickAX, step: step, element: element)
        }
        var corrected: [String: Any] = ["x": Int(clickAX.x), "y": Int(clickAX.y)]
        if let el = element {
            corrected["text"] = (el.title.isEmpty ? el.description : el.title)
            corrected["bounds"] = ["x": Int(el.frame.minX), "y": Int(el.frame.minY),
                                   "w": Int(el.frame.width), "h": Int(el.frame.height)]
        }
        WayloAPIClient.shared.reportDetectionEvent(
            source: "user_confirm_click", task: taskName, stepNumber: stepIndex + 1,
            findDescription: step.findDescription, elementType: step.controlKind,
            screenRegion: step.screenRegion.rawValue, appName: appName, correctedTarget: corrected)
        currentTargetAX = clickAX
        advanceAfterClick(stepIndex: stepIndex)
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

        // Live-agent: an answer to a clarify, or a correction — the cloud agent
        // re-decides. (Reuses this same Right-⌘ voice entry point.)
        if liveAgentActive { handleLiveAgentVoice(message); return }

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
            // STAGE the clicked element's label for this step — the user's
            // click is ground truth ("clicked the + icon for playlists").
            // Persisted only when the whole guide is marked ✓, so a botched
            // run never poisons the cache. Element-level, so ANY future task
            // whose step means the same thing ("start a jam" → same + icon)
            // resolves via free AX.
            if stepIndex < steps.count {
                let step = steps[stepIndex]
                let el = AccessibilityReader.shared.elementAt(axPoint: clickAX)
                if !step.labelCacheKey.isEmpty, let label = Self.harvestableLabel(from: el) {
                    stagedStepLabels[step.labelCacheKey] = label
                    DebugLogger.log("CACHE", "staged '\(label)' for step \(stepIndex + 1) (commits on ✓)")
                } else if let el = el {
                    DebugLogger.log("CACHE", "click label not harvestable (role=\(el.role), text='\((el.title.isEmpty ? el.description : el.title).prefix(24))') — not caching")
                }
            }
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

        // OFF-TARGET click: maybe the USER knows better than the dot. Remember it
        // so ⌃⌥⌘N ("that was the right spot, continue") can confirm+learn it even
        // when the click caused no visible screen change. AND, if the screen DOES
        // visibly change right after, auto-learn it and move on.
        if !isRight {
            lastOffTargetClick = (point: clickAX, at: Date(), stepIndex: stepIndex)
            watchOffTargetClick(at: clickAX, stepIndex: stepIndex)
        }
    }

    /// The user's most recent click that landed AWAY from the dot during the
    /// current step — the candidate "you pointed wrong, it's actually here" spot
    /// that ⌃⌥⌘N confirms.
    private var lastOffTargetClick: (point: CGPoint, at: Date, stepIndex: Int)?

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

    // MARK: - Step-label staging (user clicks = ground truth; ✓ commits)

    /// labelCacheKey → verified element label, staged during the run. Written
    /// to the backend step-label cache only when the user marks the guide ✓ —
    /// element-level knowledge ("the + icon for playlists" → "New Playlist")
    /// that ANY future task with a similar step reuses, not just this task.
    private var stagedStepLabels: [String: String] = [:]

    /// Called by TaskHistory when the user presses ✓ on a completed guide.
    func commitStagedLabels() {
        guard !stagedStepLabels.isEmpty else { return }
        let appName = TargetAppTracker.shared.targetName
        for (key, label) in stagedStepLabels {
            WayloAPIClient.shared.storeLabel(appName: appName, stepDescription: key, axLabel: label)
        }
        DebugLogger.log("CACHE", "✓ committed \(stagedStepLabels.count) step label(s) to the cache")
        stagedStepLabels.removeAll()
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
        let appBefore = TargetAppTracker.shared.targetName
        DebugLogger.log("CORRECT", "off-target click at (\(Int(clickAX.x)),\(Int(clickAX.y))) — watching for effect")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard self.isRunning, self.state == .showing,
                  self.currentStepIndex == stepIndex, token == self.locateToken,
                  stepIndex < self.steps.count else { return }
            // The user clicked into a DIFFERENT app (checked mail, clicked the
            // desktop). The screen changed, but that's not the step being done —
            // learning from it once cached 'desktop' as WhatsApp's search field.
            guard TargetAppTracker.shared.targetName == appBefore else {
                DebugLogger.log("CORRECT", "click switched apps (\(appBefore) → \(TargetAppTracker.shared.targetName)) — not a correction, ignoring")
                return
            }
            let after = AccessibilityReader.shared.targetScreenSignature()
            guard after != before else { return } // click did nothing visible — ignore

            let step = self.steps[stepIndex]
            let appName = TargetAppTracker.shared.targetName
            let element = AccessibilityReader.shared.elementAt(axPoint: clickAX)
            // HARVEST GUARD: only a real control's short label is cacheable — a
            // click on a text blob / row must not poison the fleet cache.
            let label = Self.harvestableLabel(from: element)
            let rawLabel = element.map { $0.title.isEmpty ? $0.description : $0.title } ?? ""
            DebugLogger.log("CORRECT", "user's click WORKED — learning '\(label ?? "(no cacheable label; pixels only)")' as the real target for step \(stepIndex + 1)")

            // Our predicted box was WRONG — never train on it. (The corrected
            // target is reported below as ground truth instead.)
            TrainingHarvest.shared.discard(stepIndex: stepIndex)

            // 1. Label cache: next run of this step resolves to the user's
            //    element via AX and skips vision entirely.
            if let label = label, !step.labelCacheKey.isEmpty {
                WayloAPIClient.shared.storeLabel(appName: appName,
                                                 stepDescription: step.labelCacheKey,
                                                 axLabel: label)
            }
            // 1b. ICON PIXELS: SigLIP can't name tiny icons, so a text label is
            //     useless for an icon target. Instead remember the clicked
            //     icon's PIXELS (from the BEFORE image — it may be gone now) so
            //     next run recognises it for free via perceptual hash. This is
            //     how Waylo learns an icon it could never name.
            if step.targetType == .icon || step.targetLabel.isEmpty {
                self.learnIconPixels(at: clickAX, step: step, element: element)
            }
            // 2. Analytics: a user_correction event carrying the true target.
            var corrected: [String: Any] = ["x": Int(clickAX.x), "y": Int(clickAX.y)]
            if let el = element {
                corrected["text"] = rawLabel
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

    /// Crop the icon the user just clicked out of the step's BEFORE screenshot
    /// and remember its pixels (IconMemory). Keyed by the step's icon concept so
    /// the next run's YOLO boxes are pixel-matched for free — no SigLIP, no
    /// Gemini. The before-image matters: the icon is often gone after the click
    /// (a deleted email's trash icon), so the live screen can't be used.
    private func learnIconPixels(at clickAX: CGPoint, step: Step, element: AXElementInfo?) {
        guard let capture = lastStepCapture else { return }
        let screen = capture.screen
        guard screen.frame.width > 1, screen.frame.height > 1 else { return }

        // AX-global point → normalized (0–1) in the captured image (top-left).
        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        let nx = (clickAX.x - screen.frame.minX) / screen.frame.width
        let ny = (clickAX.y - axTop) / screen.frame.height
        guard (0...1).contains(nx), (0...1).contains(ny) else { return }

        // Crop the clicked element's box when it's icon-sized, else a ~46pt box
        // centred on the click (icons are small; a big AX container would hash
        // the whole toolbar, not the glyph).
        var halfW = 23.0 / Double(screen.frame.width)
        var halfH = 23.0 / Double(screen.frame.height)
        if let f = element?.frame, f.width <= 64, f.height <= 64, f.width > 6, f.height > 6 {
            halfW = Double(f.width) / 2 / Double(screen.frame.width)
            halfH = Double(f.height) / 2 / Double(screen.frame.height)
        }
        guard let crop = capture.image.cropNormalized(x: Double(nx) - halfW, y: Double(ny) - halfH,
                                                      w: halfW * 2, h: halfH * 2) else { return }
        let concept = step.targetLabel.isEmpty ? step.elementDescription : step.targetLabel
        IconMemory.shared.remember(crop: crop, app: TargetAppTracker.shared.targetName, concept: concept)
        // Also remember WHERE it is, so next run clicks it with no YOLO at all.
        if let win = AccessibilityReader.shared.targetFocusedWindowFrame() {
            IconMemory.shared.rememberLocation(app: TargetAppTracker.shared.targetName, concept: concept,
                                               axPoint: clickAX, window: win, image: capture.image, screen: capture.screen)
        }
        // User-confirmed = gold: add this REAL icon to the fleet-wide dataset.
        if let (b64, _) = ScreenCapturer.compressedJPEGBase64(crop, maxWidth: 128) {
            WayloAPIClient.shared.uploadIconReference(label: CoordinateResolver.conciseObjectPhrase(concept), imageBase64: b64)
        }
        DebugLogger.log("CORRECT", "learned ICON PIXELS + LOCATION + uploaded reference for '\(concept)'")
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
