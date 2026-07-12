import Foundation

/// Hint for where on screen a step's element lives, so detection layers can
/// narrow their search before doing any work.
enum ScreenRegion: String, Codable {
    case menuBar      // macOS system menu bar — very top strip (File, Edit, View...)
    case ribbon       // app toolbar / ribbon below the menu bar (Bold, Italic...)
    case dialog       // modal dialog or popup in the center of the screen
    case sidebar      // left or right panel (Navigator, Inspector...)
    case spreadsheet  // main content area (cells, canvas, document body)
    case statusBar    // bottom strip of the app window
    case fullScreen   // unknown — search everywhere (fallback)

    init(lenient raw: String?) {
        self = ScreenRegion(rawValue: raw ?? "") ?? .fullScreen
    }
}
