import AppKit

/// Maps a ScreenRegion to a rectangle on screen. Regions are laid out RELATIVE
/// TO THE APP'S FOCUSED WINDOW (not the whole screen) so "the toolbar" means
/// the top of the Pages window, "the side panel" means that window's inspector
/// — wherever the window happens to sit. Only the macOS menu bar is
/// screen-absolute (it lives at the very top regardless of any window).
///
/// This is what lets Waylo tell apart the three "Format"s in Pages: the menu
/// bar at the absolute top of the screen (File/Edit/Format…), the toolbar at
/// the top of the window (the Format paintbrush), and the Format PANEL on the
/// right side of the window (Style/Text/colour).
enum ScreenRegionHelper {

    /// Height of the macOS menu bar in points (the app toolbar starts below it).
    static var menuBarHeight: CGFloat {
        guard let screen = NSScreen.main else { return 25 }
        let h = screen.frame.maxY - screen.visibleFrame.maxY
        return h > 1 ? h : 25
    }

    /// Apps that put their inspector / format panel on the RIGHT of the window
    /// (the iWork family and friends). Everything else — Finder, Mail, System
    /// Settings, most browsers — keeps its sidebar on the LEFT.
    private static let rightInspectorApps: Set<String> = [
        "pages", "numbers", "keynote", "preview", "music", "podcasts", "tv",
        "imovie", "garageband", "notes", "reminders"
    ]

    /// The single source of truth: a region as an AX-GLOBAL rect, relative to
    /// the target app's focused window when we know it (else the screen).
    static func axGlobalRect(for region: ScreenRegion, on screen: NSScreen) -> CGRect? {
        guard region != .fullScreen else { return nil }

        let axScreenTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        let screenAX = CGRect(x: screen.frame.minX, y: axScreenTop,
                              width: screen.frame.width, height: screen.frame.height)

        // Lay regions out inside the app window; fall back to the screen if the
        // window is unknown or implausibly small (e.g. a tiny palette).
        let win: CGRect = {
            if let w = AccessibilityReader.shared.targetFocusedWindowFrame(),
               w.width > 200, w.height > 200 { return w }
            return screenAX
        }()

        switch region {
        case .fullScreen:
            return nil
        case .menuBar:
            // Absolute screen-top — the macOS menu bar is never window-relative.
            return CGRect(x: screenAX.minX, y: axScreenTop,
                          width: screenAX.width, height: max(menuBarHeight, 30))
        case .ribbon:
            // The app's toolbar: the top strip of its window.
            return CGRect(x: win.minX, y: win.minY,
                          width: win.width, height: min(120, win.height * 0.20))
        case .statusBar:
            let h = min(60, win.height * 0.10)
            return CGRect(x: win.minX, y: win.maxY - h, width: win.width, height: h)
        case .dialog:
            // Centre of the window (a modal usually sits here).
            return win.insetBy(dx: win.width * 0.15, dy: win.height * 0.12)
        case .spreadsheet:
            // The main content area.
            return CGRect(x: win.minX, y: win.minY + win.height * 0.12,
                          width: win.width, height: win.height * 0.80)
        case .sidebar:
            // A side panel — on the correct SIDE for this app (Pages = right
            // inspector, Finder = left). This is the fix for colour/font steps
            // that used to crop the wrong (left) side in Pages.
            let panelW = win.width * 0.36
            let onRight = rightInspectorApps.contains(TargetAppTracker.shared.targetName.lowercased())
            let x = onRight ? win.maxX - panelW : win.minX
            return CGRect(x: x, y: win.minY + win.height * 0.06,
                          width: panelW, height: win.height * 0.90)
        }
    }

    /// Region rect in a SCREEN-LOCAL rect (top-left origin) for cropping the OCR
    /// image. Derived from the window-relative AX-global rect above so OCR and
    /// AX look at the same place.
    static func localRect(for region: ScreenRegion, on screen: NSScreen) -> CGRect? {
        guard let axRect = axGlobalRect(for: region, on: screen) else { return nil }
        let axScreenTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        return CGRect(x: axRect.minX - screen.frame.minX,
                      y: axRect.minY - axScreenTop,
                      width: axRect.width, height: axRect.height)
    }
}
