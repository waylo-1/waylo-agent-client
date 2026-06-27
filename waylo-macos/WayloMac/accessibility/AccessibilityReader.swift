import Cocoa
import ApplicationServices

/// Reads the AXUIElement tree of the frontmost macOS application.
/// This is the macOS equivalent of Android's AccessibilityService.
final class AccessibilityReader {
    static let shared = AccessibilityReader()

    private init() {}

    /// Roles we consider "interactive" and worth surfacing to the finder.
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXTextField", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox",
        "AXTab", "AXCell", "AXLink", "AXMenuButton", "AXToolbarButton"
    ]

    /// Returns the AX element tree of the frontmost app as a flat array.
    /// (Used by the dev-tools logger.)
    func getFrontmostAppElements() -> [AXElementInfo] {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return [] }
        return elements(forPID: frontApp.processIdentifier)
    }

    /// Returns the AX element tree of the *target* app — the app the user is
    /// actually working in, not Waylo. This is what guidance should use.
    func getTargetAppElements() -> [AXElementInfo] {
        let pid = TargetAppTracker.shared.targetPID
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid = pid else { return [] }
        return elements(forPID: pid)
    }

    private func elements(forPID pid: pid_t) -> [AXElementInfo] {
        let appElement = AXUIElementCreateApplication(pid)
        var elements: [AXElementInfo] = []
        traverseElement(appElement, depth: 0, results: &elements)
        return elements
    }

    /// Recursively walks the AX tree, collecting interactive elements.
    private func traverseElement(_ element: AXUIElement, depth: Int, results: inout [AXElementInfo]) {
        guard depth < 12 else { return } // Max depth to avoid runaway recursion

        let roleStr = copyStringAttribute(element, kAXRoleAttribute)
        let titleStr = copyStringAttribute(element, kAXTitleAttribute)
        let descStr = copyStringAttribute(element, kAXDescriptionAttribute)
        let helpStr = copyStringAttribute(element, kAXHelpAttribute)
        let valueStr = copyStringAttribute(element, kAXValueAttribute)

        let frame = copyFrame(element)
        let center = CGPoint(x: frame.midX, y: frame.midY)

        let isInteractive = Self.interactiveRoles.contains(roleStr)
        let hasLabel = !titleStr.isEmpty || !descStr.isEmpty || !helpStr.isEmpty || !valueStr.isEmpty

        if isInteractive && hasLabel {
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
                traverseElement(child, depth: depth + 1, results: &results)
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
