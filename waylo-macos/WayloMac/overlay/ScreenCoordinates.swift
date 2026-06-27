import AppKit

/// Converts between the two coordinate systems Waylo deals with:
///
/// - **AX / Quartz**: origin at the TOP-LEFT of the primary display, y grows
///   downward. This is what `AXUIElement` position attributes use.
/// - **Cocoa**: origin at the BOTTOM-LEFT of the primary display, y grows
///   upward. This is what `NSWindow` / `NSView` frames and `NSEvent.mouseLocation`
///   use.
///
/// The flip MUST use the height of the *primary* display (the screen whose
/// origin is (0,0)) — not `NSScreen.main`, which is whichever screen currently
/// has the key window and is wrong for a menu-bar accessory app or multi-monitor
/// setups.
enum ScreenCoordinates {

    /// The primary display (origin at (0,0)). Falls back to the first screen.
    static var primaryScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
    }

    /// Height of the primary display, used as the reference for Y flipping.
    static var primaryHeight: CGFloat {
        primaryScreen?.frame.height ?? 0
    }

    /// The union of every screen's frame, in Cocoa global coordinates. The
    /// overlay window is sized to this so the dot can appear on any display.
    static var globalFrame: CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    }

    /// AX/Quartz point (top-left origin) → Cocoa global point (bottom-left origin).
    static func axToCocoa(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Cocoa global point (bottom-left origin) → AX/Quartz point (top-left origin).
    static func cocoaToAX(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}
