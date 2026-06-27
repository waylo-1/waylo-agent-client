import Vision
import AppKit

/// Layer 1: on-device Apple Vision OCR. Finds the target text label on screen
/// and returns its location in AX global coordinates (what OverlayWindow wants).
/// Fast (~80ms), free, private — handles the majority of text-labelled UI.
final class LocalVisionDetector {

    /// Minimum fuzzy-match score (0...1) to accept a hit.
    private let threshold = 0.7

    /// Finds `targetLabel` in the captured image of `screen`, optionally cropping
    /// to `region` first so e.g. a toolbar "Bold" doesn't compete with a dialog "Bold".
    /// Returns an AX global point (top-left origin, points) or nil.
    func findLabel(_ targetLabel: String, in image: CGImage, on screen: NSScreen, region: ScreenRegion = .fullScreen) async -> CGPoint? {
        let trimmed = targetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowerTarget = trimmed.lowercased()

        // Pixels per point for this capture.
        let scale = screen.frame.width > 0 ? CGFloat(image.width) / screen.frame.width : 1

        // Determine the OCR image + the crop origin/size in the screen's local points.
        var ocrImage = image
        var cropOriginLocal = CGPoint.zero
        var cropSizeLocal = screen.frame.size

        if region != .fullScreen,
           let local = ScreenRegionHelper.localRect(for: region, screenSize: screen.frame.size) {
            let pixelRect = CGRect(
                x: local.minX * scale, y: local.minY * scale,
                width: local.width * scale, height: local.height * scale
            )
            let clamped = pixelRect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if !clamped.isEmpty, let cropped = image.cropping(to: clamped) {
                ocrImage = cropped
                cropOriginLocal = CGPoint(x: clamped.minX / scale, y: clamped.minY / scale)
                cropSizeLocal = CGSize(width: clamped.width / scale, height: clamped.height / scale)
            }
        }

        let results = await runOCRRaw(on: ocrImage)

        var bestObs: VNRecognizedTextObservation?
        var bestCandidate: VNRecognizedText?
        var bestScore = 0.0

        for obs in results {
            guard let cand = obs.topCandidates(1).first else { continue }
            let text = cand.string.lowercased().trimmingCharacters(in: .whitespaces)
            let score = similarityScore(lowerTarget, text)
            if score > bestScore {
                bestScore = score
                bestObs = obs
                bestCandidate = cand
            }
        }

        guard bestScore >= threshold, let obs = bestObs else { return nil }

        // Precise location: bounding box of just the matched substring if present.
        var box = obs.boundingBox
        if let cand = bestCandidate,
           let range = cand.string.range(of: trimmed, options: .caseInsensitive),
           let rectObs = try? cand.boundingBox(for: range) {
            box = rectObs.boundingBox
        }

        // box is normalized within the OCR (cropped) image, bottom-left origin.
        let localX = box.midX * cropSizeLocal.width
        let localYFromTop = (1.0 - box.midY) * cropSizeLocal.height
        let screenLocalX = cropOriginLocal.x + localX
        let screenLocalY = cropOriginLocal.y + localYFromTop

        // Screen-local (top-left) → AX global (top-left).
        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        return CGPoint(x: screen.frame.minX + screenLocalX, y: axTop + screenLocalY)
    }

    // MARK: - OCR

    private func runOCRRaw(on cgImage: CGImage) async -> [VNRecognizedTextObservation] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // don't autocorrect UI labels

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - Fuzzy matching

    /// Exact = 1.0, containment = 0.85, otherwise Levenshtein ratio.
    private func similarityScore(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1.0 }
        // Word-level containment: "file" matches an observation "File" exactly,
        // and a multi-word target token appearing in the text scores high.
        if b.contains(a) || a.contains(b) { return 0.85 }
        let distance = levenshtein(a, b)
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        return 1.0 - (Double(distance) / Double(maxLen))
    }

    private func levenshtein(_ s: String, _ t: String) -> Int {
        let s = Array(s), t = Array(t)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var dp = Array(0...t.count)
        for i in 1...s.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...t.count {
                let temp = dp[j]
                dp[j] = s[i - 1] == t[j - 1] ? prev : 1 + min(prev, min(dp[j], dp[j - 1]))
                prev = temp
            }
        }
        return dp[t.count]
    }
}
