import AppKit

/// Executes agent-mode actions through the most reliable channel available:
/// AXPress on a live element handle (no coordinates), AXValue for typing,
/// the AX menu tree for menu paths (menu items are pressable WITHOUT opening
/// the menu or knowing any coordinates), and CGEvents for keys/scroll.
/// Synthetic clicks at a point are the last resort, not the default.
enum AgentExecutor {

    // MARK: - Press

    /// AXPress the element; falls back to a synthetic click at its centre.
    @discardableResult
    static func press(_ info: AXElementInfo) -> Bool {
        if AXUIElementPerformAction(info.axElement, kAXPressAction as CFString) == .success {
            DebugLogger.log("AGENT", "AXPress '\(info.title.isEmpty ? info.description : info.title)' OK")
            return true
        }
        DebugLogger.log("AGENT", "AXPress failed → synthetic click at (\(Int(info.center.x)),\(Int(info.center.y)))")
        return syntheticClick(at: info.center)
    }

    @discardableResult
    static func syntheticClick(at axPoint: CGPoint) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: axPoint, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: axPoint, mouseButton: .left) else { return false }
        down.post(tap: .cghidEventTap)
        usleep(60_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Type

    /// Roles that legitimately accept typed text.
    private static let typableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"
    ]

    /// Role of the element that currently has keyboard focus (system-wide).
    static func focusedElementRole() -> String {
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let el = ref else { return "" }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &roleRef)
        return roleRef as? String ?? ""
    }

    /// Types text. With a target field: focus it, set AXValue directly (exact,
    /// instant, no keystroke race). Without one: VERIFY a text control actually
    /// has focus before synthesizing keystrokes — blind typing lands anywhere
    /// (a document, a menu search…) and is worse than failing loudly so the
    /// model presses the field first.
    @discardableResult
    static func type(_ text: String, into info: AXElementInfo?, submit: Bool) -> Bool {
        var ok = false
        if let info {
            AXUIElementSetAttributeValue(info.axElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            // Some fields need a click to accept focus.
            if AXUIElementSetAttributeValue(info.axElement, kAXValueAttribute as CFString, text as CFString) == .success {
                ok = true
                DebugLogger.log("AGENT", "AXValue set on field (\(text.count) chars)")
            } else {
                _ = press(info)
                usleep(150_000)
            }
        }
        if !ok {
            if info == nil {
                let role = focusedElementRole()
                guard typableRoles.contains(role) else {
                    DebugLogger.log("AGENT", "type REFUSED — focused element is '\(role.isEmpty ? "unknown" : role)', not a text field")
                    return false
                }
            }
            typeKeystrokes(text)
            ok = true
        }
        if submit {
            usleep(120_000)
            _ = key(combo: "return")
        }
        return ok
    }

    /// Sends the string as unicode keystrokes (works in any focused control).
    private static func typeKeystrokes(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for ch in text.unicodeScalars {
            var utf16 = Array(String(ch).utf16)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                usleep(12_000)
            }
        }
        DebugLogger.log("AGENT", "typed \(text.count) chars via keystrokes")
    }

    // MARK: - Keyboard shortcuts

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "comma": 43, "period": 47, "slash": 44, "minus": 27, "equal": 24,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    /// Presses a combo like "cmd+shift+4" or "return".
    @discardableResult
    static func key(combo: String) -> Bool {
        var flags: CGEventFlags = []
        var keyName = ""
        for part in combo.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: keyName = part
            }
        }
        guard let code = keyCodes[keyName] else {
            DebugLogger.log("AGENT", "unknown key '\(keyName)' in combo '\(combo)'")
            return false
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(40_000)
        up.post(tap: .cghidEventTap)
        DebugLogger.log("AGENT", "key \(combo)")
        return true
    }

    // MARK: - Menu paths (the most reliable channel of all)

    /// Invokes a menu-bar item by path, e.g. ["File", "Export…"]. The AX menu
    /// tree is fully readable while CLOSED, and AXPress on the leaf item
    /// executes it — no coordinates, no opening menus, layout-proof. Titles
    /// are matched case-insensitively, ignoring a trailing ellipsis.
    @discardableResult
    static func menu(path: [String]) -> Bool {
        guard !path.isEmpty, let pid = TargetAppTracker.shared.targetPID else { return false }
        let app = AXUIElementCreateApplication(pid)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barRef) == .success,
              let bar = barRef else {
            DebugLogger.log("AGENT", "menu: no menu bar for pid \(pid)")
            return false
        }
        var current = bar as! AXUIElement
        for (depth, component) in path.enumerated() {
            guard let next = childMenuItem(of: current, titled: component) else {
                DebugLogger.log("AGENT", "menu: '\(component)' not found at depth \(depth) of \(path.joined(separator: " > "))")
                return false
            }
            current = next
        }
        let ok = AXUIElementPerformAction(current, kAXPressAction as CFString) == .success
        DebugLogger.log("AGENT", "menu \(path.joined(separator: " > ")) → \(ok ? "OK" : "press failed")")
        return ok
    }

    /// Finds a child menu item by title, descending through wrapper AXMenus.
    private static func childMenuItem(of element: AXUIElement, titled wanted: String) -> AXUIElement? {
        let target = normalizeMenuTitle(wanted)
        var queue: [AXUIElement] = [element]
        var depth = 0
        while !queue.isEmpty, depth < 3 {   // unwrap AXMenu containers between levels
            var nextQueue: [AXUIElement] = []
            for el in queue {
                var childrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                      let children = childrenRef as? [AXUIElement] else { continue }
                for child in children {
                    var roleRef: CFTypeRef?, titleRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
                    AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
                    let role = roleRef as? String ?? ""
                    let title = titleRef as? String ?? ""
                    if role == "AXMenu" {
                        nextQueue.append(child)   // transparent container — look inside
                    } else if normalizeMenuTitle(title) == target {
                        return child
                    }
                }
            }
            queue = nextQueue
            depth += 1
        }
        return nil
    }

    private static func normalizeMenuTitle(_ s: String) -> String {
        s.replacingOccurrences(of: "…", with: "")
         .replacingOccurrences(of: "...", with: "")
         .trimmingCharacters(in: .whitespaces)
         .lowercased()
    }

    // MARK: - Computer-use actions (0-999 grid → real events)

    /// Executes a computer-use action: the model returns 0-999 grid coordinates
    /// on the captured screen; convert via the screen's frame and click/type
    /// there. The dot flashes at each click point so the user SEES the action.
    /// Shared by agent mode and teach mode's last-resort layer.
    @MainActor
    static func computerAction(_ a: WayloAPIClient.AgentAction, on screen: NSScreen) -> Bool {
        func axPoint(_ gx: Int, _ gy: Int) -> CGPoint {
            let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
            return CGPoint(x: screen.frame.minX + CGFloat(gx) / 1000.0 * screen.frame.width,
                           y: axTop + CGFloat(gy) / 1000.0 * screen.frame.height)
        }
        func flash(_ p: CGPoint) {
            OverlayWindowController.shared.showDot(at: p, caption: "")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if !GuidanceEngine.shared.isRunning { OverlayWindowController.shared.hideDot() }
            }
        }
        switch a.act {
        case "press_at":
            guard let x = a.x, let y = a.y else { return false }
            let p = axPoint(x, y)
            flash(p)
            usleep(250_000)   // let the flash appear before the click
            return syntheticClick(at: p)
        case "type_at":
            guard let x = a.x, let y = a.y else { return false }
            let p = axPoint(x, y)
            flash(p)
            usleep(250_000)
            _ = syntheticClick(at: p)
            usleep(200_000)
            return type(a.text ?? "", into: nil, submit: a.submit ?? false)
        case "type":
            return type(a.text ?? "", into: nil, submit: a.submit ?? false)
        case "key":
            return key(combo: a.combo ?? "")
        case "menu":
            return menu(path: a.path ?? [])
        case "scroll":
            return scroll(direction: a.direction ?? "down")
        case "wait":
            return true
        default:
            return false
        }
    }

    // MARK: - Scroll

    @discardableResult
    static func scroll(direction: String) -> Bool {
        let amount: Int32 = direction.lowercased() == "up" ? 6 : -6
        // Scroll at the centre of the target window so the right view gets it.
        let center: CGPoint
        if let frame = AccessibilityReader.shared.targetFocusedWindowFrame() {
            center = CGPoint(x: frame.midX, y: frame.midY)
        } else {
            center = CGPoint(x: NSScreen.main.map { $0.frame.midX } ?? 700, y: 400)
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: center, mouseButton: .left),
              let ev = CGEvent(scrollWheelEvent2Source: source, units: .line,
                               wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0) else { return false }
        move.post(tap: .cghidEventTap)
        usleep(30_000)
        ev.location = center
        ev.post(tap: .cghidEventTap)
        DebugLogger.log("AGENT", "scroll \(direction)")
        return true
    }
}
