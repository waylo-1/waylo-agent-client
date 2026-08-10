import Foundation

/// Ship-vs-dev switches for the app's surface. The production build shows the
/// simple, one-mode teach experience for real users — no extra guide modes, no
/// developer tools — and defaults "contribute training screenshots" ON so the
/// fleet keeps learning. Flip `isProduction` to false for a full dev build.
enum WayloConfig {
    static let isProduction = true

    /// Register default preference values (called once at launch). Training
    /// capture defaults ON in production so detection keeps improving; users can
    /// still turn it off from the panel.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            YOLODetector.captureTrainingImagesKey: isProduction
        ])
    }
}
