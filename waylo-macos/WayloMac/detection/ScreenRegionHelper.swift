import AppKit

/// Maps a ScreenRegion to rectangles, both in a screen's local coordinates
/// (top-left origin, used for cropping the OCR image) and in AX global
/// coordinates (top-left origin, used to filter AX elements / place the dot).
enum ScreenRegionHelper {

    /// Region rect in the screen's LOCAL coordinates (origin top-left of `screenSize`).
    /// Height of the macOS menu bar in points. The `ribbon` (the APP's toolbar)
    /// starts below it — including the menu bar in `ribbon` made "the Format
    /// button in the toolbar" match Pages' menu-bar "Format" MENU instead.
    static var menuBarHeight: CGFloat {
        guard let screen = NSScreen.main else { return 25 }
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 1 ? h : 25
    }

    static func localRect(for region: ScreenRegion, screenSize: CGSize) -> CGRect? {
        let w = screenSize.width
        let h = screenSize.height
        let menuBar = menuBarHeight
        switch region {
        case .menuBar:     return CGRect(x: 0,        y: 0,        width: w,         height: max(menuBar, h * 0.04))
        case .ribbon:      return CGRect(x: 0,        y: menuBar,  width: w,         height: h * 0.20 - menuBar)
        case .dialog:      return CGRect(x: w * 0.20, y: h * 0.15, width: w * 0.60,  height: h * 0.70)
        case .sidebar:     return CGRect(x: 0,        y: h * 0.08, width: w * 0.26,  height: h * 0.88)
        case .spreadsheet: return CGRect(x: 0,        y: h * 0.10, width: w,         height: h * 0.88)
        case .statusBar:   return CGRect(x: 0,        y: h * 0.93, width: w,         height: h * 0.07)
        case .fullScreen:  return nil
        }
    }

    /// Region rect in AX global coordinates (top-left origin) for the given screen.
    static func axGlobalRect(for region: ScreenRegion, on screen: NSScreen) -> CGRect? {
        guard let local = localRect(for: region, screenSize: screen.frame.size) else { return nil }
        // The AX-global top of this screen.
        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        return CGRect(
            x: screen.frame.minX + local.minX,
            y: axTop + local.minY,
            width: local.width,
            height: local.height
        )
    }
}
