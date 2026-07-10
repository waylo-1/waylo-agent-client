import AppKit

/// Collects YOLO training examples that are actually TRUSTWORTHY.
///
/// A Nova detection is only a *hypothesis* — it may point at the wrong thing.
/// Writing it to the training set immediately (the old behavior) poisons the
/// data with whatever Nova got wrong. An example earns its place only when the
/// user's own behavior confirms it:
///
///   1. STAGE    — Nova returns a box → held in memory, nothing written.
///   2. VERIFY   — the user clicks inside that box → the box was right.
///   3. DISCARD  — the user clicks somewhere else and the screen changes →
///                 the box was WRONG; drop it (the correction is reported
///                 separately as ground truth).
///   4. COMMIT   — the user marks the finished guide ✓ ("that was correct") →
///                 verified examples are written to disk and uploaded.
///      REJECT   — the user marks it ✗ → everything is dropped.
///
/// Screenshots are only ever captured/stored when the user has opted in
/// (`YOLODetector.captureTrainingImagesKey`); without it we keep the labelled
/// box only, which is still useful for analytics but not for training.
@MainActor
final class TrainingHarvest: ObservableObject {
    static let shared = TrainingHarvest()

    struct Example {
        let stepIndex: Int
        let appName: String
        let targetLabel: String
        let controlKind: String
        let screenRegion: String
        let bbox: [Double]        // Nova's raw [xMin,yMin,xMax,yMax] on 0–1000
        let pixelWidth: Int
        let pixelHeight: Int
        /// Downscaled JPEG, captured only when the user opted in.
        let imageBase64: String?
        var verified = false
    }

    /// Examples for the guide currently running, keyed by step index.
    private var staged: [Int: Example] = [:]
    /// Task name of the running guide (for the uploaded event).
    private var taskName = ""

    private init() {}

    var captureImagesEnabled: Bool {
        UserDefaults.standard.bool(forKey: YOLODetector.captureTrainingImagesKey)
    }

    // MARK: - Lifecycle

    func beginGuide(task: String) {
        staged.removeAll()
        taskName = task
    }

    /// A cloud layer produced a box. Hold it — do NOT write it yet.
    func stage(stepIndex: Int, appName: String, targetLabel: String, controlKind: String,
               screenRegion: String, bbox: [Double], image: CGImage) {
        var b64: String?
        if captureImagesEnabled, let (encoded, _) = ScreenCapturer.compressedJPEGBase64(image, maxWidth: 1280) {
            b64 = encoded
        }
        staged[stepIndex] = Example(
            stepIndex: stepIndex, appName: appName, targetLabel: targetLabel,
            controlKind: controlKind, screenRegion: screenRegion, bbox: bbox,
            pixelWidth: image.width, pixelHeight: image.height, imageBase64: b64
        )
        DebugLogger.log("HARVEST", "staged '\(targetLabel)' for step \(stepIndex + 1) (image=\(b64 != nil))")
    }

    /// The user clicked inside the predicted box — the prediction was right.
    func markVerified(stepIndex: Int) {
        guard staged[stepIndex] != nil else { return }
        staged[stepIndex]?.verified = true
        DebugLogger.log("HARVEST", "step \(stepIndex + 1) VERIFIED by the user's click")
    }

    /// The user clicked elsewhere and it worked — our box was wrong. Drop it.
    func discard(stepIndex: Int) {
        guard staged.removeValue(forKey: stepIndex) != nil else { return }
        DebugLogger.log("HARVEST", "step \(stepIndex + 1) DISCARDED — user corrected it")
    }

    /// User pressed ✓ on the finished guide: commit every verified example.
    func commitVerified() {
        let good = staged.values.filter(\.verified)
        guard !good.isEmpty else {
            DebugLogger.log("HARVEST", "nothing to commit (0 verified of \(staged.count) staged)")
            staged.removeAll(); return
        }
        for example in good {
            // Local JSONL (+ image when opted in) for offline fine-tuning.
            YOLODetector.shared.writeTrainingExample(example)
            // Central DB so the model learns from ALL users, not just this Mac.
            WayloAPIClient.shared.reportDetectionEvent(
                source: "auto_success",
                task: taskName,
                stepNumber: example.stepIndex + 1,
                findDescription: example.targetLabel,
                elementType: example.controlKind,
                screenRegion: example.screenRegion,
                appName: example.appName,
                layerReached: 4,                       // L3 Nova produced this box
                chosenBox: [
                    "bbox_0_1000": example.bbox,
                    "image_pixel_width": example.pixelWidth,
                    "image_pixel_height": example.pixelHeight,
                    "verified_by": "user_click",
                ],
                screenshotBase64: example.imageBase64,
                screenWidth: example.pixelWidth,
                screenHeight: example.pixelHeight
            )
        }
        DebugLogger.log("HARVEST", "COMMITTED \(good.count) verified example(s) → disk + backend")
        staged.removeAll()
    }

    /// User pressed ✗: the guide was wrong, none of it is training data.
    func rejectAll() {
        DebugLogger.log("HARVEST", "rejected — dropping \(staged.count) staged example(s)")
        staged.removeAll()
    }
}
