import AppKit

/// Opening an app (or the Trash) is a solved problem the OS already answers —
/// `NSWorkspace` launches anything by name or URL. Pointing a vision model at a
/// Dock icon is strictly harder AND less reliable: Dock icons carry no text, so
/// OCR is useless, YOLO sees a generic glyph, and the icon's name is localized
/// ("Bin" vs "Trash"). Detection effort belongs on the elements that genuinely
/// need it — unlabelled controls INSIDE an app.
///
/// So: when a step is really "open <thing>", Waylo opens it and moves on.
enum AppLauncher {

    enum Target {
        case app(name: String, url: URL)
        case trash

        var displayName: String {
            switch self {
            case .app(let name, _): return name
            case .trash: return trashDisplayName
            }
        }
    }

    /// What the Dock actually calls the Trash on this Mac ("Bin" on en_IN/en_GB).
    /// Read from the Dock's own AX title so we speak the user's language.
    static var trashDisplayName: String {
        let dockTrash = AccessibilityReader.shared.getSystemUIElements()
            .first { $0.role == "AXDockItem"
                && ["trash", "bin"].contains($0.title.lowercased()) }
        return dockTrash?.title ?? "Trash"
    }

    /// If this step is really "open something", return what to open.
    /// Conservative: only fires for the Dock/launch shape, never for a step
    /// that acts *inside* an app (that's what detection is for).
    static func target(for step: Step) -> Target? {
        let text = "\(step.instruction) \(step.elementDescription) \(step.targetLabel)".lowercased()

        // A right-click step wants a context menu, not a launch — leave it alone.
        let wantsContextMenu = text.contains("right-click") || text.contains("right click")
            || text.contains("control-click") || text.contains("control click")
            || text.contains("context menu")

        // The macOS Finder Bin — ONLY when the step is genuinely about the
        // DESKTOP Trash, i.e. it names the Dock, or we're already in Finder.
        // "delete"/"trash"/"bin" INSIDE another app (Mail's Delete/Trash toolbar
        // icon, Gmail's page trash) is NOT the Finder Bin — it's a control in
        // that app, so leave it to normal detection (which now finds Mail's
        // Delete button via the toolbar AX read). Without this, "delete an email
        // in Mail" wrongly launched Finder's Bin. "Empty Bin" is a button inside
        // the Trash window (checked via targetLabel) — never a launch.
        let label = step.targetLabel.lowercased()
        let targetIsEmptyButton = label.hasPrefix("empty")
        let mentionsTrash = text.contains("trash") || text.contains("bin")
        let inFinder = TargetAppTracker.shared.targetName.lowercased().contains("finder")
        if mentionsTrash, !wantsContextMenu, !targetIsEmptyButton,
           !TargetAppTracker.shared.isBrowser,
           (text.contains("dock") || inFinder) {
            return .trash
        }

        // "click the <App> icon in the Dock" / "open <App>".
        guard !wantsContextMenu, text.contains("dock") || text.hasPrefix("open ") else { return nil }
        guard let name = appName(in: step), let url = resolveApp(named: name) else { return nil }
        return .app(name: name, url: url)
    }

    /// Performs the launch. Returns a spoken confirmation.
    @discardableResult
    static func open(_ target: Target) -> String {
        switch target {
        case .app(let name, let url):
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            DebugLogger.log("LAUNCH", "opened app '\(name)' (\(url.lastPathComponent))")
            return "Opening \(name) for you."
        case .trash:
            if let url = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: false) {
                NSWorkspace.shared.open(url)
                DebugLogger.log("LAUNCH", "opened the \(trashDisplayName)")
            }
            return "Opening the \(trashDisplayName) for you."
        }
    }

    // MARK: - Name resolution

    /// Pulls the app name out of the step. Prefers the explicit targetLabel,
    /// else the words before "icon"/"in the Dock".
    private static func appName(in step: Step) -> String? {
        let label = step.targetLabel.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty, label.split(separator: " ").count <= 3 { return label }

        let source = step.elementDescription.isEmpty ? step.instruction : step.elementDescription
        // "Click the Photo Booth icon in the Dock" → "Photo Booth"
        if let r = source.range(of: #"(?i)(?:the\s+)?([A-Za-z0-9 ]{2,30}?)\s+(?:icon|app)"#,
                                options: .regularExpression) {
            let match = String(source[r])
                .replacingOccurrences(of: #"(?i)\s*(icon|app)\s*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?i)^\s*the\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !match.isEmpty { return match }
        }
        if source.lowercased().hasPrefix("open ") {
            let tail = source.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, tail.split(separator: " ").count <= 3 { return tail }
        }
        return nil
    }

    /// Finds an installed app by display name (case-insensitive).
    static func resolveApp(named name: String) -> URL? {
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications",
                    "/System/Applications/Utilities",
                    "/Applications/Utilities",
                    ("~/Applications" as NSString).expandingTildeInPath]
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            if let hit = items.first(where: {
                $0.hasSuffix(".app") && $0.dropLast(4).caseInsensitiveCompare(name) == .orderedSame
            }) {
                return URL(fileURLWithPath: "\(dir)/\(hit)")
            }
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame
        }), let url = running.bundleURL {
            return url
        }
        return nil
    }
}
