import Foundation
import AppKit

/// High-level state of a running guide.
enum GuidanceState {
    case idle
    case locating   // taking a screenshot / asking the vision model
    case showing    // dot is on screen, waiting for the user to press Next
    case manual     // couldn't locate; user does it themselves then presses Next
    case paused
    case complete
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
    @Published var currentStepIndex = 0
    @Published var stepCount = 0
    @Published var currentInstruction = ""
    @Published var statusMessage = ""

    private var steps: [Step] = []
    private var taskName = ""
    private var debugKeyMonitor: Any?
    private var clickMonitor: Any?
    private var keyAdvanceMonitor: Any?
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
        steps = plan.steps
        stepCount = plan.steps.count
        taskName = plan.task
        currentStepIndex = 0
        isRunning = true
        installDebugHotkey()

        Task { await executeStep(index: 0) }
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

    /// Advance to the next step. Ignored while a locate is in flight.
    func nextStep() {
        guard isRunning, state != .locating, state != .paused else { return }
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

        Speaker.shared.speak(step.instruction)

        switch step.action {
        case .click:
            await locateAndShow(step: step)
        case .type, .key, .info:
            presentNonClickStep(step)
        }
    }

    /// Non-click steps (type text / press a key / informational). Shows a banner
    /// and advances when the user commits (Return, or the specified key).
    private func presentNonClickStep(_ step: Step) {
        locateToken += 1
        state = .showing
        OverlayWindowController.shared.showBanner(step.instruction)

        switch step.action {
        case .info:
            statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — press Next when ready"
        default:
            statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — do it, then press \(keyName(for: step))"
            installKeyAdvanceMonitor(forStep: currentStepIndex, step: step)
        }
    }

    private func keyName(for step: Step) -> String {
        switch (step.key ?? "").lowercased() {
        case "tab": return "Tab"
        case "space": return "Space"
        case "escape", "esc": return "Esc"
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
        guard let capture = await ScreenCapturer.shared.captureActiveScreen() else {
            NSLog("[Waylo] locate: captureActiveScreen returned nil")
            guard token == locateToken, isRunning else { return }
            state = .manual
            statusMessage = "I couldn't read the screen. Do it yourself, then press Next."
            return
        }
        NSLog("[Waylo] locate: captured screen %dx%d, resolving step %d", capture.image.width, capture.image.height, currentStepIndex + 1)
        guard token == locateToken, isRunning else { return }

        let resolution = await CoordinateResolver.shared.resolve(
            capture: capture,
            targetLabel: step.targetLabel,
            elementDescription: step.elementDescription,
            stepInstruction: step.instruction,
            findDescription: step.findDescription,
            screenRegion: step.screenRegion,
            task: taskName,
            stepIndex: step.index,
            totalSteps: steps.count
        )

        guard token == locateToken, isRunning else { return }

        if let resolution = resolution {
            applyUpdatedInstruction(resolution.updatedInstruction)
            currentTargetAX = resolution.axPoint
            OverlayWindowController.shared.showDot(at: resolution.axPoint, caption: currentInstruction)
            state = .showing
            statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click the dot to continue"
            // Seamless: clicking on/near the dot advances to the next step.
            installClickMonitor(target: resolution.axPoint, forStep: currentStepIndex)
            return
        }

        // Before giving up, self-heal: show the loading dot and ask the model to
        // re-read the screen — it can relabel this step or replan the rest.
        if await attemptRecovery(step: step, capture: capture, token: token) {
            return
        }

        guard token == locateToken, isRunning else { return }
        // All layers + recovery failed — manual.
        OverlayWindowController.shared.hideDot()
        state = .manual
        statusMessage = "I couldn't find it. Do it yourself, then press Next."
        Speaker.shared.speak("I couldn't find that one. Please do it yourself, then press Next.")
    }

    /// Self-healing: screenshot → backend `/recover`. The model can correct the
    /// element label (then we retry OCR/AX) or replan all remaining steps.
    /// Returns true if it handled the step (showed a dot or replanned).
    private func attemptRecovery(step: Step, capture: ScreenCapturer.Capture, token: Int) async -> Bool {
        state = .locating
        statusMessage = "Let me take a closer look..."
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
                targetLabel: step.targetLabel
            )
        } catch {
            print("[Engine] recover failed: \(error)")
            return false
        }

        guard token == locateToken, isRunning else { return true }
        OverlayWindowController.shared.hideDot()

        // 1. Replan: replace remaining steps and continue from here.
        if result.replan, !result.steps.isEmpty {
            print("[Engine] replanning \(result.steps.count) steps from index \(currentStepIndex)")
            replacePlan(from: currentStepIndex, with: result.steps)
            await executeStep(index: currentStepIndex)
            return true
        }

        // 2. Relabel: retry the resolver with the model's corrected label.
        if !result.visibleLabel.isEmpty {
            let retry = await CoordinateResolver.shared.resolve(
                capture: capture,
                targetLabel: result.visibleLabel,
                elementDescription: result.visibleLabel,
                stepInstruction: step.instruction,
                findDescription: result.visibleLabel,
                screenRegion: step.screenRegion,
                task: taskName,
                stepIndex: step.index,
                totalSteps: steps.count
            )
            guard token == locateToken, isRunning else { return true }
            if let retry = retry {
                // Cache this working relabel so future runs skip recovery/Nova.
                WayloAPIClient.shared.storeLabel(
                    appName: TargetAppTracker.shared.targetName,
                    stepDescription: step.elementDescription.isEmpty ? step.instruction : step.elementDescription,
                    axLabel: result.visibleLabel
                )
                applyUpdatedInstruction(result.updatedInstruction)
                currentTargetAX = retry.axPoint
                OverlayWindowController.shared.showDot(at: retry.axPoint, caption: currentInstruction)
                state = .showing
                statusMessage = "Step \(currentStepIndex + 1) of \(steps.count) — click the dot to continue"
                installClickMonitor(target: retry.axPoint, forStep: currentStepIndex)
                return true
            }
        }

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
                screenRegion: s.screenRegion
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
        isRunning = false
    }

    // MARK: - Global debug hotkey (Ctrl+Option+N) — re-check / fix the step

    private func installDebugHotkey() {
        guard debugKeyMonitor == nil else { return }
        debugKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Ctrl + Option + N  (keyCode 45 = N)
            if event.modifierFlags.contains([.control, .option]) && event.keyCode == 45 {
                Task { @MainActor in self?.debugRelocate() }
            }
        }
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
        guard isRunning, state != .locating else { return }
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

    // MARK: - Click-to-advance

    /// Installs a global click monitor: when the user clicks on/near the dot,
    /// advance to the next step automatically (seamless).
    private func installClickMonitor(target: CGPoint, forStep stepIndex: Int) {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // Capture the click location synchronously, then hop to the main actor.
            let clickCocoa = NSEvent.mouseLocation
            Task { @MainActor in
                self?.handleGlobalClick(at: clickCocoa, target: target, stepIndex: stepIndex)
            }
        }
    }

    private func handleGlobalClick(at clickCocoa: CGPoint, target: CGPoint, stepIndex: Int) {
        guard isRunning, state == .showing, currentStepIndex == stepIndex else { return }

        // Convert the click to AX coords and measure distance to the dot.
        let clickAX = ScreenCoordinates.cocoaToAX(clickCocoa)
        let dx = clickAX.x - target.x
        let dy = clickAX.y - target.y
        guard (dx * dx + dy * dy).squareRoot() <= clickToleranceAX else { return }

        // Hit! Advance after a short settle delay so the UI can update.
        removeClickMonitor()
        OverlayWindowController.shared.hideDot()
        let next = stepIndex + 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s settle
            guard self.isRunning, self.currentStepIndex == stepIndex else { return }
            await self.executeStep(index: next)
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    // MARK: - Key-to-advance (for type / key steps)

    private func installKeyAdvanceMonitor(forStep stepIndex: Int, step: Step) {
        removeKeyAdvanceMonitor()
        keyAdvanceMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            Task { @MainActor in
                self?.handleKeyAdvance(code: code, stepIndex: stepIndex, step: step)
            }
        }
    }

    private func handleKeyAdvance(code: UInt16, stepIndex: Int, step: Step) {
        guard isRunning, state == .showing, currentStepIndex == stepIndex else { return }

        // Which key commits this step? Default Return (36); honor an explicit key.
        let commit: Set<UInt16>
        switch (step.key ?? "").lowercased() {
        case "tab": commit = [48]
        case "space": commit = [49]
        case "escape", "esc": commit = [53]
        default: commit = [36, 76] // Return and keypad Enter
        }
        guard commit.contains(code) else { return }

        removeKeyAdvanceMonitor()
        OverlayWindowController.shared.hideDot()
        let next = stepIndex + 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard self.isRunning, self.currentStepIndex == stepIndex else { return }
            await self.executeStep(index: next)
        }
    }

    private func removeKeyAdvanceMonitor() {
        if let monitor = keyAdvanceMonitor {
            NSEvent.removeMonitor(monitor)
            keyAdvanceMonitor = nil
        }
    }
}
