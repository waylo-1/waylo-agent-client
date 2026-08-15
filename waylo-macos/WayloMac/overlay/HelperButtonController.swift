import Cocoa
import SwiftUI

/// A small interactive "I'll do it for you" button, shown while Waylo points at
/// something the user may struggle to find (a Dock icon has no text, so it's
/// the hardest thing on screen to describe). The main overlay window is
/// click-through by design, so this needs its own interactive panel.
@MainActor
final class HelperButtonController {
    static let shared = HelperButtonController()

    private var panel: NSPanel?
    private var action: (() -> Void)?

    private init() {}

    /// Shows the button centered near the bottom of the active screen.
    /// `title` is the button label; `action` runs when it's clicked.
    func show(title: String, action: @escaping () -> Void) {
        hide()
        self.action = action

        let size = CGSize(width: 340, height: 64)
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? .zero

        let p = NSPanel(
            contentRect: NSRect(x: frame.midX - size.width / 2,
                                y: frame.minY + 150,
                                width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.contentViewController = NSHostingController(
            rootView: HelperButtonView(title: title) { [weak self] in
                self?.action?()
                self?.hide()
            }
        )
        p.orderFrontRegardless()
        panel = p
        DebugLogger.log("HELPER", "shown: '\(title)'")
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        action = nil
    }
}

private struct HelperButtonView: View {
    let title: String
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.red.opacity(hovering ? 1.0 : 0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}
