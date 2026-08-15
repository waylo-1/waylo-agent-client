import Cocoa

/// A transparent, borderless, always-on-top window used to draw the red dot.
/// Floats above every other app (including full-screen) and is click-through
/// by default so the user can interact with the app beneath it.
final class OverlayWindow: NSWindow {
    init() {
        let frame = ScreenCoordinates.globalFrame
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Transparent background.
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false

        // Float above EVERYTHING including full-screen apps.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))

        // CRITICAL: click-through so the user can interact with the app beneath.
        ignoresMouseEvents = true

        // Join all spaces and stay above full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Span every display so the dot can be placed on any screen.
        setFrame(frame, display: true)
    }

    // The overlay should never become key/main so it doesn't steal focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Enable interaction when capturing a hold gesture on the dot.
    func enableMouseInteraction() { ignoresMouseEvents = false }

    /// Restore the default click-through behaviour.
    func disableMouseInteraction() { ignoresMouseEvents = true }
}
