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

    /// JUDGE / MAX-ACCURACY mode — an OPT-IN toggle (Developer Tools), OFF by
    /// default so the normal app keeps its original, cheap pipeline. When ON, the
    /// vision layer asks Gemini to REASON about the exact element (more accurate
    /// grounding) and gives a precise dot on confident results instead of a coarse
    /// region. Costs more Gemini tokens — flip it on (and set the default true) for
    /// the XPRIZE submission build where it must "never get it wrong."
    static let maxAccuracyKey = "waylo.maxAccuracy"
    static var maxAccuracy: Bool { UserDefaults.standard.bool(forKey: maxAccuracyKey) }

    /// Gemini grounding is accepted as a precise dot only above this confidence;
    /// below it (in max-accuracy mode) we retry once, then describe. Higher bar in
    /// judge mode so a shaky guess never becomes a confident wrong dot.
    static var novaConfidenceFloor: Double { maxAccuracy ? 0.85 : 0.70 }

    /// Register default preference values (called once at launch). Training
    /// capture defaults ON everywhere so detection keeps improving; users can
    /// still turn it off from the panel.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            YOLODetector.captureTrainingImagesKey: true
        ])
    }
}
