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
        let inDialog: Bool
    }

    let entries: [Entry]
    /// Hash of the visible UI — compared across actions to tell the model
    /// whether its last action actually did anything.
    let fingerprint: Int
    let appName: String
    /// True when a modal sheet/dialog is open — the model must act inside it.
    let dialogOpen: Bool
    /// Top-level menu names (File, Edit, …) — a compact hint, since the model
    /// invokes menus by PATH, not by pressing an item's id.
    let menuTitles: [String]

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
            if e.inDialog { d["dialog"] = true }
            return d
        }
    }

    /// Reads the target app's tree and numbers the interactive elements.
    /// When a modal sheet/dialog is open its elements are listed FIRST and
    /// flagged, so the model can't miss that it must act inside the dialog.
    /// Cap keeps the prompt bounded.
    static func capture(maxElements: Int = 110) -> AgentSnapshot {
        let appName = TargetAppTracker.shared.targetName
        let raw = AccessibilityReader.shared.getTargetAppElements()
        let dialogFrame = AccessibilityReader.shared.targetFocusedDialogFrame()

        // The AX tree includes the WHOLE menu bar (every File/Edit/Apple item),
        // which floods the list — 100+ menu rows crowd out real window content
        // and even dialog buttons. The agent invokes menus by PATH, so menu
        // items are useless as pressable ids: drop them, keep only the
        // top-level menu NAMES as a hint.
        var menuTitles: [String] = []
        var seen = Set<String>()
        var deduped: [(AXElementInfo, Bool)] = []
        for info in raw {
            if info.role == "AXMenuBarItem" {
                if !info.title.isEmpty, !menuTitles.contains(info.title) { menuTitles.append(info.title) }
                continue
            }
            // Menu dropdown contents — not pressable by id in agent mode.
            if info.role == "AXMenuItem" || info.role == "AXMenu" { continue }

            let key = "\(info.role)|\(info.title)|\(info.description)|\(Int(info.frame.minX)),\(Int(info.frame.minY))"
            guard seen.insert(key).inserted else { continue }
            // Skip fully unlabeled static text — nothing for the model to go on.
            if info.title.isEmpty && info.description.isEmpty && info.value.isEmpty
                && (info.role == "AXStaticText" || info.role == "AXRow") { continue }
            let inDialog = dialogFrame.map { $0.intersects(info.frame) } ?? false
            deduped.append((info, inDialog))
        }
        // Dialog elements first — they're what the model must act on.
        if dialogFrame != nil {
            deduped.sort { $0.1 && !$1.1 }
        }

        var entries: [Entry] = []
        var hasher = Hasher()
        for (i, pair) in deduped.prefix(maxElements).enumerated() {
            entries.append(Entry(id: i + 1, info: pair.0, inDialog: pair.1))
            hasher.combine("\(pair.0.role)|\(pair.0.title)|\(Int(pair.0.frame.minX)),\(Int(pair.0.frame.minY))")
        }
        hasher.combine(dialogFrame != nil)

        let dialogCount = entries.filter(\.inDialog).count
        let preview = entries.prefix(8)
            .map { $0.info.title.isEmpty ? $0.info.description : $0.info.title }
            .filter { !$0.isEmpty }.joined(separator: ", ")
        DebugLogger.log("AGENT", "observe: \(entries.count) elements"
            + (dialogFrame != nil ? " (DIALOG open, \(dialogCount) inside)" : "")
            + (preview.isEmpty ? "" : " — \(preview)"))

        return AgentSnapshot(entries: entries, fingerprint: hasher.finalize(),
                             appName: appName, dialogOpen: dialogFrame != nil,
                             menuTitles: menuTitles)
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
