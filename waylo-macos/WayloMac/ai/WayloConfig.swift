import Foundation

/// Ship-vs-dev switches for the app's surface. The production build shows the
/// simple, one-mode teach experience for real users — no extra guide modes, no
/// developer tools — and defaults "contribute training screenshots" ON so the
/// fleet keeps learning. Flip `isProduction` to false for a full dev build.
enum WayloConfig {
    /// FALSE = full dev build (guide modes + Developer Tools visible). Flip to
    /// TRUE when packaging the shipped app to hide those and show the simple
    /// teach-only surface. Kept false for now so testing keeps its tools.
    static let isProduction = false

    /// Register default preference values (called once at launch). Training
    /// capture defaults ON everywhere so detection keeps improving; users can
    /// still turn it off from the panel.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            YOLODetector.captureTrainingImagesKey: true
        ])
    }
}
