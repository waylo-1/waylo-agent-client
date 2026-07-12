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
        "AXButton", "AXMenuItem", "AXTextField", "AXTextArea", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXTab", "AXCell", "AXLink", "AXMenuButton", "AXToolbarButton",
        "AXMenuBarItem", "AXStaticText", "AXRow",
        // Icon-only controls (paperclip, +, gear, share) very often render as
        // AXImage carrying an AXDescription/AXHelp — "textless" to the eye but
        // NAMED in the tree. Extraction still requires a label, so decorative
        // images are dropped; only meaningful icons surface.
        "AXImage"
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

    /// The Dock's on-screen frame (AX coords), or nil. Used to hard-reject
    /// vision detections for "… in the Dock" targets that land elsewhere (a
    /// desktop folder icon once won a "Trash icon in the Dock" step).
    func dockFrame() -> CGRect? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        // The Dock's "list" child is the icon strip itself.
        for child in children where copyStringAttribute(child, kAXRoleAttribute) == "AXList" {
            let frame = copyFrame(child)
            if frame.width > 60, frame.height > 20 { return frame }
        }
        return nil
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

    /// The interactive element under an AX-global point — hit-testing via the
    /// system-wide AX element. Walks UP from the deepest hit to the nearest
    /// ancestor with a usable label, so clicking a button's inner text still
    /// returns the button. Used to LEARN from user clicks: when the user
    /// clicks somewhere other than where Waylo pointed and the screen then
    /// changes, that element was the real target.
    func elementAt(axPoint: CGPoint) -> AXElementInfo? {
        let system = AXUIElementCreateSystemWide()
        var ref: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(axPoint.x), Float(axPoint.y), &ref) == .success,
              var element = ref else { return nil }

        for _ in 0..<4 {
            let role = copyStringAttribute(element, kAXRoleAttribute)
            let title = copyStringAttribute(element, kAXTitleAttribute)
            let desc = copyStringAttribute(element, kAXDescriptionAttribute)
            let value = copyStringAttribute(element, kAXValueAttribute)
            if !title.isEmpty || !desc.isEmpty || (!value.isEmpty && role == "AXStaticText") {
                let frame = copyFrame(element)
                return AXElementInfo(
                    role: role, title: title, description: desc,
                    helpText: copyStringAttribute(element, kAXHelpAttribute),
                    value: value, frame: frame,
                    center: CGPoint(x: frame.midX, y: frame.midY),
                    axElement: element
                )
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            element = parent as! AXUIElement
        }
        return nil
    }

    /// Whether an element is an ON/selected toggle (radio button, checkbox,
    /// tab, or a toolbar button that acts as a toggle). Returns nil when the
    /// element isn't a toggle or its state is unreadable. Used to skip a
    /// "click to open/show X" step when X is ALREADY open — clicking an
    /// already-selected toggle turns it back OFF (Pages' Format button closed
    /// the panel it was supposed to open).
    func isToggleOn(_ element: AXUIElement) -> Bool? {
        let role = copyStringAttribute(element, kAXRoleAttribute)
        let toggleRoles: Set<String> = ["AXRadioButton", "AXCheckBox", "AXToggle", "AXTab"]
        // A plain AXButton can also toggle (e.g. an inspector button) — only
        // trust it when it actually exposes a 0/1 value.
        let isToggleRole = toggleRoles.contains(role)

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef else { return isToggleRole ? nil : nil }

        if let n = value as? Int { return n != 0 }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        return nil
    }

    /// A cheap fingerprint of the target app's visible state: app name, window
    /// count, focused-window title, and whether a sheet/dialog is up. Comparing
    /// it before/after an action answers "did that click visibly DO anything?"
    /// without a screenshot. (Deliberately coarse — content edits inside a
    /// window don't change it, which is fine: it's a navigation signal.)
    func targetScreenSignature() -> String {
        let windows = targetWindowList()
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        var focusedTitle = ""
        if let pid = pid {
            let app = AXUIElementCreateApplication(pid)
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               let winRef = winRef {
                focusedTitle = copyStringAttribute(winRef as! AXUIElement, kAXTitleAttribute)
            }
        }
        let sheet = targetFocusedDialogFrame() != nil
        // Opening a menu is a real screen change but adds no window — without
        // this, clicking "Insert" (menu drops down) looked like "nothing
        // happened" to the verification signal.
        let menu = targetHasOpenMenu()
        return "\(TargetAppTracker.shared.targetName)|\(windows.count)|\(focusedTitle)|\(sheet)|\(menu)"
    }

    /// True when the target app currently has an open menu (a menu-bar menu
    /// dropped down, or a context menu). Cheap: only inspects the menu bar's
    /// immediate children for a selected item, not the whole tree.
    func targetHasOpenMenu() -> Bool {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return false }
        let app = AXUIElementCreateApplication(pid)

        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return false }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef)
        guard let items = childrenRef as? [AXUIElement] else { return false }

        for item in items {
            // An OPEN menu shows up as a child AXMenu of the menu-bar item.
            // (kAXSelectedAttribute alone misses it — that's why clicking
            // "Format" logged "screen unchanged" while its menu was open.)
            var childrenRef: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &childrenRef)
            if let menus = childrenRef as? [AXUIElement],
               menus.contains(where: { copyStringAttribute($0, kAXRoleAttribute) == "AXMenu" }) {
                return true
            }
            var selectedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXSelectedAttribute as CFString, &selectedRef) == .success,
               let selected = selectedRef as? Bool, selected {
                return true
            }
        }
        return false
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
