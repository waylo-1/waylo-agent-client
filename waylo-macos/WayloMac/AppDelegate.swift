import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var notchPanel: NotchPanelController?
    private var onboardingController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // No Dock icon.

        DebugLogger.log("BOOT", "App launched. Hotkeys: ⌃⌥⌘V voice · ⌃⌥⌘N re-detect · ⌃⌥⌘A ask · ⌃⌥⌘Q screen-Q&A · ⌃⌥⌘W panel · ⌃⌥⌘D debug · ⌃⌥⌘T coord-test")

        // Track which real app the user is working in (not Waylo itself).
        TargetAppTracker.shared.start()

        // Pull the fleet's learned icon hashes so this Mac recognizes icons
        // other users' verified guides already taught (best-effort).
        Task.detached(priority: .utility) { await IconMemory.shared.syncFromBackend() }

        // Day-one seed of the labelled-icon dataset from SF Symbols (once).
        IconReferenceSeeder.seedOnceIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "cursorarrow.rays",
            accessibilityDescription: "Waylo"
        )
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self

        // Ask for microphone + speech permission up front (non-blocking).
        MicHandler.shared.requestPermission()

        // Request Screen Recording up front — required for the vision fallback.
        ScreenRecordingPermission.request()

        checkAccessibilityPermission()
        registerHotkeys()

        // Open the panel once at launch (clicky-style) so the user sees the
        // task input immediately; afterwards it's click-driven via the
        // menu-bar icon / ⌃⌥⌘W / the notch pill while a guide runs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.expandPanel()
        }
    }

    /// Opens the notch panel expanded.
    func expandPanel() {
        if notchPanel == nil {
            notchPanel = NotchPanelController()
        }
        notchPanel?.expand()
    }

    func applicationWillTerminate(_ notification: Notification) {}

    @objc func togglePanel() {
        if notchPanel == nil {
            notchPanel = NotchPanelController()
        }
        notchPanel?.toggle()
    }

    /// Shows the notch panel (used when a guide starts so progress lives in the notch).
    func showPanel() {
        if notchPanel == nil {
            notchPanel = NotchPanelController()
        }
        notchPanel?.show()
    }

    // MARK: - Permissions

    private func checkAccessibilityPermission() {
        // takeUnretainedValue: this is a global CF constant we don't own —
        // takeRetainedValue would over-release it.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        // Onboarding covers ALL permissions with live status — show it when
        // anything is missing, so nothing is discovered broken mid-task.
        if !trusted || !ScreenRecordingPermission.isGranted {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController()
        }
        onboardingController?.show()
    }

    // MARK: - Global hotkeys (CGEventTap — work in any app, consume the combo)

    private func registerHotkeys() {
        let hk = HotkeyManager.shared
        // Esc — the universal "stop": ends a running guide or agent task. Only
        // consumed when something was actually running (handler returns true).
        hk.escStopAction = {
            MainActor.assumeIsolated {
                if AgentEngine.shared.isRunning {
                    AgentEngine.shared.stop()
                    Speaker.shared.stop()
                    Speaker.shared.speak("Stopped.")
                    OverlayWindowController.shared.hideDot()
                    return true
                }
                if GuidanceEngine.shared.isRunning {
                    GuidanceEngine.shared.stopGuidance()
                    Speaker.shared.speak("Stopped.")
                    return true
                }
                return false
            }
        }
        // ⌃⌥⌘ V — HOLD to talk: speak a task (or mid-guide correction) for as
        // long as it's held; release to run the whole transcript.
        hk.registerHold(keyCode: 9, name: "voice",
            onPress: { Task { @MainActor in VoiceCommandEngine.shared.beginPushToTalk() } },
            onRelease: { Task { @MainActor in VoiceCommandEngine.shared.endPushToTalk() } })
        // HOLD RIGHT ⌘ — the one-finger push-to-talk. Same handlers as ⌃⌥⌘V,
        // but a single key an elderly/non-technical user can actually remember
        // and hold: "hold the right command key and speak."
        hk.registerModifierHold(keyCode: HotkeyManager.rightCommandKeyCode, name: "voice",
            onPress: { Task { @MainActor in VoiceCommandEngine.shared.beginPushToTalk() } },
            onRelease: { Task { @MainActor in VoiceCommandEngine.shared.endPushToTalk() } })
        // ⌃⌥⌘ N — "that was the right spot, continue": if the user just clicked
        // away from the dot, confirm+learn that click and advance; else re-detect.
        hk.register(keyCode: 45, name: "re-detect") {
            Task { @MainActor in GuidanceEngine.shared.debugRelocate() }
        }
        // ⌃⌥⌘ A — HOLD to ask a question by voice.
        hk.registerHold(keyCode: 0, name: "ask",
            onPress: { Task { @MainActor in ConversationEngine.shared.beginPushToTalk() } },
            onRelease: { Task { @MainActor in ConversationEngine.shared.endPushToTalk() } })
        // ⌃⌥⌘ Q — ask a free-form question answered from what's on screen.
        hk.register(keyCode: 12, name: "screen-question") {
            Task { @MainActor in ConversationEngine.shared.askAboutScreen() }
        }
        // ⌃⌥⌘ W — toggle the notch panel.
        hk.register(keyCode: 13, name: "panel") {
            Task { @MainActor in self.togglePanel() }
        }
        // ⌃⌥⌘ D — toggle the debug overlay. Logging stays ON always so we never
        // lose pipeline traces (the overlay is just the on-screen panel).
        hk.register(keyCode: 2, name: "debug") {
            Task { @MainActor in
                DebugLogger.isEnabled = true
                DebugOverlayController.shared.toggle()
                DebugLogger.log("DEBUG", "overlay toggled (logging stays on)")
            }
        }
        // ⌃⌥⌘ T — coordinate self-test.
        hk.register(keyCode: 17, name: "coord-test") {
            Task { @MainActor in CoordinateTester.runCoordinateTest() }
        }
        hk.start()
    }
}
