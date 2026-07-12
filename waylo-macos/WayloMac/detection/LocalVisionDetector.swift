import Vision
import AppKit

/// Layer 1: on-device Apple Vision OCR. Finds the target text label on screen
/// and returns its location in AX global coordinates (what OverlayWindow wants).
/// Fast (~80ms), free, private — handles the majority of text-labelled UI.
final class LocalVisionDetector {

    /// Minimum fuzzy-match score (0...1) to accept a hit. Raised so OCR no longer
    /// accepts weak partial matches — we'd rather escalate to vision than guess.
    private let threshold = 0.8

    /// A scored OCR match: the location plus how confident we are (0...1).
    struct OCRMatch {
        let point: CGPoint
        let score: Double
        /// AX-global bounding rect of the matched text (for region highlights).
        var frame: CGRect = .zero
    }

    /// Thin wrapper: returns a point only if the best match clears `threshold`.
    func findLabel(_ targetLabel: String, in image: CGImage, on screen: NSScreen, region: ScreenRegion = .fullScreen) async -> CGPoint? {
        guard let match = await findLabelScored(targetLabel, in: image, on: screen, region: region),
              match.score >= threshold else { return nil }
        return match.point
    }

    /// Finds `targetLabel` in the captured image of `screen`, optionally cropping
    /// to `region` first so e.g. a toolbar "Bold" doesn't compete with a dialog "Bold".
    /// `cropAXRect` (AX-global) overrides the region crop — used to focus a
    /// newly-opened window. Returns the best match with its confidence score
    /// (caller decides whether to accept), or nil if no text matched at all.
    /// Coords are AX global (top-left).
    func findLabelScored(_ targetLabel: String, in image: CGImage, on screen: NSScreen,
                         region: ScreenRegion = .fullScreen, cropAXRect: CGRect? = nil) async -> OCRMatch? {
        let trimmed = targetLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowerTarget = trimmed.lowercased()

        // Pixels per point for this capture.
        let scale = screen.frame.width > 0 ? CGFloat(image.width) / screen.frame.width : 1

        // Determine the OCR image + the crop origin/size in the screen's local points.
        var ocrImage = image
        var cropOriginLocal = CGPoint.zero
        var cropSizeLocal = screen.frame.size

        // Preferred crop: an explicit AX-global rect (a newly-opened window),
        // else the coarse screen region.
        let axTopOfScreen = ScreenCoordinates.primaryHeight - screen.frame.maxY
        var localCropRect: CGRect?
        if let axRect = cropAXRect {
            localCropRect = CGRect(x: axRect.minX - screen.frame.minX,
                                   y: axRect.minY - axTopOfScreen,
                                   width: axRect.width, height: axRect.height)
        } else if region != .fullScreen {
            localCropRect = ScreenRegionHelper.localRect(for: region, on: screen)
        }

        if let local = localCropRect {
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

        guard bestScore > 0, let obs = bestObs else { return nil }

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
        // Add the crop origin back so coords are relative to the full screen,
        // not the crop. This is the classic "found inside the crop but reported
        // crop-relative" bug — guarded here by always summing cropOriginLocal.
        let screenLocalX = cropOriginLocal.x + localX
        let screenLocalY = cropOriginLocal.y + localYFromTop

        // Screen-local (top-left) → AX global (top-left).
        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        let result = CGPoint(x: screen.frame.minX + screenLocalX, y: axTop + screenLocalY)

        // The matched text's full bounding rect in AX-global coords (top of the
        // text = 1 - box.maxY in the bottom-left-origin normalized space).
        let axFrame = CGRect(
            x: screen.frame.minX + cropOriginLocal.x + box.minX * cropSizeLocal.width,
            y: axTop + cropOriginLocal.y + (1.0 - box.maxY) * cropSizeLocal.height,
            width: box.width * cropSizeLocal.width,
            height: box.height * cropSizeLocal.height
        )

        DebugLogger.log("OCR", String(format: "best '%@' score=%.2f cropOrigin=(%.0f,%.0f) → ax=(%.0f,%.0f)",
            trimmed, bestScore, cropOriginLocal.x, cropOriginLocal.y, result.x, result.y))
        return OCRMatch(point: result, score: bestScore, frame: axFrame)
    }

    /// A compact comma-separated list of the text currently visible on screen
    /// (deduped, capped). Sent with the Nova request as free grounding — a
    /// vision model anchored to real on-screen words searches far better on
    /// busy screens. ~80ms, fully local.
    func visibleTextSummary(in image: CGImage, maxItems: Int = 40) async -> String {
        let results = await runOCRRaw(on: image)
        var seen = Set<String>()
        var items: [String] = []
        for obs in results {
            guard let text = obs.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 48 else { continue }
            guard seen.insert(text.lowercased()).inserted else { continue }
            items.append(text)
            if items.count >= maxItems { break }
        }
        return items.joined(separator: ", ")
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

    /// Recall-biased word-set similarity (0...1). The key idea: a match is strong
    /// when ALL target words are present in the observed text, even if the OCR
    /// line has extra words around it (OCR groups text into lines). A fragment
    /// like "Empty" still fails to match a longer target "Empty Bin" because a
    /// target word ("Bin") is MISSING.
    ///   - exact string match                          → 1.0
    ///   - same words, different order                 → 0.97
    ///   - all target words present (extras allowed)    → 0.82…0.95 (tighter = higher)
    ///   - some target words missing                    → low, recall-scaled
    ///   - single-word typos                            → Levenshtein ratio
    private func similarityScore(_ target: String, _ observed: String) -> Double {
        if target.isEmpty || observed.isEmpty { return 0 }
        if target == observed { return 1.0 }

        let aWords = words(target)   // target
        let bWords = words(observed) // observed on screen
        guard !aWords.isEmpty, !bWords.isEmpty else { return 0 }

        let aSet = Set(aWords), bSet = Set(bWords)
        if aSet == bSet { return 0.97 }

        let presentCount = aSet.filter { bSet.contains($0) }.count
        let recall = Double(presentCount) / Double(aSet.count)  // how much of target is found

        if recall >= 1.0 {
            // Every target word is present. Strong match regardless of extra
            // words in the OCR line. A mild precision term rewards tighter
            // matches so an exact-words observation outranks a longer line.
            let precision = Double(aSet.count) / Double(bSet.count)
            return 0.82 + 0.13 * precision   // 0.82 … 0.95
        }

        // A target word is missing — the dangerous "Empty Bin" vs "Empty" case.
        if aWords.count == 1 && bWords.count == 1 {
            // Single token on both sides: tolerate typos via Levenshtein.
            let distance = levenshtein(target, observed)
            let maxLen = max(target.count, observed.count)
            return maxLen > 0 ? max(0, 1.0 - Double(distance) / Double(maxLen)) : 0
        }
        return 0.45 * recall  // partial recall stays below threshold
    }

    /// Lowercased alphanumeric word tokens.
    private func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
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
