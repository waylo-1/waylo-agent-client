import Cocoa

/// Borderless panel that hangs from the notch. Unlike a non-activating panel,
/// this one CAN become key so the text field and buttons receive input.
final class NotchWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
