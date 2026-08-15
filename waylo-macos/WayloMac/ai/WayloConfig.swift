import Foundation

/// Ship-vs-dev switches for the app's surface. The production build shows the
/// simple, one-mode teach experience for real users — no extra guide modes, no
/// developer tools — and defaults "contribute training screenshots" ON so the
/// fleet keeps learning. Flip `isProduction` to false for a full dev build.
enum WayloConfig {
    /// TRUE = shipped build: teach-only surface, no Developer Tools/modes, and
    /// Judge/max-accuracy always on. FALSE = full dev build with tools + toggles.
    static let isProduction = true

    /// JUDGE / MAX-ACCURACY mode — an OPT-IN toggle (Developer Tools), OFF by
    /// default so the normal app keeps its original, cheap pipeline. When ON, the
    /// vision layer asks Gemini to REASON about the exact element (more accurate
    /// grounding) and gives a precise dot on confident results instead of a coarse
    /// region. Costs more Gemini tokens — flip it on (and set the default true) for
    /// the XPRIZE submission build where it must "never get it wrong."
    static let maxAccuracyKey = "waylo.maxAccuracy"
    static var maxAccuracy: Bool {
        // Backend remote config wins (so Judge Mode can be flipped without a
        // re-download); else shipped build = on, dev build = the local toggle.
        if let remote = remoteConfig("maxAccuracy") as? Bool { return remote }
        if isProduction { return true }
        return UserDefaults.standard.bool(forKey: maxAccuracyKey)
    }

    /// A value from the cached remote config (written by RemoteConfig at launch).
    /// Read straight from UserDefaults so hot paths never touch the @MainActor object.
    static func remoteConfig(_ key: String) -> Any? {
        (UserDefaults.standard.dictionary(forKey: "waylo.remoteConfig"))?[key]
    }

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
