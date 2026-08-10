import Cocoa
import ApplicationServices

/// Reads the AXUIElement tree of the frontmost macOS application.
/// This is the macOS equivalent of Android's AccessibilityService.
/// `@unchecked Sendable`: the tree walk runs on a background queue, but the only
/// mutable state (`targetElementCache`) is written/read on the main actor, and
/// the walk itself uses only locals + thread-safe AX APIs.
final class AccessibilityReader: @unchecked Sendable {
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

    /// Per-locate cache of the target app's element tree. One `resolve()` runs
    /// several searches (anchor, label, description) that each want the SAME
    /// tree, and the screen is static during a read-only detection pass — so we
    /// read it ONCE and reuse. On a slow app (Mail) this turns three 2.5s tree
    /// walks into one. `invalidateTargetElementCache()` clears it at the start
    /// of each locate so it never goes stale across steps.
    private var targetElementCache: (pid: pid_t, elements: [AXElementInfo])?

    /// Dedicated thread for the (slow, cross-process) AX tree walk so it NEVER
    /// runs on the main thread — a huge/slow app (Mail) must not freeze the UI.
    private let axReadQueue = DispatchQueue(label: "waylo.ax.treeread", qos: .userInitiated)

    /// Clear the per-locate element cache. Called at the start of each resolve
    /// so the next step re-reads a fresh tree.
    func invalidateTargetElementCache() { targetElementCache = nil }

    /// Read the target app's element tree OFF the main thread and cache it, so
    /// the synchronous getTargetAppElements() calls in the same resolve return
    /// instantly and the UI stays responsive during the (up to 2.5s) walk. Call
    /// once at the start of each locate; it always refreshes (fresh per step).
    func prewarmTargetElements() async {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { targetElementCache = nil; return }
        let els: [AXElementInfo] = await withCheckedContinuation { cont in
            axReadQueue.async {
                cont.resume(returning: self.elements(forPID: pid, roles: Self.interactiveRoles))
            }
        }
        await MainActor.run { self.targetElementCache = (pid, els) }
    }

    /// Returns the AX element tree of the *target* app — the app the user is
    /// actually working in, not Waylo. This is what guidance should use.
    func getTargetAppElements() -> [AXElementInfo] {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return [] }
        if let c = targetElementCache, c.pid == pid { return c.elements }
        let els = elements(forPID: pid, roles: Self.interactiveRoles)
        targetElementCache = (pid, els)
        return els
    }

    /// Focused DEEP search for an element by its accessible NAME. The normal read
    /// caps at depth 14 + a time budget, so a control buried deep in a web app's
    /// DOM — Gmail's compose-toolbar paperclip, whose aria-label is "Attach
    /// files" — is never collected, even though the browser exposes that name for
    /// free. When we KNOW the name (a cached working label, or the planner's own
    /// label), this walks deeper (≤28) but prunes hard to elements whose label
    /// actually contains that name, so it stays cheap even in a huge tree. This is
    /// the free/private/pixel-exact path for web icons — far more reliable than
    /// naming a 30px glyph with vision. Off the main thread; returns the smallest
    /// clickable match inside `restrictRect`, or nil.
    private static let deepStopWords: Set<String> =
        ["the", "a", "an", "to", "of", "in", "on", "and", "or", "for", "icon", "button", "click"]
    private static let deepClickableRoles: Set<String> =
        ["AXButton", "AXMenuItem", "AXCheckBox", "AXLink", "AXRadioButton",
         "AXImage", "AXMenuButton", "AXPopUpButton"]

    func deepFindByName(_ name: String, restrictRect: CGRect? = nil) async -> AXElementInfo? {
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !Self.deepStopWords.contains($0) }
        guard !words.isEmpty else { return nil }
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return nil }
        return await withCheckedContinuation { cont in
            axReadQueue.async {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.5)
                var hits: [AXElementInfo] = []
                let deadline = Date().addingTimeInterval(0.9)
                self.deepCollectByName(app, depth: 0, words: words, restrict: restrictRect,
                                       results: &hits, deadline: deadline)
                // Prefer the smallest CLICKABLE match — the icon button itself, not
                // a big container that happens to carry the same accessible name.
                func boxArea(_ e: AXElementInfo) -> CGFloat { e.frame.width * e.frame.height }
                let best = hits.filter { Self.deepClickableRoles.contains($0.role) }
                                .min(by: { boxArea($0) < boxArea($1) })
                    ?? hits.min(by: { boxArea($0) < boxArea($1) })
                if let b = best {
                    DebugLogger.log("AX", "DEEP name search '\(name)' → \(b.role) '\(b.title.isEmpty ? b.description : b.title)' at (\(Int(b.center.x)),\(Int(b.center.y)))")
                } else {
                    DebugLogger.log("AX", "DEEP name search '\(name)' → no match (walked deep, name not in tree)")
                }
                cont.resume(returning: best)
            }
        }
    }

    private func deepCollectByName(_ element: AXUIElement, depth: Int, words: [String],
                                   restrict: CGRect?, results: inout [AXElementInfo], deadline: Date) {
        guard depth < 28, results.count < 40, Date() < deadline else { return }
        let title = copyStringAttribute(element, kAXTitleAttribute)
        let desc = copyStringAttribute(element, kAXDescriptionAttribute)
        let help = copyStringAttribute(element, kAXHelpAttribute)
        let identRaw = copyStringAttribute(element, "AXIdentifier")
        let hay = "\(title) \(desc) \(help) \(identRaw)".lowercased()
        if !hay.trimmingCharacters(in: .whitespaces).isEmpty, words.allSatisfy({ hay.contains($0) }) {
            let frame = copyFrame(element)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if frame.width > 1, frame.height > 1,
               (restrict?.insetBy(dx: -8, dy: -8).contains(center) ?? true) {
                results.append(AXElementInfo(
                    role: copyStringAttribute(element, kAXRoleAttribute),
                    title: title, description: desc, helpText: help,
                    value: copyStringAttribute(element, kAXValueAttribute),
                    frame: frame, center: center, axElement: element,
                    identifier: AXElementInfo.meaningfulIdentifier(identRaw)))
            }
        }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if let arr = children as? [AXUIElement] {
            for child in arr {
                if Date() >= deadline { return }
                deepCollectByName(child, depth: depth + 1, words: words,
                                  restrict: restrict, results: &results, deadline: deadline)
            }
        }
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
        // CAP EACH cross-process AX call. The default has effectively no timeout,
        // so ONE busy/unresponsive app (Mail with a big mailbox) can hang a
        // single AXUIElementCopyAttributeValue for seconds — and the walk makes
        // thousands, freezing the MAIN THREAD (and the whole app: the panel
        // wouldn't open, Esc was laggy) for ~20s. 0.5s per call keeps a hung app
        // from stalling us; a responsive app answers in <5ms so this is a no-op.
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var elements: [AXElementInfo] = []
        // PRIORITY PASS: collect the TOOLBAR(s) first. On a huge/slow app (Mail)
        // the budgeted full walk is depth-first and spends its whole budget on
        // the message list before ever reaching the toolbar — so named toolbar
        // icons (Archive, Reply, Flag…) were never seen. The toolbar is tiny, so
        // grabbing it up front guarantees those buttons are always available.
        collectToolbars(appElement, roles: roles, results: &elements)
        // Plus a total wall-clock budget so even many slow-but-not-hung calls
        // can't blow past a couple of seconds — bail with whatever we have.
        let deadline = Date().addingTimeInterval(2.5)
        traverseElement(appElement, depth: 0, roles: roles, results: &elements, deadline: deadline)
        if Date() >= deadline {
            DebugLogger.log("AX", "tree walk hit the 2.5s budget — returning \(elements.count) elements (app slow/huge)")
        }
        // Dedup: a toolbar button may be collected by both passes. Same role at
        // the same frame = the same element.
        var seen = Set<String>()
        elements = elements.filter { e in
            let k = "\(e.role)|\(Int(e.frame.minX))|\(Int(e.frame.minY))|\(Int(e.frame.width))|\(Int(e.frame.height))"
            return seen.insert(k).inserted
        }
        return elements
    }

    /// Find the target app's toolbar(s) — a small, high-value subtree that holds
    /// the visible action icons — and collect their buttons FIRST, before the
    /// budgeted full walk that a big app can exhaust on its content list.
    private func collectToolbars(_ app: AXUIElement, roles: Set<String>, results: inout [AXElementInfo]) {
        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef)
        let windows = (winsRef as? [AXUIElement]) ?? []
        for win in windows {
            findToolbars(in: win, depth: 0, roles: roles, results: &results)
        }
    }

    /// Shallow search (≤5 deep) for AXToolbar under `el`; each found toolbar is
    /// traversed fully (it's small) with a tight 1s budget of its own.
    private func findToolbars(in el: AXUIElement, depth: Int, roles: Set<String>, results: inout [AXElementInfo]) {
        guard depth < 5 else { return }
        if copyStringAttribute(el, kAXRoleAttribute) == "AXToolbar" {
            traverseElement(el, depth: 0, roles: roles, results: &results,
                            deadline: Date().addingTimeInterval(1.0))
            return
        }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef)
        for child in (childrenRef as? [AXUIElement]) ?? [] {
            findToolbars(in: child, depth: depth + 1, roles: roles, results: &results)
        }
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
        guard let window = focusedTargetWindow() else { return nil }
        let frame = copyFrame(window)
        return frame.width > 1 && frame.height > 1 ? frame : nil
    }

    /// The target app's focused window (else its main window), or nil.
    private func focusedTargetWindow() -> AXUIElement? {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return nil }
        let app = AXUIElementCreateApplication(pid)

        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) != .success || winRef == nil {
            AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &winRef)
        }
        guard let winRef = winRef else { return nil }
        return (winRef as! AXUIElement)
    }

    /// Frame (AX coords) of the web-page CONTENT area of the target browser's
    /// focused window. Exact when the engine exposes an AXWebArea; otherwise
    /// the window frame minus the top chrome strip (tab bar + toolbar). In the
    /// fallback case the page isn't in the AX tree AT ALL, so everything the
    /// tree can see above the strip is chrome and nothing real gets excluded.
    /// Used by CoordinateResolver to keep web-content steps from matching
    /// browser chrome (tab titles, bookmarks, the address bar).
    func targetWebContentFrame() -> CGRect? {
        guard let window = focusedTargetWindow() else { return nil }
        if let web = largestWebArea(in: window, depth: 0), web.width > 200, web.height > 150 {
            DebugLogger.log("AX", "AXWebArea found \(Int(web.width))x\(Int(web.height))")
            return web
        }
        let frame = copyFrame(window)
        guard frame.width > 1, frame.height > 1 else { return nil }
        let chromeStrip: CGFloat = 80
        DebugLogger.log("AX", "no AXWebArea — approximating web content as window minus \(Int(chromeStrip))pt chrome strip")
        return CGRect(x: frame.minX, y: frame.minY + chromeStrip,
                      width: frame.width, height: max(0, frame.height - chromeStrip))
    }

    /// The URL of the frontmost browser's focused web page. Chrome/Safari expose
    /// it on the AXWebArea as "AXURL". This tells the planner WHICH site the user
    /// is already on (mail.google.com, docs.google.com…) so it doesn't add "open
    /// a tab / search for the site" steps when they're already there. nil for
    /// non-browsers or when no URL is exposed.
    func targetWebURL() -> String? {
        guard TargetAppTracker.shared.isBrowser, let window = focusedTargetWindow() else { return nil }
        guard let web = firstWebAreaElement(in: window, depth: 0) else { return nil }
        var urlRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(web, "AXURL" as CFString, &urlRef) == .success,
              let ref = urlRef else { return nil }
        // AXURL usually bridges to NSURL→URL; occasionally it's a plain string.
        if let url = ref as? URL { return url.absoluteString }
        if let s = ref as? String { return s }
        return nil
    }

    /// First AXWebArea ELEMENT under `element` (sibling of largestWebArea, which
    /// returns only a frame). Does not descend into a web area.
    private func firstWebAreaElement(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 12 else { return nil }
        if copyStringAttribute(element, kAXRoleAttribute) == "AXWebArea" { return element }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        for child in (childrenRef as? [AXUIElement]) ?? [] {
            if let hit = firstWebAreaElement(in: child, depth: depth + 1) { return hit }
        }
        return nil
    }

    /// The largest AXWebArea frame under `element` (browsers can host several —
    /// the page, DevTools, extension popups). Does not descend INTO a web area.
    private func largestWebArea(in element: AXUIElement, depth: Int) -> CGRect? {
        guard depth < 12 else { return nil }
        if copyStringAttribute(element, kAXRoleAttribute) == "AXWebArea" {
            let f = copyFrame(element)
            return (f.width > 1 && f.height > 1) ? f : nil
        }
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        var best: CGRect?
        for child in children {
            if let f = largestWebArea(in: child, depth: depth + 1),
               best == nil || f.width * f.height > best!.width * best!.height {
                best = f
            }
        }
        return best
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
    /// `deadline` is a hard wall-clock budget — a huge/slow tree (Mail) must
    /// never freeze the main thread, so we bail with a partial result.
    private func traverseElement(_ element: AXUIElement, depth: Int, roles: Set<String>,
                                 results: inout [AXElementInfo], deadline: Date) {
        guard depth < 14 else { return } // Max depth to avoid runaway recursion
        guard results.count < Self.maxElements else { return }
        guard Date() < deadline else { return }  // out of time — return what we have

        let roleStr = copyStringAttribute(element, kAXRoleAttribute)
        let subroleStr = copyStringAttribute(element, kAXSubroleAttribute)
        let titleStr = copyStringAttribute(element, kAXTitleAttribute)
        let descStr = copyStringAttribute(element, kAXDescriptionAttribute)
        let helpStr = copyStringAttribute(element, kAXHelpAttribute)
        let valueStr = copyStringAttribute(element, kAXValueAttribute)
        // Developer-assigned identifier ("attachButton") — frequently the only
        // name a textless icon carries. Junk (UUIDs, _NS internals) filtered.
        let identStr = AXElementInfo.meaningfulIdentifier(
            copyStringAttribute(element, "AXIdentifier"))

        let frame = copyFrame(element)
        let center = CGPoint(x: frame.midX, y: frame.midY)

        let isInteractive = roles.contains(roleStr)
        let hasLabel = !titleStr.isEmpty || !descStr.isEmpty || !helpStr.isEmpty
            || !valueStr.isEmpty || !identStr.isEmpty
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
                axElement: element,
                identifier: identStr
            ))
        }

        // Recurse into children.
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if let childArray = children as? [AXUIElement] {
            for child in childArray {
                if Date() >= deadline { return }   // stop mid-loop on a wide/slow node
                traverseElement(child, depth: depth + 1, roles: roles, results: &results, deadline: deadline)
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
// AXUIElement is a thread-safe CFType and every field is immutable after
// construction, so an AXElementInfo is safe to hand from the background AX-read
// thread back to the main actor.
struct AXElementInfo: @unchecked Sendable {
    let role: String
    let title: String
    let description: String
    let helpText: String
    let value: String
    let frame: CGRect
    let center: CGPoint
    let axElement: AXUIElement
    /// Developer-assigned AXIdentifier ("attachButton", "sendMessage") —
    /// often the ONLY name a textless icon has. Humanized for matching.
    var identifier: String = ""

    /// All text fields combined — used for scoring.
    var allText: String {
        [role, title, description, helpText, value, Self.humanizeIdentifier(identifier)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// "attachFileButton" / "attach-file_button" → "attach file button".
    static func humanizeIdentifier(_ id: String) -> String {
        guard !id.isEmpty else { return "" }
        var s = id.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2",
                                        options: .regularExpression)
        s = s.replacingOccurrences(of: #"[-_.:]+"#, with: " ", options: .regularExpression)
        return s.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Filters out machine junk (UUIDs, long hex, _NS internals) so only
    /// human-meaningful identifiers are used for matching.
    static func meaningfulIdentifier(_ id: String) -> String {
        let t = id.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 48,
              t.rangeOfCharacter(from: .letters) != nil,
              !t.hasPrefix("_NS"), !t.hasPrefix("NSAuto"),
              t.range(of: #"^[0-9a-fA-F-]{16,}$"#, options: .regularExpression) == nil
        else { return "" }
        return t
    }
}
