import AppKit

/// Tasks that don't need a plan at all: opening a website, a web search, or
/// launching an app are one NSWorkspace call — instant, free, and impossible
/// to mis-ground. Matching is deliberately CONSERVATIVE: anything ambiguous
/// falls through to the planner ("search for my file in Finder" is guidance,
/// not a Google query), so a false negative costs one LLM call while a false
/// positive would hijack a real task.
enum IntentShortcuts {

    enum Intent {
        case openURL(URL, spoken: String)
        case webSearch(query: String, engine: String, url: URL)
        case openApp(name: String, url: URL)
    }

    /// Returns a matched intent, or nil → send the task to the planner.
    static func match(_ task: String) -> Intent? {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip conversational filler up front so natural speech matches:
        // "can you search…", "hey Waylo please open…", "I want to google…".
        let lower = stripFiller(text.lowercased())

        // 1. Explicit URL / domain anywhere in the task.
        if let url = explicitURL(in: text) {
            return .openURL(url, spoken: "Opening \(url.host ?? "the website").")
        }

        // 2. Web search — ONLY when the engine is named ("search X on google",
        //    "google X", "youtube X", "search youtube for X").
        if let (query, engine) = searchQuery(in: lower, original: text) {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let url = engine == "youtube"
                ? URL(string: "https://www.youtube.com/results?search_query=\(encoded)")!
                : URL(string: "https://www.google.com/search?q=\(encoded)")!
            return .webSearch(query: query, engine: engine, url: url)
        }

        // 3. App launch — "open/launch/start <app>", short tail, and ONLY when
        //    the app actually resolves on this Mac (else the planner guides
        //    the user through Dock/Spotlight, which teaches more anyway).
        for prefix in ["open ", "launch ", "start "] where lower.hasPrefix(prefix) {
            let name = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            let words = name.split(separator: " ")
            guard !name.isEmpty, words.count <= 3 else { continue }
            if let url = resolveApp(named: name) {
                return .openApp(name: name, url: url)
            }
        }

        return nil
    }

    /// Performs the intent. Returns the confirmation to show/speak.
    @discardableResult
    static func perform(_ intent: Intent) -> String {
        switch intent {
        case .openURL(let url, let spoken):
            NSWorkspace.shared.open(url)
            DebugLogger.log("INTENT", "openURL \(url.absoluteString)")
            return spoken
        case .webSearch(let query, let engine, let url):
            NSWorkspace.shared.open(url)
            DebugLogger.log("INTENT", "search '\(query)' on \(engine)")
            return "Searching \(engine == "youtube" ? "YouTube" : "Google") for \(query)."
        case .openApp(let name, let url):
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            DebugLogger.log("INTENT", "openApp \(name) → \(url.path)")
            return "Opening \(name)."
        }
    }

    // MARK: - Matching helpers

    private static func explicitURL(in text: String) -> URL? {
        // Full URLs.
        if let range = text.range(of: #"https?://\S+"#, options: .regularExpression) {
            return URL(string: String(text[range]))
        }
        // Bare domains ("go to amazon.in", "open wikipedia.org") — require a
        // dot + known-ish TLD shape and no spaces.
        if let range = text.range(of: #"(?i)\b[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|org|net|in|io|co|gov|edu|app|dev|ai)(/\S*)?\b"#,
                                  options: .regularExpression) {
            return URL(string: "https://\(text[range])")
        }
        return nil
    }

    /// Removes leading conversational filler so natural phrasings match:
    /// "can you", "could you", "please", "i want to", "i'd like to", "hey",
    /// "ok", "waylo". Applied repeatedly (they stack: "hey waylo can you …").
    private static func stripFiller(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces)
        let fillers = #"^(?:hey\s+|ok\s+|okay\s+|so\s+|um\s+|waylo[,\s]+|please\s+|can you\s+|could you\s+|would you\s+|will you\s+|i want to\s+|i wanna\s+|i'd like to\s+|i would like to\s+|let's\s+|lets\s+|help me\s+)"#
        while let r = s.range(of: fillers, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private static func searchQuery(in lowerIn: String, original: String) -> (String, String)? {
        // Drop a leading "open chrome/safari/google/the browser and …" so a
        // spoken "open Google and search X" still counts as a web search
        // (open + search is redundant — the URL opens in the default browser).
        var lower = lowerIn
        if let r = lower.range(of: #"^\s*(?:open|launch|start|go to|goto)\s+(?:the\s+|a\s+)?(?:chrome|google chrome|google|safari|firefox|edge|browser|web browser)\s+(?:and\s+)?"#,
                               options: .regularExpression) {
            lower = String(lower[r.upperBound...])
        }

        // Patterns match at the START of the (cleaned) string; the query can
        // trail off with or without a "on google/youtube" suffix.
        let patterns: [(pattern: String, engine: String)] = [
            (#"^(?:search|look up|find)\s+(?:for\s+)?(.+?)\s+on\s+youtube\b.*$"#, "youtube"),
            (#"^(?:search|look up|find)\s+(?:for\s+)?(.+?)\s+on\s+google\b.*$"#, "google"),
            (#"^search\s+youtube\s+for\s+(.+)$"#, "youtube"),
            (#"^search\s+(?:google|the web)\s+for\s+(.+)$"#, "google"),
            (#"^(?:search|look up|find)\s+(?:for\s+)?(.+)$"#, "google"),   // bare "search X"
            (#"^youtube\s+(.+)$"#, "youtube"),
            (#"^google\s+(?:for\s+)?(.+)$"#, "google"),
        ]
        for (pattern, engine) in patterns {
            if let q = lower.firstCapture(for: pattern)?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
                return (q, engine)
            }
        }
        return nil
    }

    /// Finds an installed app by (case-insensitive) display name.
    private static func resolveApp(named name: String) -> URL? {
        AppLauncher.resolveApp(named: name)
    }
}
