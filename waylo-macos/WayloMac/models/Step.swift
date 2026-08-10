import Foundation

/// What kind of action a step requires.
enum StepAction: String, Codable {
    case click      // click a UI element (show dot, advance on click)
    case type       // type text (show banner, advance on Return)
    case key        // press a key like Enter/Tab (show banner, advance on that key)
    case info       // just an instruction / wait (advance on Next or any key)
}

/// The visual nature of the target — drives which detection layers run.
/// `.text`  → AX tree + Apple Vision OCR (words on screen).
/// `.icon`  → AX (by description/tooltip) + YOLO + Nova (graphical icons/logos).
enum StepTargetType: String, Codable {
    case text
    case icon
}

/// A single guided step. `instruction` is spoken/shown to the user,
/// `targetLabel` is the exact visible text to find via OCR, and
/// `elementDescription`/`findDescription` are richer hints for AX / vision search.
struct Step: Codable, Identifiable {
    let index: Int
    let instruction: String
    let findDescription: String
    let targetLabel: String       // exact visible text, e.g. "Bold", "File" ("" if icon-only)
    let elementDescription: String // natural-language hint, e.g. "Bold button in the toolbar"
    let action: StepAction         // click / type / key / info
    let key: String?               // for `.key` actions, e.g. "return", "tab"
    let screenRegion: ScreenRegion // where to look: menuBar / ribbon / dialog / ...
    var targetType: StepTargetType = .text  // text vs icon/logo — routes detection
    /// The kind of control to click — "button", "menuItem", "checkbox", "tab",
    /// "link", "field", or "" (any). Lets detection prefer a real control over
    /// matching plain header/label text.
    var controlKind: String = ""
    /// Nearby visible text that helps locate the target when its own label is
    /// short/ambiguous (e.g. anchor "Login Password" for a "Change…" button).
    var anchorText: String = ""
    /// Where the target sits relative to anchorText: "below"/"above"/"left"/"right"/"near".
    var anchorPosition: String = ""
    /// If > 0, the step advances automatically this many seconds after it's shown.
    /// Used for "do this, then I'll continue on my own" info steps (e.g. "open any
    /// chat" in WhatsApp, where Waylo can't know which chat you'll pick).
    var autoAdvanceSeconds: Double = 0
    /// When true, the step's instruction is shown silently (not spoken aloud).
    /// Used for pure-wait steps like the Photo Booth countdown.
    var silent: Bool = false
    /// When true (info steps), Waylo just speaks the instruction and advances as
    /// soon as it senses ANY click — used when it can't reliably point (e.g. the
    /// Google result link) but the user can click it themselves.
    var advanceOnAnyClick: Bool = false
    /// The name a screen reader announces for this control — its aria-label (web)
    /// or AXDescription (native). The planner (which knows the app) fills this for
    /// icon targets: Gmail's paperclip is announced "Attach files", so a focused
    /// deep AX search for that exact name resolves it pixel-exact and FREE on the
    /// first run — no vision, no learning. "" when unknown/not applicable.
    var accessibleName: String = ""
    /// URL-GATED navigation. When set (e.g. "leetcode.com"), this step doesn't
    /// point at anything — Waylo speaks how to get there ("click the address bar,
    /// type leetcode.com, press Enter — or open it from your bookmarks") and then
    /// just WATCHES the browser's URL, auto-advancing the moment it matches. Robust
    /// to HOW the user navigates (typing, bookmark, history, autocomplete); no
    /// brittle click-address-bar → type → Return sequence to mis-detect.
    var awaitURL: String = ""

    var id: Int { index }

    /// Stable key for the step-label cache. Built identically on the lookup and
    /// store paths so the embedding (and therefore the match) lines up. Combines
    /// the element description, exact target label and action.
    var labelCacheKey: String {
        "\(elementDescription) \(targetLabel) \(action.rawValue)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A full plan returned by the backend for a given task.
struct GuidePlan: Codable {
    let task: String
    let app: String
    let steps: [Step]
    /// True for hardcoded demo plans — these are LOCKED so mid-run corrections
    /// only relabel/re-point a step and never replan (rewrite remaining steps).
    var demo: Bool = false
}
