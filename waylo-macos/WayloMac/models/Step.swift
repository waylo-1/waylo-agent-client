import Foundation

/// What kind of action a step requires.
enum StepAction: String, Codable {
    case click      // click a UI element (show dot, advance on click)
    case type       // type text (show banner, advance on Return)
    case key        // press a key like Enter/Tab (show banner, advance on that key)
    case info       // just an instruction / wait (advance on Next or any key)
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

    var id: Int { index }
}

/// A full plan returned by the backend for a given task.
struct GuidePlan: Codable {
    let task: String
    let app: String
    let steps: [Step]
}
