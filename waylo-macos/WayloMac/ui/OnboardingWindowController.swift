import Cocoa
import SwiftUI

/// Hosts the OnboardingView in a standard window.
@MainActor
final class OnboardingWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Waylo"
        window.center()

        self.init(window: window)

        let view = OnboardingView(onGranted: { [weak self] in
            self?.close()
        })
        window.contentViewController = NSHostingController(rootView: view)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
