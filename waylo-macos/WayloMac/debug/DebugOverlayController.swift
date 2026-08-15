import Cocoa
import SwiftUI

/// Hosts the DebugOverlayView in a borderless, click-through panel pinned to the
/// top-right of the main screen. Toggled with Cmd+Shift+D.
@MainActor
final class DebugOverlayController {
    static let shared = DebugOverlayController()

    private var window: NSWindow?

    private init() {}

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        if window == nil { build() }
        position()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 208),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: DebugOverlayView())
        window = panel
    }

    private func position() {
        guard let window = window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - window.frame.width - 16
        let y = visible.maxY - window.frame.height - 16
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
