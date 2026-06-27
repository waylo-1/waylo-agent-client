import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var notchPanel: NotchPanelController?
    private var onboardingController: OnboardingWindowController?
    private var hotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // No Dock icon.

        // Track which real app the user is working in (not Waylo itself).
        TargetAppTracker.shared.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "cursorarrow.rays",
            accessibilityDescription: "Waylo"
        )
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self

        // Ask the speech recognizer for permission up front (non-blocking).
        MicHandler.shared.requestPermission()

        // Enable mid-session voice Q&A (Ctrl+Option+A).
        ConversationEngine.shared.start()

        // Request Screen Recording up front — required for the vision fallback.
        ScreenRecordingPermission.request()

        checkAccessibilityPermission()
        registerGlobalHotkey()

        // Show the always-visible pill at the notch.
        showPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyMonitor = nil
        }
    }

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
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
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

    // MARK: - Global hotkey (Cmd+Shift+W)

    private func registerGlobalHotkey() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 13 {
                DispatchQueue.main.async {
                    self?.togglePanel()
                }
            }
        }
    }
}
