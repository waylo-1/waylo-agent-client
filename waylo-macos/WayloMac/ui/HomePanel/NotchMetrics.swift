import AppKit

/// Measures the physical notch so the UI can hug it (Boring Notch style).
enum NotchMetrics {
    struct Info {
        let width: CGFloat
        let height: CGFloat
        let hasNotch: Bool
    }

    /// The display the panel should anchor to: the built-in (notched) screen
    /// when present — a notch UI on an external monitor makes no sense — else
    /// whatever is main. Multi-display safe.
    static var anchorScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    static func current() -> Info {
        guard let screen = anchorScreen else {
            return Info(width: 180, height: 32, hasNotch: false)
        }
        let top = screen.safeAreaInsets.top
        if top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            if width > 0 {
                return Info(width: width, height: top, hasNotch: true)
            }
        }
        // No notch — use a small pill near the top center.
        return Info(width: 180, height: 32, hasNotch: false)
    }
}
