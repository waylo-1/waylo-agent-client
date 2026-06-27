import AppKit

/// Orchestrates the layered element-location pipeline. Returns a point in AX
/// global coordinates (what OverlayWindowController.showDot expects).
///
/// Layer order:
///   1. Apple Vision OCR        — on-device, ~80ms, free (handles most steps)
///   2. CoreML YOLO             — stub for icon-only buttons (always nil today)
///   3. Accessibility tree      — free, pixel-exact for native macOS apps
///   4. Nova Pro (Bedrock)      — cloud last resort (weak grounding)
@MainActor
final class CoordinateResolver {
    static let shared = CoordinateResolver()

    private let visionDetector = LocalVisionDetector()
    private let yoloDetector = YOLODetector()
    private let novaFallback = NovaVisionFallback()

    private init() {}

    struct Resolution {
        let axPoint: CGPoint
        /// A refined instruction if a cloud layer produced one (else empty).
        let updatedInstruction: String
    }

    func resolve(
        capture: ScreenCapturer.Capture,
        targetLabel: String,
        elementDescription: String,
        stepInstruction: String,
        findDescription: String,
        screenRegion: ScreenRegion,
        task: String,
        stepIndex: Int,
        totalSteps: Int
    ) async -> Resolution? {
        let image = capture.image
        let screen = capture.screen

        // --- Layer 0: Accessibility tree (region-filtered) — free, exact -----
        if !targetLabel.isEmpty, let element = axSearch(targetLabel, region: screenRegion, screen: screen) {
            print("[Resolver] L0 AX hit '\(element.title)' \(element.center)")
            return Resolution(axPoint: element.center, updatedInstruction: "")
        }
        let axQuery = elementDescription.isEmpty ? findDescription : elementDescription
        if let element = axSearch(axQuery, region: screenRegion, screen: screen) {
            print("[Resolver] L0 AX hit (desc) '\(element.title)' \(element.center)")
            return Resolution(axPoint: element.center, updatedInstruction: "")
        }
        print("[Resolver] L0 AX miss")

        // --- Layer 1: Region-aware Apple Vision OCR ------------------------
        let candidates = ocrCandidates(
            targetLabel: targetLabel,
            elementDescription: elementDescription,
            instruction: stepInstruction
        )
        for label in candidates {
            if let point = await visionDetector.findLabel(label, in: image, on: screen, region: screenRegion) {
                print("[Resolver] L1 OCR hit '\(label)' \(point)")
                return Resolution(axPoint: point, updatedInstruction: "")
            }
            // Retry full-screen if the region crop missed (region hint may be off).
            if screenRegion != .fullScreen,
               let point = await visionDetector.findLabel(label, in: image, on: screen, region: .fullScreen) {
                print("[Resolver] L1 OCR hit (fullScreen) '\(label)' \(point)")
                return Resolution(axPoint: point, updatedInstruction: "")
            }
        }
        print("[Resolver] L1 OCR miss")

        // --- Layer 2: CoreML YOLO (stub) -----------------------------------
        if let point = await yoloDetector.findElement(elementDescription, in: image, on: screen) {
            print("[Resolver] L2 hit \(point)")
            return Resolution(axPoint: point, updatedInstruction: "")
        }

        // --- Label cache: a prior working relabel — try it before paying for Nova
        let appName = TargetAppTracker.shared.targetName
        let cacheKey = elementDescription.isEmpty ? stepInstruction : elementDescription
        if !appName.isEmpty, !cacheKey.isEmpty,
           let cachedLabel = await WayloAPIClient.shared.lookupLabel(appName: appName, stepDescription: cacheKey) {
            if let element = axSearch(cachedLabel, region: screenRegion, screen: screen) {
                print("[Resolver] label-cache AX hit '\(cachedLabel)'")
                return Resolution(axPoint: element.center, updatedInstruction: "")
            }
            if let point = await visionDetector.findLabel(cachedLabel, in: image, on: screen, region: screenRegion) {
                print("[Resolver] label-cache OCR hit '\(cachedLabel)'")
                return Resolution(axPoint: point, updatedInstruction: "")
            }
        }

        // --- Layer 3: Nova 2 Lite fallback ---------------------------------
        guard ScreenRecordingPermission.isGranted else { return nil }
        print("[Resolver] L3 Nova fallback")
        if let result = await novaFallback.findElement(
            targetLabel: targetLabel,
            elementDescription: elementDescription,
            stepInstruction: stepInstruction,
            task: task,
            stepIndex: stepIndex,
            totalSteps: totalSteps,
            image: image,
            screen: screen
        ) {
            if let point = result.axPoint {
                print("[Resolver] L3 hit \(point)")
                return Resolution(axPoint: point, updatedInstruction: result.updatedInstruction)
            }
            let refined = result.updatedFindDescription
            if !refined.isEmpty {
                if let element = axSearch(refined, region: screenRegion, screen: screen) {
                    return Resolution(axPoint: element.center, updatedInstruction: result.updatedInstruction)
                }
                if let point = await visionDetector.findLabel(refined, in: image, on: screen, region: screenRegion) {
                    return Resolution(axPoint: point, updatedInstruction: result.updatedInstruction)
                }
            }
        }

        print("[Resolver] all layers failed for '\(targetLabel)'")
        return nil
    }

    /// Accessibility-tree search filtered to the given region.
    private func axSearch(_ query: String, region: ScreenRegion, screen: NSScreen) -> AXElementInfo? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let all = AccessibilityReader.shared.getTargetAppElements()
        guard !all.isEmpty else { return nil }

        let candidates: [AXElementInfo]
        if region != .fullScreen, let rect = ScreenRegionHelper.axGlobalRect(for: region, on: screen) {
            let expanded = rect.insetBy(dx: -24, dy: -24)
            let filtered = all.filter { expanded.intersects($0.frame) }
            candidates = filtered.isEmpty ? all : filtered // fall back to all if region empties
        } else {
            candidates = all
        }
        return ElementFinder.shared.findElement(description: query, in: candidates)
    }

    /// Builds an ordered, de-duplicated list of text labels to try via OCR.
    /// Prefers the explicit targetLabel, then quoted phrases, then capitalized
    /// words from the instruction/description.
    private func ocrCandidates(targetLabel: String, elementDescription: String, instruction: String) -> [String] {
        var result: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, !result.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
            result.append(t)
        }

        if !targetLabel.isEmpty { add(targetLabel) }

        // Quoted phrases like “Export” or "New Folder".
        for text in [instruction, elementDescription] {
            for match in quotedPhrases(in: text) { add(match) }
        }

        // Capitalized words / runs (File, Export, New Folder) from instruction.
        for run in capitalizedRuns(in: instruction) { add(run) }

        return result
    }

    private func quotedPhrases(in text: String) -> [String] {
        var phrases: [String] = []
        // Straight and curly quotes.
        let pattern = "[\"'\u{201C}\u{2018}]([^\"'\u{201D}\u{2019}]{2,40})[\"'\u{201D}\u{2019}]"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                phrases.append(ns.substring(with: m.range(at: 1)))
            }
        }
        return phrases
    }

    private func capitalizedRuns(in text: String) -> [String] {
        let stop: Set<String> = ["the", "a", "an", "click", "tap", "select", "press", "open", "your", "on", "at", "in", "to", "of", "and", "now", "first", "then", "next"]
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var runs: [String] = []
        var current: [String] = []
        for word in words {
            let isCap = word.first?.isUppercase == true && !stop.contains(word.lowercased())
            if isCap {
                current.append(word)
            } else {
                if !current.isEmpty { runs.append(current.joined(separator: " ")); current = [] }
            }
        }
        if !current.isEmpty { runs.append(current.joined(separator: " ")) }
        // Also include individual capitalized words.
        for word in words where word.first?.isUppercase == true && !stop.contains(word.lowercased()) && word.count >= 2 {
            runs.append(word)
        }
        return runs
    }
}
