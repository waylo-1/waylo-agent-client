import Cocoa
import ApplicationServices

/// Reads the AXUIElement tree of the frontmost macOS application.
/// This is the macOS equivalent of Android's AccessibilityService.
final class AccessibilityReader {
    static let shared = AccessibilityReader()

    private init() {}

    /// Roles we consider "interactive" and worth surfacing to the finder.
    /// Includes AXStaticText / AXRow / AXCell because AX-hostile apps (notably
    /// System Settings) expose sidebar/list items as static text inside rows
    /// rather than as buttons.
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXTextField", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXTab", "AXCell", "AXLink", "AXMenuButton", "AXToolbarButton",
        "AXMenuBarItem", "AXStaticText", "AXRow"
    ]

    /// Subroles to ALWAYS skip — window chrome the user should never be pointed
    /// at (the red/yellow/green traffic-light buttons, full-screen control).
    private static let excludedSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"
    ]

    /// Broader role set for system UI (Dock, menu-bar extras), where targets are
    /// icons exposed as AXDockItem / AXImage with a title or description.
    private static let systemRoles: Set<String> = [
        "AXDockItem", "AXButton", "AXMenuBarItem", "AXImage",
        "AXMenuItem", "AXStaticText"
    ]

    /// Bundle IDs of system processes that own UI outside the frontmost app
    /// (Dock icons, menu-bar extras). These never become the "active app" so
    /// they must be read explicitly.
    private static let systemUIBundleIDs = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.systemuiserver"
    ]

    /// Returns the AX element tree of the frontmost app as a flat array.
    /// (Used by the dev-tools logger.)
    func getFrontmostAppElements() -> [AXElementInfo] {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return [] }
        return elements(forPID: frontApp.processIdentifier, roles: Self.interactiveRoles)
    }

    /// Returns the AX element tree of the *target* app — the app the user is
    /// actually working in, not Waylo. This is what guidance should use.
    func getTargetAppElements() -> [AXElementInfo] {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return [] }
        return elements(forPID: pid, roles: Self.interactiveRoles)
    }

    /// Returns labelled elements from system UI processes (Dock, menu-bar extras).
    /// These own things like the Trash / app icons in the Dock, which never
    /// appear in the frontmost app's AX tree.
    func getSystemUIElements() -> [AXElementInfo] {
        var result: [AXElementInfo] = []
        for bundleID in Self.systemUIBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                result += elements(forPID: app.processIdentifier, roles: Self.systemRoles)
            }
        }
        DebugLogger.log("AX", "system UI elements=\(result.count)")
        return result
    }

    private func elements(forPID pid: pid_t, roles: Set<String>) -> [AXElementInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        var elements: [AXElementInfo] = []
        traverseElement(appElement, depth: 0, roles: roles, results: &elements)
        return elements
    }

    /// True if the target app currently shows a real scrollable area — used to
    /// decide whether a "scroll to find it" prompt makes sense (it does NOT for
    /// menus, the menu bar, or small dialogs that can't scroll).
    func targetHasScrollArea() -> Bool {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return false }
        let found = containsScrollArea(AXUIElementCreateApplication(pid), depth: 0)
        DebugLogger.log("AX", "targetHasScrollArea=\(found)")
        return found
    }

    private func containsScrollArea(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth < 12 else { return false }
        let role = copyStringAttribute(element, kAXRoleAttribute)
        if role == "AXScrollArea" || role == "AXScrollBar" {
            let f = copyFrame(element)
            if f.width > 80 && f.height > 120 { return true } // a real, sizeable scroll area
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if let arr = children as? [AXUIElement] {
            for child in arr where containsScrollArea(child, depth: depth + 1) { return true }
        }
        return false
    }

    /// Frame (AX/top-left coords) of the target app's focused window, else its
    /// main window. Used to validate that a "dialog"-region hit lands inside the
    /// active window rather than somewhere else on screen.
    func targetFocusedWindowFrame() -> CGRect? {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return nil }
        let app = AXUIElementCreateApplication(pid)

        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) != .success || winRef == nil {
            AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &winRef)
        }
        guard let winRef = winRef else { return nil }
        let frame = copyFrame(winRef as! AXUIElement)
        return frame.width > 1 && frame.height > 1 ? frame : nil
    }

    /// Frame (AX coords) of a modal surface in the target app — a sheet,
    /// dialog, or system alert — if one is currently up. Used to hard-restrict
    /// detection to the modal's contents (a confirmation's "Empty Bin" button
    /// vs the toolbar "Empty" behind it). Returns nil when there is no modal so
    /// menu-bar / dropdown targets aren't filtered.
    ///
    /// Detects BOTH styles: a sheet attached to a window (via kAXSheetsAttribute
    /// — how Finder's "Empty the Trash?" confirmation appears) and a standalone
    /// dialog window (subrole AXDialog / AXSystemDialog).
    func targetFocusedDialogFrame() -> CGRect? {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return nil }
        let app = AXUIElementCreateApplication(pid)

        // Any window's attached sheet wins first (it's modal over its parent).
        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef)
        let windows = (winsRef as? [AXUIElement]) ?? []
        for win in windows {
            var sheetsRef: CFTypeRef?
            // No kAXSheetsAttribute constant in the SDK — the attribute is "AXSheets".
            AXUIElementCopyAttributeValue(win, "AXSheets" as CFString, &sheetsRef)
            if let sheet = (sheetsRef as? [AXUIElement])?.first {
                let f = copyFrame(sheet)
                if f.width > 1, f.height > 1 {
                    DebugLogger.log("AX", "modal sheet detected \(Int(f.width))x\(Int(f.height))")
                    return f
                }
            }
        }

        // Else a standalone dialog window (focused, else any).
        var focusedRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef)
        let candidates = [focusedRef].compactMap { $0 as! AXUIElement? } + windows
        for win in candidates {
            let role = copyStringAttribute(win, kAXRoleAttribute)
            let subrole = copyStringAttribute(win, kAXSubroleAttribute)
            if role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" || subrole == "AXSheet" {
                let f = copyFrame(win)
                if f.width > 1, f.height > 1 {
                    DebugLogger.log("AX", "modal dialog detected \(Int(f.width))x\(Int(f.height))")
                    return f
                }
            }
        }
        return nil
    }

    /// Every window of the target app with its frame (AX coords) and subrole.
    /// This is how new windows are identified REGARDLESS of app style: whether
    /// an app opens a standard window (AXStandardWindow), a dialog (AXDialog),
    /// a sheet, or a floating panel, it always appears in kAXWindowsAttribute
    /// with an authoritative frame. Diffing this list before/after a click
    /// reveals "the window that just opened" and its exact borders.
    func targetWindowList() -> [(element: AXUIElement, frame: CGRect, subrole: String)] {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return [] }
        let app = AXUIElementCreateApplication(pid)

        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef)
        guard let wins = winsRef as? [AXUIElement] else { return [] }
        return wins.compactMap { w in
            let f = copyFrame(w)
            guard f.width > 40, f.height > 40 else { return nil }
            return (w, f, copyStringAttribute(w, kAXSubroleAttribute))
        }
    }

    /// Hard cap on collected elements. Huge trees (Xcode, browsers with many
    /// tabs) can hold tens of thousands of nodes; walking them all stalls
    /// every locate for seconds and floods the scorer with noise. The first
    /// ~800 interactive elements cover everything visible on one screen.
    private static let maxElements = 800

    /// Recursively walks the AX tree, collecting interactive elements.
    private func traverseElement(_ element: AXUIElement, depth: Int, roles: Set<String>, results: inout [AXElementInfo]) {
        guard depth < 14 else { return } // Max depth to avoid runaway recursion
        guard results.count < Self.maxElements else { return }

        let roleStr = copyStringAttribute(element, kAXRoleAttribute)
        let subroleStr = copyStringAttribute(element, kAXSubroleAttribute)
        let titleStr = copyStringAttribute(element, kAXTitleAttribute)
        let descStr = copyStringAttribute(element, kAXDescriptionAttribute)
        let helpStr = copyStringAttribute(element, kAXHelpAttribute)
        let valueStr = copyStringAttribute(element, kAXValueAttribute)

        let frame = copyFrame(element)
        let center = CGPoint(x: frame.midX, y: frame.midY)

        let isInteractive = roles.contains(roleStr)
        let hasLabel = !titleStr.isEmpty || !descStr.isEmpty || !helpStr.isEmpty || !valueStr.isEmpty
        let isWindowChrome = Self.excludedSubroles.contains(subroleStr)

        // AXStaticText is included for AX-hostile apps (System Settings sidebar),
        // but body/paragraph text would flood candidates and slow things down —
        // only keep SHORT, label-like static text.
        var staticTextTooLong = false
        if roleStr == "AXStaticText" {
            let label = titleStr.isEmpty ? valueStr : titleStr
            staticTextTooLong = label.count > 40
        }

        if isInteractive && hasLabel && !isWindowChrome && !staticTextTooLong {
            results.append(AXElementInfo(
                role: roleStr,
                title: titleStr,
                description: descStr,
                helpText: helpStr,
                value: valueStr,
                frame: frame,
                center: center,
                axElement: element
            ))
        }

        // Recurse into children.
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if let childArray = children as? [AXUIElement] {
            for child in childArray {
                traverseElement(child, depth: depth + 1, roles: roles, results: &results)
            }
        }
    }

    // MARK: - Attribute helpers

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return "" }
        return (value as? String) ?? ""
    }

    private func copyFrame(_ element: AXUIElement) -> CGRect {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)

        var cgPosition = CGPoint.zero
        var cgSize = CGSize.zero
        if let pos = positionRef {
            AXValueGetValue(pos as! AXValue, .cgPoint, &cgPosition)
        }
        if let sz = sizeRef {
            AXValueGetValue(sz as! AXValue, .cgSize, &cgSize)
        }
        return CGRect(origin: cgPosition, size: cgSize)
    }
}

/// Data model for a single accessibility element.
struct AXElementInfo {
    let role: String
    let title: String
    let description: String
    let helpText: String
    let value: String
    let frame: CGRect
    let center: CGPoint
    let axElement: AXUIElement

    /// All text fields combined — used for scoring.
    var allText: String {
        [role, title, description, helpText, value]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
