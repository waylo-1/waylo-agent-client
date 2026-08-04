import AppKit
import CoreGraphics

/// Layer 2.5: dual-model YOLO detection (OmniParser + Screen2AX) via the Railway
/// `/detect-elements` proxy → Python microservice. Called by CoordinateResolver
/// ONLY when L0 (AX), L1 (OCR) and the label cache have all missed, BEFORE the
/// paid Nova call (L3).
///
/// Coordinate conversion: YOLO returns 0–1 normalized, top-left origin. We map it
/// to AX-global coords using the CAPTURED screen's frame (so it's correct on
/// multi-monitor / non-primary displays), matching how L1/L3 convert.

// MARK: - Response models

struct YOLOElement: Decodable {
    let x: Double        // normalized 0-1, left edge
    let y: Double        // normalized 0-1, top edge
    let w: Double
    let h: Double
    let cx: Double       // center x, normalized 0-1
    let cy: Double       // center y, normalized 0-1
    let confidence: Double
    let source: String   // "screen2ax" | "omniparser"
    let axClass: String? // "AXButton", "AXLink", ... (nil for omniparser)
    /// RELATIVE: similarity softmaxed across the scored boxes. Says which box
    /// is most target-like — but a softmax always crowns a winner, even when
    /// the target isn't on screen at all.
    let matchScore: Double?
    /// ABSOLUTE: raw similarity (SigLIP: calibrated sigmoid probability) of
    /// this crop vs the target text. This is the "is the target actually here"
    /// check. Without gating on it, an absent target still yields a confident
    /// wrong winner — which is exactly how a desktop folder won a "Trash icon
    /// in the Dock" step.
    let matchConf: Double?
    /// Tier 2: zero-shot concept label for a textless icon ("search",
    /// "attach"), or nil when nothing matched distinctly.
    let caption: String?

    enum CodingKeys: String, CodingKey {
        case x, y, w, h, cx, cy, confidence, source, caption
        case axClass = "ax_class"
        case matchScore = "match_score"
        case matchConf = "match_conf"
    }
}

struct YOLODetectResponse: Decodable {
    let elements: [YOLOElement]
    let omniCount: Int
    let macosCount: Int
    let mergedCount: Int
    let matchApplied: Bool?

    enum CodingKeys: String, CodingKey {
        case elements
        case omniCount = "omni_count"
        case macosCount = "macos_count"
        case mergedCount = "merged_count"
        case matchApplied = "match_applied"
    }
}

private struct YOLOCandidate {
    let element: YOLOElement
    let axPoint: CGPoint
    let axFrame: CGRect
    let score: Double
}

// MARK: - YOLODetector

@MainActor
final class YOLODetector {
    static let shared = YOLODetector()
    private init() {}

    /// A successful detection: the click point plus the element's bounding
    /// rect (both AX-global), so the overlay can draw a region highlight.
    struct Detection {
        let point: CGPoint
        let frame: CGRect
        /// True when `frame` is the TOOLBAR CLUSTER (not the exact icon): YOLO
        /// couldn't confidently NAME the glyph but localized the icon row near
        /// the anchor. The caller highlights the whole area and describes the
        /// icon — free, and never a wrong dot.
        var approximate: Bool = false
    }

    /// Entry point. Returns the best matching element, or nil so
    /// CoordinateResolver falls through to L3 (Nova).
    /// Minimum ABSOLUTE match confidence. A SigLIP sigmoid probability below
    /// this means "the target text does not describe this crop" — regardless of
    /// how it ranks against the other boxes. Tuned conservatively: a miss costs
    /// one Nova call, a false accept points the user at the wrong thing.
    private static let minMatchConf = 0.10

    /// Stricter absolute SigLIP confidence required to accept a match on a WEB
    /// toolbar icon (strictWebIcon). Higher than minMatchConf because tiny
    /// packed browser glyphs produce confident-looking but wrong matches; below
    /// this we defer to Gemini rather than point wrong. Tuned conservatively —
    /// a miss costs one Gemini call, a false accept teaches the wrong thing.
    private static let strictWebMinConf = 0.22

    func detect(
        capture: ScreenCapturer.Capture,
        targetLabel: String,
        elementDescription: String,
        screenRegion: ScreenRegion,
        stepInstruction: String,
        restrictAXRect: CGRect? = nil,
        strictWebIcon: Bool = false,
        anchorPoint: CGPoint? = nil,
        anchorPosition: String = ""
    ) async -> Detection? {
        let image = capture.image
        let screen = capture.screen
        let regionRaw = screenRegion.rawValue

        DebugLogger.log("L2.5", "starting YOLO detection for '\(targetLabel)' region='\(regionRaw)'")

        // Reuse the shared compressor (normalized coords are scale-invariant, so
        // downscaling is safe and keeps the upload fast).
        guard let (b64, _) = ScreenCapturer.compressedJPEGBase64(image, maxWidth: 1280) else {
            DebugLogger.log("L2.5", "ERROR: failed to encode screenshot")
            return nil
        }

        let response: YOLODetectResponse
        do {
            response = try await WayloAPIClient.shared.detectElements(
                imageBase64: b64,
                targetLabel: targetLabel,
                stepInstruction: stepInstruction,
                screenRegion: regionRaw
            )
        } catch {
            DebugLogger.log("L2.5", "request failed: \(error.localizedDescription) — falling through to L3")
            DebugState.shared.yoloResult = "MISS (net)"
            return nil
        }

        DebugLogger.log("L2.5", "got \(response.mergedCount) elements (omni: \(response.omniCount), screen2ax: \(response.macosCount))")
        DebugState.shared.yoloElementCount = response.mergedCount

        guard !response.elements.isEmpty else {
            DebugLogger.log("L2.5", "no elements detected, falling through to L3")
            DebugState.shared.yoloResult = "MISS"
            return nil
        }

        // Tier 5 — ICON MEMORY: if we've located this exact icon before, match
        // it by perceptual hash among the YOLO boxes. Free, ~1ms, pixel-exact,
        // and skips the paid SigLIP/Nova path entirely. Tight Hamming gate, so
        // an unfamiliar screen simply falls through to normal scoring.
        let concept = targetLabel.isEmpty ? elementDescription : targetLabel
        if !IconMemory.shared.isEmpty {
            var cgCrops: [CGImage] = []
            var boxIndex: [Int] = []
            for (i, el) in response.elements.enumerated() {
                // WEB-CONTENT restriction: only remember/recall icons that sit
                // inside the page area, so a chrome glyph can't pixel-match a
                // page icon's memory.
                if let rect = restrictAXRect {
                    let boxCenter = normalizedToAXPoint(cx: el.cx, cy: el.cy, screen: screen)
                    if !rect.insetBy(dx: -8, dy: -8).contains(boxCenter) { continue }
                }
                if let c = image.cropNormalized(x: el.x, y: el.y, w: el.w, h: el.h) {
                    cgCrops.append(c); boxIndex.append(i)
                }
            }
            if let hit = IconMemory.shared.bestMatch(crops: cgCrops,
                                                     app: TargetAppTracker.shared.targetName,
                                                     concept: concept) {
                let el = response.elements[boxIndex[hit]]
                let point = normalizedToAXPoint(cx: el.cx, cy: el.cy, screen: screen)
                let frame = normalizedToAXRect(x: el.x, y: el.y, w: el.w, h: el.h, screen: screen)
                DebugLogger.log("L2.5", "ICON MEMORY hit — pixel-exact, skipping semantic match")
                DebugState.shared.update(layer: "Icon memory", dot: point)
                return Detection(point: point, frame: frame)
            }
        }

        // "… in the Dock" targets must land inside the Dock. Deterministic and
        // free: the Dock's real frame comes from AX, no model can override it.
        var dockOnly: CGRect?
        let contextText = "\(elementDescription) \(stepInstruction)".lowercased()
        if contextText.contains("dock") {
            dockOnly = await MainActor.run { AccessibilityReader.shared.dockFrame() }
            if let d = dockOnly {
                DebugLogger.log("L2.5", "Dock target → restricting to Dock frame \(Int(d.width))x\(Int(d.height)) at (\(Int(d.minX)),\(Int(d.minY)))")
            }
        }

        // A web-content step restricts the field to the page area (dock target
        // constraint, when present, is even tighter and wins).
        guard let best = selectBestMatch(
            elements: response.elements,
            targetLabel: targetLabel,
            elementDescription: elementDescription,
            screenRegion: screenRegion,
            screen: screen,
            restrictTo: dockOnly ?? restrictAXRect,
            strictWebIcon: strictWebIcon
        ) else {
            // Strict web naming failed — but YOLO still DETECTED the toolbar's
            // icon boxes. Localize that cluster near the anchor (free) so the
            // caller can square-over-toolbar + describe, no Gemini call. This is
            // the whole point: YOLO already knows WHERE the row is, it just
            // can't reliably NAME the 30px glyph.
            if strictWebIcon, let anchor = anchorPoint,
               let region = toolbarRegionNearAnchor(response.elements, anchor: anchor,
                                                    anchorPosition: anchorPosition, screen: screen,
                                                    restrict: restrictAXRect) {
                DebugLogger.log("L2.5", "named match failed → localized toolbar cluster near anchor: region \(Int(region.width))x\(Int(region.height)) (free, no Gemini)")
                DebugState.shared.yoloResult = "REGION (cluster)"
                return Detection(point: CGPoint(x: region.midX, y: region.midY), frame: region, approximate: true)
            }
            DebugLogger.log("L2.5", "no element matched semantic criteria, falling through to L3")
            DebugState.shared.yoloResult = "MISS (no match)"
            return nil
        }

        let cls = best.element.axClass ?? "-"
        DebugLogger.log("L2.5",
            "MATCH source=\(best.element.source) ax_class=\(cls) " +
            "conf=\(String(format: "%.2f", best.element.confidence)) score=\(String(format: "%.2f", best.score)) " +
            "point=(\(Int(best.axPoint.x)),\(Int(best.axPoint.y)))")
        DebugLogger.logResolution("L2.5", found: true, point: best.axPoint, label: targetLabel)
        DebugState.shared.yoloResult = "HIT \(best.element.source) \(cls) \(String(format: "%.2f", best.element.confidence))"
        DebugState.shared.update(layer: "L2.5 \(best.element.source)", dot: best.axPoint)
        return Detection(point: best.axPoint, frame: best.axFrame)
    }

    // MARK: - Semantic matching

    private func selectBestMatch(
        elements: [YOLOElement],
        targetLabel: String,
        elementDescription: String,
        screenRegion: ScreenRegion,
        screen: NSScreen,
        restrictTo: CGRect? = nil,
        strictWebIcon: Bool = false
    ) -> YOLOCandidate? {
        let expectedAXClass = inferExpectedAXClass(
            targetLabel: targetLabel.lowercased(),
            elementDescription: elementDescription.lowercased()
        )

        var candidates: [YOLOCandidate] = []
        for element in elements {
            let axPoint = normalizedToAXPoint(cx: element.cx, cy: element.cy, screen: screen)
            let axFrame = normalizedToAXRect(x: element.x, y: element.y, w: element.w, h: element.h, screen: screen)

            guard isValidAXPoint(axPoint, screenRegion: screenRegion, screen: screen) else { continue }
            // Hard geometric constraint (e.g. Dock) — no score can override it.
            if let rect = restrictTo, !rect.insetBy(dx: -10, dy: -10).contains(axPoint) { continue }

            var score = 0.0
            // CLIP semantic match vs the step's target text — the strongest
            // signal when the service computed it (it's what actually ties a
            // box to THIS step's target).
            if let ms = element.matchScore { score += ms * 0.8 }
            // AX class match (Screen2AX only).
            if let axClass = element.axClass, let expected = expectedAXClass, axClass == expected {
                score += 0.5
            }
            // Source bonus: Screen2AX is more reliable for native macOS.
            if element.source == "screen2ax" { score += 0.1 }
            // Model confidence.
            score += element.confidence * 0.3
            // Region match bonus (already validated above, so always in-region).
            score += 0.1

            candidates.append(YOLOCandidate(element: element, axPoint: axPoint, axFrame: axFrame, score: score))
        }

        let minScore = 0.3
        guard let winner = candidates.max(by: { $0.score < $1.score }), winner.score >= minScore else {
            return nil
        }

        // A detection is only accepted when something ties it to THIS step's
        // target — otherwise any confident box in the region would "win" and a
        // wrong dot blocks the far more accurate Nova fallback. Accept when:
        //   - CLIP says this box is the semantic winner (decisively), or
        //   - the expected AX class matched, or
        //   - the region narrowed the field to a single unambiguous candidate.
        let ms = winner.element.matchScore ?? 0
        let conf = winner.element.matchConf ?? 0
        let runnerUpMS = candidates
            .filter { $0.element.matchScore != nil && $0.axPoint != winner.axPoint }
            .map { $0.element.matchScore! }.max() ?? 0

        // ABSOLUTE gate first: a softmax always crowns a winner, even when the
        // target isn't on screen. If the model doesn't independently believe
        // this crop matches the target text, NOTHING here is acceptable —
        // defer to Nova rather than confidently point at the wrong thing.
        if winner.element.matchConf != nil && conf < Self.minMatchConf {
            DebugLogger.log("L2.5", "REJECTED: matchScore=\(String(format: "%.2f", ms)) looks decisive but absolute conf=\(String(format: "%.3f", conf)) < \(Self.minMatchConf) — target likely NOT among the boxes → L3 Nova")
            return nil
        }

        let semanticWinner = ms >= 0.35 && ms >= runnerUpMS * 1.5
        let classMatched = expectedAXClass != nil
            && winner.element.axClass == expectedAXClass
        let unambiguous = candidates.count == 1 && winner.element.confidence >= 0.5

        // WEB TOOLBAR: every glyph is an AXImage packed side by side, so
        // class-match and single-candidate mean nothing, and SigLIP naming of a
        // 30px glyph is shaky. Demand a REAL semantic winner with genuine
        // absolute confidence; anything less defers to Gemini (paid, accurate,
        // and it also returns the container+hint for the region fallback). This
        // keeps YOLO free-first on the web without letting it point wrong.
        if strictWebIcon {
            guard semanticWinner, conf >= Self.strictWebMinConf else {
                DebugLogger.log("L2.5", "web icon NOT a confident semantic winner (ms=\(String(format: "%.2f", ms)) conf=\(String(format: "%.3f", conf))) → defer to Gemini")
                return nil
            }
        } else {
            guard semanticWinner || classMatched || unambiguous else {
                DebugLogger.log("L2.5", "best candidate rejected (matchScore=\(String(format: "%.2f", ms)), no class match, \(candidates.count) candidates) — deferring to L3 Nova")
                return nil
            }
        }
        if semanticWinner {
            DebugLogger.log("L2.5", "semantic winner: score=\(String(format: "%.2f", ms)) (runner-up \(String(format: "%.2f", runnerUpMS))) conf=\(String(format: "%.3f", conf))")
        }
        return winner
    }

    /// The bounding rect of the ICON ROW (toolbar) that contains the target,
    /// derived from YOLO's own detected boxes near the anchor — no Gemini. We
    /// take the small, icon-sized boxes that sit in the same horizontal band as
    /// the anchor and on the requested side of it, then union them. The anchor
    /// landmark itself is EXCLUDED (it may be a destructive control like Send —
    /// the highlighted, click-to-advance area must not contain it). nil when
    /// there's no clear cluster (→ caller falls through to Gemini).
    private func toolbarRegionNearAnchor(_ elements: [YOLOElement], anchor: CGPoint,
                                         anchorPosition: String, screen: NSScreen,
                                         restrict: CGRect?) -> CGRect? {
        let bandTol: CGFloat = 26          // "same row" as the anchor
        let side = anchorPosition.lowercased()
        var boxes: [CGRect] = []
        for el in elements {
            let f = normalizedToAXRect(x: el.x, y: el.y, w: el.w, h: el.h, screen: screen)
            // Icon-sized only — skip big content/text boxes.
            guard f.width >= 8, f.height >= 8, f.width <= 90, f.height <= 90 else { continue }
            if let r = restrict, !r.insetBy(dx: -8, dy: -8).intersects(f) { continue }
            guard abs(f.midY - anchor.y) <= bandTol else { continue }          // same row
            if f.insetBy(dx: -4, dy: -4).contains(anchor) { continue }          // not the landmark
            switch side {                                                       // correct side
            case "right": if f.midX < anchor.x { continue }
            case "left":  if f.midX > anchor.x { continue }
            default: break
            }
            boxes.append(f)
        }
        guard boxes.count >= 2 else { return nil }   // a real row, not one stray box
        // Keep only the CONTIGUOUS run of icons out from the anchor — stop at the
        // first big horizontal gap so we box the actual toolbar, not far-flung
        // page elements that happen to share the row (that's why the paperclip
        // square spanned 588px to the screen edge).
        let maxGap: CGFloat = 64
        let ordered = side == "left" ? boxes.sorted { $0.maxX > $1.maxX }   // right→left from anchor
                                     : boxes.sorted { $0.minX < $1.minX }   // left→right from anchor
        var kept = [ordered[0]]
        for b in ordered.dropFirst() {
            let gap = side == "left" ? (kept.last!.minX - b.maxX) : (b.minX - kept.last!.maxX)
            if gap > maxGap { break }
            kept.append(b)
        }
        guard kept.count >= 2 else { return nil }
        var region = kept[0]
        for b in kept.dropFirst() { region = region.union(b) }
        // A toolbar is a short horizontal strip; if the union is tall it's not a
        // single row (bad cluster) — bail to Gemini rather than box a big area.
        guard region.height <= 70 else { return nil }
        return region.insetBy(dx: -10, dy: -8)
    }

    // MARK: - Coordinate conversion (YOLO normalized → AX global)

    /// YOLO uses 0–1 normalized, top-left origin. Convert to AX-global logical
    /// points using the captured screen's frame so multi-monitor / non-primary
    /// displays resolve correctly (consistent with LocalVisionDetector / Nova).
    private func normalizedToAXPoint(cx: Double, cy: Double, screen: NSScreen) -> CGPoint {
        let localX = CGFloat(cx) * screen.frame.width
        let localY = CGFloat(cy) * screen.frame.height
        let axX = screen.frame.minX + localX
        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        let axY = axTop + localY
        return CGPoint(x: axX, y: axY)
    }

    /// Normalized 0–1 top-left box → AX-global rect (same mapping as the point).
    private func normalizedToAXRect(x: Double, y: Double, w: Double, h: Double, screen: NSScreen) -> CGRect {
        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        return CGRect(
            x: screen.frame.minX + CGFloat(x) * screen.frame.width,
            y: axTop + CGFloat(y) * screen.frame.height,
            width: CGFloat(w) * screen.frame.width,
            height: CGFloat(h) * screen.frame.height
        )
    }

    // MARK: - Validation

    private func isValidAXPoint(_ point: CGPoint, screenRegion: ScreenRegion, screen: NSScreen) -> Bool {
        // Must be within the union of all displays (AX space).
        guard ScreenCoordinates.axGlobalBounds.insetBy(dx: -1, dy: -1).contains(point) else { return false }

        // AX y is measured from the top of the primary display.
        let bottom = ScreenCoordinates.primaryHeight
        switch screenRegion {
        case .menuBar:   return point.y < 50
        case .ribbon:    return point.y < 160
        case .sidebar:   return point.x < 350
        case .statusBar: return point.y > bottom - 50
        default:         return true
        }
    }

    // MARK: - AX class inference

    /// Infer the expected Screen2AX class from the step's keywords.
    private func inferExpectedAXClass(targetLabel: String, elementDescription: String) -> String? {
        let c = "\(targetLabel) \(elementDescription)"
        if c.contains("button") || c.contains("btn") || c.contains("click") || c.contains("press") { return "AXButton" }
        if c.contains("link") || c.contains("url") || c.contains("href") { return "AXLink" }
        if c.contains("text") || c.contains("input") || c.contains("field") || c.contains("type") || c.contains("search") || c.contains("enter") { return "AXTextArea" }
        if c.contains("expand") || c.contains("collapse") || c.contains("triangle") || c.contains("arrow") || c.contains("disclosure") { return "AXDisclosureTriangle" }
        if c.contains("image") || c.contains("icon") || c.contains("logo") || c.contains("photo") { return "AXImage" }
        return nil
    }

    // MARK: - Training data collection

    /// UserDefaults key for the OPT-IN screenshot capture. Off by default —
    /// the core privacy rule is "screenshots never touch disk", so saving
    /// training images requires an explicit user decision (dev-tools toggle).
    static let captureTrainingImagesKey = "waylo.captureTrainingImages"

    /// Writes ONE user-verified training example to the local JSONL (+ image
    /// when the user opted in). Called only from `TrainingHarvest.commitVerified()`
    /// — never straight off a raw detection, because an unconfirmed box may be
    /// wrong and would poison the training set.
    nonisolated func writeTrainingExample(_ example: TrainingHarvest.Example) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Sahayak", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "app_name": example.appName,
            "target_label": example.targetLabel,
            "control_kind": example.controlKind,
            "screen_region": example.screenRegion,
            "bbox_0_1000": example.bbox,
            "image_pixel_width": example.pixelWidth,
            "image_pixel_height": example.pixelHeight,
            "verified": true,
        ]

        // Image (opt-in only) written next to the log so the example is
        // actually trainable — bbox-only rows have no pixels to learn from.
        if let b64 = example.imageBase64, let jpeg = Data(base64Encoded: b64) {
            let imagesDir = dir.appendingPathComponent("training_images", isDirectory: true)
            try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(example.stepIndex).jpg"
            if (try? jpeg.write(to: imagesDir.appendingPathComponent(name))) != nil {
                entry["image_file"] = "training_images/\(name)"
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let file = dir.appendingPathComponent("yolo_training_log.jsonl")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.data(using: .utf8)?.write(to: file)
        }
        DebugLogger.log("HARVEST", "wrote verified example '\(example.targetLabel)'\(entry["image_file"] != nil ? " (with image)" : " (bbox only)")")
    }
}
