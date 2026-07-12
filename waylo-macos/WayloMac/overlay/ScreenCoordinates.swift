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

    /// The primary display (origin at (0,0)) — never NSScreen.main, so it's
    /// stable regardless of cursor position or which screen is "main".
    /// Falls back to the first screen.
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

    /// The union of every display expressed in AX/Quartz coordinates (top-left
    /// origin, y down). Used to clamp dot placement so a stray point can never be
    /// drawn off every screen — while still supporting valid multi-monitor points
    /// (a dot on a display to the right/above the primary stays valid).
    static var axGlobalBounds: CGRect {
        let h = primaryHeight
        return NSScreen.screens.reduce(CGRect.null) { acc, screen in
            let f = screen.frame
            // Cocoa (bottom-left) → AX (top-left): axY = primaryHeight - f.maxY.
            let axRect = CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
            return acc.union(axRect)
        }
    }

    /// Clamps an AX point to the union of all displays (AX space).
    static func clampToScreens(_ p: CGPoint) -> CGPoint {
        let b = axGlobalBounds
        guard !b.isNull else { return p }
        return CGPoint(x: min(max(p.x, b.minX), b.maxX),
                       y: min(max(p.y, b.minY), b.maxY))
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
