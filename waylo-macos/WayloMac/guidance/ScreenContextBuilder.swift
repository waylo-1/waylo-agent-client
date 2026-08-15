import AppKit

/// Builds the compact live-screen snapshot sent with /plan so the planner can
/// ground its steps in what is ACTUALLY on the user's screen: the frontmost
/// app, its focused window, and the visible interactive elements from the
/// accessibility tree. This is what turns "scripted tutorial" into an
/// open-ended planner — targetLabels come from real visible labels, and the
/// plan starts from the current state instead of assuming a cold start.
///
/// Kept deliberately small (~2KB): the backend caps it, and a huge dump only
/// dilutes the signal. All reads are local AX — fast, free, private.
enum ScreenContextBuilder {

    /// Max elements listed per section — enough signal, bounded tokens.
    private static let maxElements = 36
    private static let maxDockItems = 14

    /// System-wide dark mode. Read live so it's always current.
    static var isDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }

    static func build() -> String {
        var lines: [String] = []

        let appName = TargetAppTracker.shared.targetName
        lines.append("Frontmost app: \(appName.isEmpty ? "(unknown)" : appName)")
        // System appearance — so the planner can describe controls by their
        // actual shade ("dark Save button" vs "white Save button"). Auto-
        // detected (no need to ask the user; updates if they switch).
        lines.append("Appearance: \(Self.isDarkMode ? "Dark mode" : "Light mode")")

        if let windows = windowSummary(), !windows.isEmpty {
            lines.append("Windows: \(windows)")
        }

        // Visible interactive elements of the target app, deduped, shortest
        // first inside each role (short titles are the clickable labels).
        let elements = AccessibilityReader.shared.getTargetAppElements()
        if !elements.isEmpty {
            var seen = Set<String>()
            var described: [String] = []
            for el in elements {
                let title = el.title.isEmpty ? el.description : el.title
                let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.count <= 40 else { continue }
                let key = "\(el.role)|\(clean.lowercased())"
                guard seen.insert(key).inserted else { continue }
                described.append("\(shortRole(el.role)):\(clean)")
                if described.count >= maxElements { break }
            }
            if !described.isEmpty {
                lines.append("Visible elements: " + described.joined(separator: ", "))
            }
        }

        // Dock apps — tells the planner what can be launched with one click,
        // and (critically) what this Mac CALLS them: on en_IN/en_GB the Trash
        // is titled "Bin". The Trash is always the LAST Dock item, so a naive
        // prefix() truncated it out of the snapshot and the planner kept
        // guessing "Trash" — keep it explicitly.
        let allDock = AccessibilityReader.shared.getSystemUIElements()
            .filter { $0.role == "AXDockItem" && !$0.title.isEmpty }
            .map(\.title)
        var dock = Array(allDock.prefix(maxDockItems))
        if let trash = allDock.last(where: { ["trash", "bin"].contains($0.lowercased()) }),
           !dock.contains(trash) {
            dock.append(trash)
        }
        if !dock.isEmpty {
            lines.append("Dock: " + dock.joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }

    /// Titles of the target app's windows (the focused one marked).
    private static func windowSummary() -> String? {
        let windows = AccessibilityReader.shared.targetWindowList()
        guard !windows.isEmpty else { return nil }
        return windows.prefix(4).map { w in
            let kind = w.subrole.isEmpty ? "window" : w.subrole.replacingOccurrences(of: "AX", with: "")
            return "\(kind) \(Int(w.frame.width))x\(Int(w.frame.height))"
        }.joined(separator: "; ")
    }

    /// "AXMenuBarItem" → "menubar", etc. — keeps the snapshot tight.
    private static func shortRole(_ role: String) -> String {
        switch role {
        case "AXButton", "AXMenuButton", "AXToolbarButton": return "btn"
        case "AXMenuBarItem": return "menubar"
        case "AXMenuItem": return "menu"
        case "AXTextField", "AXComboBox": return "field"
        case "AXCheckBox", "AXRadioButton": return "check"
        case "AXTab": return "tab"
        case "AXLink": return "link"
        case "AXStaticText": return "text"
        case "AXRow", "AXCell": return "row"
        default: return role.replacingOccurrences(of: "AX", with: "").lowercased()
        }
    }
}
