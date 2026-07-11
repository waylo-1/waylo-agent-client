import AppKit

/// One observation of the target app for the agent loop: the AX tree flattened
/// into a NUMBERED list the model can choose from ("press #7"), with the live
/// `AXUIElement` handle kept per id so the chosen element is acted on directly
/// (AXPress) — no coordinates, no OCR, no fuzzy re-matching. This is the core
/// of agent mode: the model never *describes* an element for us to find; it
/// *picks* one we already hold.
struct AgentSnapshot {

    struct Entry {
        let id: Int
        let info: AXElementInfo
    }

    let entries: [Entry]
    /// Hash of the visible UI — compared across actions to tell the model
    /// whether its last action actually did anything.
    let fingerprint: Int
    let appName: String

    /// id → element for the executor.
    func element(for id: Int) -> AXElementInfo? {
        entries.first(where: { $0.id == id })?.info
    }

    /// The JSON payload for /act.
    var payload: [[String: Any]] {
        entries.map { e in
            var d: [String: Any] = ["id": e.id, "role": Self.shortRole(e.info.role)]
            if !e.info.title.isEmpty { d["title"] = String(e.info.title.prefix(60)) }
            if !e.info.description.isEmpty, e.info.description != e.info.title {
                d["desc"] = String(e.info.description.prefix(60))
            }
            if !e.info.value.isEmpty { d["value"] = String(e.info.value.prefix(40)) }
            d["pos"] = "\(Int(e.info.center.x)),\(Int(e.info.center.y))"
            return d
        }
    }

    /// Reads the target app's tree and numbers the interactive elements.
    /// Cap keeps the prompt bounded; elements are already interactive-only
    /// (AccessibilityReader filters roles).
    static func capture(maxElements: Int = 110) -> AgentSnapshot {
        let appName = TargetAppTracker.shared.targetName
        let raw = AccessibilityReader.shared.getTargetAppElements()

        // Dedupe identical (role|title|desc) rows — long lists repeat entries
        // (table cells) and dilute the prompt. Keep first occurrence.
        var seen = Set<String>()
        var entries: [Entry] = []
        var hasher = Hasher()
        var nextID = 1
        for info in raw {
            let key = "\(info.role)|\(info.title)|\(info.description)|\(Int(info.frame.minX)),\(Int(info.frame.minY))"
            guard seen.insert(key).inserted else { continue }
            // Skip fully unlabeled static text — nothing for the model to go on.
            if info.title.isEmpty && info.description.isEmpty && info.value.isEmpty
                && (info.role == "AXStaticText" || info.role == "AXRow") { continue }
            entries.append(Entry(id: nextID, info: info))
            hasher.combine(key)
            nextID += 1
            if entries.count >= maxElements { break }
        }
        return AgentSnapshot(entries: entries, fingerprint: hasher.finalize(), appName: appName)
    }

    private static func shortRole(_ role: String) -> String {
        switch role {
        case "AXButton", "AXMenuButton", "AXToolbarButton": return "button"
        case "AXMenuBarItem": return "menubar"
        case "AXMenuItem": return "menuitem"
        case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField": return "field"
        case "AXCheckBox": return "checkbox"
        case "AXRadioButton": return "radio"
        case "AXTab": return "tab"
        case "AXLink": return "link"
        case "AXPopUpButton": return "popup"
        case "AXStaticText": return "text"
        case "AXRow", "AXCell": return "row"
        default: return role.replacingOccurrences(of: "AX", with: "").lowercased()
        }
    }
}
