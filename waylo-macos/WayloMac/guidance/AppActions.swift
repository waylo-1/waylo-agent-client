import AppKit

/// Autonomous "just do it" actions for specific apps — the tier above
/// `IntentShortcuts`. Where IntentShortcuts *opens* a URL/app, AppActions
/// *controls* a running app through its most reliable channel — a **URI
/// scheme** or **AppleScript** — never the slow, AX-hostile vision pipeline.
/// The result is instant, deterministic, and impossible to mis-ground: "play
/// drake on spotify", "pause the music", "next song", "directions to the
/// airport" happen in one call.
///
/// Matching is deliberately CONSERVATIVE (same philosophy as IntentShortcuts):
/// the app must be NAMED, or the verb must be an unambiguous media-transport
/// command, so a genuine guidance task ("how do I pause a clip in my editor")
/// is never hijacked. Anything unmatched returns nil → the planner handles it.
///
/// Adding an app is a small, local change: add a pattern in `match(_:)` and a
/// case in `perform(_:)`. Nothing else in the app needs to know.
enum AppActions {

    // Bundle IDs of the apps we can drive.
    private static let spotifyBundle = "com.spotify.client"
    private static let musicBundle   = "com.apple.Music"

    enum Action {
        /// Resolve a query to a Spotify URI (via backend) and PLAY it; falls
        /// back to opening the in-app search results when unresolved.
        case spotifyPlay(query: String)
        /// A media-transport command against a specific app.
        case transport(bundleID: String, appLabel: String, command: Transport)
        /// Open a URI scheme (Apple Maps directions, etc.).
        case openURI(URL, spoken: String)
    }

    enum Transport { case pause, resume, next, previous }

    // MARK: - Matching

    /// Returns a matched autonomous action, or nil → fall through to the planner.
    static func match(_ task: String) -> Action? {
        let lower = stripFiller(task.lowercased().trimmingCharacters(in: .whitespaces))

        // 1. "play <query> on spotify" / "spotify play <query>" / "on spotify play <query>"
        if let q = firstCapture(lower, #"^play\s+(.+?)\s+(?:on|in|using|with)\s+spotify\b.*$"#)
            ?? firstCapture(lower, #"^(?:on\s+)?spotify[,:]?\s+play\s+(.+)$"#)
            ?? firstCapture(lower, #"^play\s+(.+?)\s+song\s+on\s+spotify\b.*$"#) {
            let query = cleanQuery(q)
            if !query.isEmpty { return .spotifyPlay(query: query) }
        }

        // 2. Media transport. Pick the target app: an explicitly named one,
        //    else whichever music app is actually running (Spotify preferred).
        if let t = transportCommand(in: lower) {
            let (bundle, label) = musicTarget(in: lower)
            // Only drive an app that's actually open — launching Spotify just to
            // pause it is nonsense. If neither is open, let it fall through.
            guard isRunning(bundle) else {
                if let (rb, rl) = anyRunningMusicApp() { return .transport(bundleID: rb, appLabel: rl, command: t) }
                return nil
            }
            return .transport(bundleID: bundle, appLabel: label, command: t)
        }

        // 3. Apple Maps directions. Only UNAMBIGUOUS travel phrasing — "drive
        //    to X", "directions to X", "X on maps". ("navigate to"/"route to"
        //    are dropped on purpose: "navigate to settings" is in-app guidance,
        //    not a map query.)
        if let dest = firstCapture(lower, #"^(?:directions?\s+(?:to|from\s+here\s+to)|drive\s+to|get\s+me\s+to)\s+(.+)$"#)
            ?? firstCapture(lower, #"^(.+?)\s+on\s+(?:apple\s+)?maps$"#) {
            let d = cleanQuery(dest)
            if !d.isEmpty, let enc = d.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let url = URL(string: "maps://?daddr=\(enc)&dirflg=d") {
                return .openURI(url, spoken: "Getting directions to \(d).")
            }
        }

        return nil
    }

    /// Which transport command the phrase expresses (if any). Requires a media
    /// cue word so unrelated "pause"/"next" tasks don't match.
    private static func transportCommand(in lower: String) -> Transport? {
        let cue = #"(?:music|song|track|spotify|playback|tune|it|this)"#
        if matches(lower, #"^(?:pause|stop)\s+(?:the\s+)?"# + cue + #"\b.*$"#) { return .pause }
        if matches(lower, #"^(?:resume|unpause|continue|keep playing|play)\s+(?:the\s+)?(?:music|song|track|spotify|playback|tune)\b.*$"#) { return .resume }
        if matches(lower, #"^(?:next|skip)\s*(?:the\s+)?(?:song|track|tune|this(?:\s+one)?|"# + cue + #")?\b.*$"#)
            && lower.range(of: #"(next|skip)"#, options: .regularExpression) != nil { return .next }
        if matches(lower, #"^(?:previous|last|prior|go back(?:\s+a)?)\s+(?:song|track|tune)\b.*$"#) { return .previous }
        return nil
    }

    /// Explicitly-named music app, else Spotify as the default label.
    private static func musicTarget(in lower: String) -> (bundle: String, label: String) {
        if lower.contains("apple music") || lower.range(of: #"\bmusic\b"#, options: .regularExpression) != nil {
            return (musicBundle, "Apple Music")
        }
        return (spotifyBundle, "Spotify")
    }

    // MARK: - Performing

    /// Executes the action. Returns the line to show/speak. Async because the
    /// Spotify play path may resolve the track URI over the network first.
    @discardableResult
    static func perform(_ action: Action) async -> String {
        switch action {
        case .openURI(let url, let spoken):
            NSWorkspace.shared.open(url)
            DebugLogger.log("ACTION", "openURI \(url.absoluteString)")
            return spoken

        case .transport(let bundle, let label, let command):
            return runTransport(bundle: bundle, label: label, command: command)

        case .spotifyPlay(let query):
            return await playOnSpotify(query: query)
        }
    }

    // MARK: - Spotify play (resolve → AppleScript, else search URI)

    private static func playOnSpotify(query: String) async -> String {
        // Best path: resolve the query to a real Spotify URI via the backend
        // (Spotify Web API search) and start playback locally via AppleScript —
        // fully autonomous, actually plays the artist/track. Requires a Spotify
        // key on the backend; when absent the resolve returns nil and we fall
        // back to opening the in-app search results (still instant, one tap to
        // play). Either way the user is never sent to the vision pipeline.
        if let uri = await WayloAPIClient.shared.resolveSpotifyURI(query: query) {
            ensureRunning(spotifyBundle)
            let escaped = uri.replacingOccurrences(of: "\"", with: "")
            if runAppleScript("tell application \"Spotify\"\nplay track \"\(escaped)\"\nend tell") {
                DebugLogger.log("ACTION", "spotify play \(uri) for '\(query)'")
                return "Playing \(query) on Spotify."
            }
        }
        // Fallback: open the search results in the app.
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? query
        if let url = URL(string: "spotify:search:\(enc)") {
            NSWorkspace.shared.open(url)
            DebugLogger.log("ACTION", "spotify search fallback for '\(query)'")
            return "Here's \(query) on Spotify — press play on the top result."
        }
        return "I couldn't reach Spotify."
    }

    // MARK: - AppleScript helpers

    private static func runTransport(bundle: String, label: String, command: Transport) -> String {
        guard isRunning(bundle) else { return "\(label) isn't open." }
        let appName = (bundle == musicBundle) ? "Music" : "Spotify"
        let verb: String
        let spoken: String
        switch command {
        case .pause:    verb = "pause";           spoken = "Paused."
        case .resume:   verb = "play";            spoken = "Playing."
        case .next:     verb = "next track";      spoken = "Next track."
        case .previous: verb = "previous track";  spoken = "Previous track."
        }
        let ok = runAppleScript("tell application \"\(appName)\" to \(verb)")
        DebugLogger.log("ACTION", "\(appName) \(verb) → \(ok ? "ok" : "failed")")
        return ok ? spoken : "I couldn't control \(label)."
    }

    /// Runs an AppleScript source string. Returns true on success. AppleScript
    /// needs the Automation (Apple Events) TCC grant, which the app requests;
    /// a denial surfaces as failure and we degrade gracefully.
    @discardableResult
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        if let error { DebugLogger.log("ACTION", "AppleScript error: \(error[NSAppleScript.errorMessage] ?? "?")") ; return false }
        return true
    }

    // MARK: - App-state helpers

    private static func isRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
    }

    /// Spotify preferred, then Apple Music — used when the phrase names no app.
    private static func anyRunningMusicApp() -> (bundle: String, label: String)? {
        if isRunning(spotifyBundle) { return (spotifyBundle, "Spotify") }
        if isRunning(musicBundle)   { return (musicBundle, "Apple Music") }
        return nil
    }

    /// Launch the app (if needed) so a subsequent AppleScript `play track`
    /// lands on a live process.
    private static func ensureRunning(_ bundleID: String) {
        guard !isRunning(bundleID),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }

    // MARK: - Text helpers

    /// Removes leading conversational filler ("can you", "please", "hey waylo").
    private static func stripFiller(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces)
        let fillers = #"^(?:hey\s+|ok\s+|okay\s+|so\s+|um\s+|waylo[,\s]+|please\s+|can you\s+|could you\s+|would you\s+|will you\s+|i want to\s+|i wanna\s+|i'd like to\s+|i would like to\s+|let's\s+|lets\s+|help me\s+)"#
        while let r = s.range(of: fillers, options: [.regularExpression, .caseInsensitive]) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Trims trailing politeness and quotes from a captured query.
    private static func cleanQuery(_ q: String) -> String {
        var s = q.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”"))
        s = s.replacingOccurrences(of: #"\s+(please|now|for me|thanks|thank you)\.?$"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstCapture(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
