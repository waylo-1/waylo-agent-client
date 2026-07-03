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

        // Show the always-visible pill at the notch.
        showPanel()
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
        if !trusted {
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
        // ⌃⌥⌘ V — voice command (speak a task, or a mid-guide correction).
        hk.register(keyCode: 9, name: "voice") {
            Task { @MainActor in VoiceCommandEngine.shared.activate() }
        }
        // ⌃⌥⌘ N — re-detect the current step (fresh screenshot → Nova recovery).
        hk.register(keyCode: 45, name: "re-detect") {
            Task { @MainActor in GuidanceEngine.shared.debugRelocate() }
        }
        // ⌃⌥⌘ A — ask a question by voice.
        hk.register(keyCode: 0, name: "ask") {
            Task { @MainActor in ConversationEngine.shared.activate() }
        }
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
