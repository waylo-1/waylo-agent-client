import AppKit

/// Orchestrates the layered element-location pipeline. Returns a point in AX
/// global coordinates (what OverlayWindowController.showDot expects).
///
/// The flow BRANCHES on targetType/controlKind (cheapest, most private first):
///   - plain text target      → OCR first (visual ground truth), then AX
///   - real control (button…) → AX first (role/anchor beat header text), OCR fallback
///   - icon target             → AX-by-description → label cache → YOLO (L2.5) → Nova (L3)
/// `localOnly` (scroll-assist polling) stops after AX + OCR — no network.
/// Every Nova hit is harvested: label cached for next-run AX resolution and a
/// YOLO training example logged.
@MainActor
final class CoordinateResolver {
    static let shared = CoordinateResolver()

    private let visionDetector = LocalVisionDetector()
    private let novaFallback = NovaVisionFallback()

    private init() {}

    struct Resolution {
        let axPoint: CGPoint
        /// A refined instruction if a cloud layer produced one (else empty).
        let updatedInstruction: String
        /// The AX element when L0 resolved — lets assist mode press it via
        /// AXUIElementPerformAction instead of a synthetic click.
        var axElement: AXUIElement? = nil
        /// Near-tied CONFIDENT matches at other locations ("Empty" in three
        /// places). Non-empty means the resolver refuses to guess — the engine
        /// shows numbered badges and lets the user pick.
        var alternates: [CGPoint] = []
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
        totalSteps: Int,
        cacheKey: String = "",
        localOnly: Bool = false,
        targetType: StepTargetType = .text,
        controlKind: String = "",
        anchorText: String = "",
        anchorPosition: String = ""
    ) async -> Resolution? {
        let image = capture.image
        let screen = capture.screen

        DebugLogger.log("RESOLVE", "start target='\(targetLabel)' desc='\(elementDescription)' region=\(screenRegion) step=\(stepIndex)/\(totalSteps)")
        DebugState.shared.update(targetApp: TargetAppTracker.shared.targetName, layer: "resolving…", screen: screen.frame)

        // Resolve an anchor location (nearby text the planner gave) once, so AX
        // can prefer the target in the right direction from it.
        var anchorInfo: (point: CGPoint, position: String)?
        if !anchorText.isEmpty {
            if let el = axSearch(anchorText, region: screenRegion, screen: screen) {
                anchorInfo = (el.center, anchorPosition)
            } else if let m = await visionDetector.findLabelScored(anchorText, in: image, on: screen, region: .fullScreen), m.score >= 0.8 {
                anchorInfo = (m.point, anchorPosition)
            }
            if let a = anchorInfo { DebugLogger.log("RESOLVE", "anchor '\(anchorText)' at (\(Int(a.point.x)),\(Int(a.point.y))) pos=\(anchorPosition)") }
        }

        let isControl = ElementFinder.isControlKind(controlKind)

        // Plain TEXT/label targets: OCR first (visual ground truth). For real
        // CONTROLS (buttons etc.) we run AX first so role/anchor can pick the
        // actual control over plain header text — OCR is the control's fallback.
        if targetType == .text && !isControl {
            if let p = await locateByOCR(targetLabel: targetLabel, elementDescription: elementDescription,
                                         instruction: stepInstruction, image: image, screen: screen, region: screenRegion) {
                return Resolution(axPoint: p, updatedInstruction: "")
            }
        }

        // --- Layer 0: Accessibility tree (role + anchor aware) -------------
        if !targetLabel.isEmpty,
           let found = axSearchDetailed(targetLabel, region: screenRegion, screen: screen, allowSystemUI: true,
                                        preferredRole: controlKind, anchor: anchorInfo) {
            let element = found.best
            print("[Resolver] L0 AX hit '\(element.title)' \(element.center)")
            DebugLogger.logResolution("L0-AX", found: true, point: element.center, label: "\(element.title) [\(element.role)]")
            DebugState.shared.update(layer: "L0 AX", dot: element.center)
            return Resolution(axPoint: element.center, updatedInstruction: "",
                              axElement: element.axElement,
                              alternates: found.alternates.map(\.center))
        }
        let axQuery = elementDescription.isEmpty ? findDescription : elementDescription
        // The verbose description is only used for AX when there's NO precise
        // targetLabel, or for icon targets (which rely on AXDescription/tooltips).
        // For a labelled text target it pollutes the match — e.g. matching the
        // "System Settings" header for an "Appearance" step — so we skip it.
        if (targetType == .icon || targetLabel.isEmpty),
           let element = axSearch(axQuery, region: screenRegion, screen: screen, allowSystemUI: false,
                                  preferredRole: controlKind, anchor: anchorInfo) {
            if passesRegion(element.center, screenRegion, screen: screen) {
                print("[Resolver] L0 AX hit (desc) '\(element.title)' \(element.center)")
                DebugLogger.logResolution("L0-AX-desc", found: true, point: element.center, label: element.title)
                DebugState.shared.update(layer: "L0 AX (desc)", dot: element.center)
                return Resolution(axPoint: element.center, updatedInstruction: "", axElement: element.axElement)
            }
            DebugLogger.log("RESOLVE", "REGION_MISMATCH L0-AX-desc '\(element.title)' \(element.center) region=\(screenRegion) — trying next layer")
        }
        print("[Resolver] L0 AX miss")
        DebugLogger.logResolution("L0-AX", found: false, point: nil, label: axQuery)

        // CONTROL targets: OCR fallback after AX (a button's text sits on it, so
        // OCR of the label still lands on the control).
        if targetType == .text && isControl {
            if let p = await locateByOCR(targetLabel: targetLabel, elementDescription: elementDescription,
                                         instruction: stepInstruction, image: image, screen: screen, region: screenRegion) {
                return Resolution(axPoint: p, updatedInstruction: "")
            }
        }

        // Fast path for the scroll-assist polling loop: AX + OCR only, no network.
        if localOnly { return nil }

        // --- Label cache (between L2 and L3): a prior working label. If found,
        // try AX (L0) ONLY with it — a hit lets us skip the costly L3 vision call.
        let appName = TargetAppTracker.shared.targetName
        if !appName.isEmpty, !cacheKey.isEmpty,
           let cachedLabel = await WayloAPIClient.shared.lookupLabel(appName: appName, stepDescription: cacheKey) {
            DebugState.shared.update(cache: "HIT \(cachedLabel)")
            DebugLogger.log("RESOLVE", "LABEL_CACHE lookup HIT '\(cachedLabel)'")
            if let element = axSearch(cachedLabel, region: screenRegion, screen: screen, allowSystemUI: true),
               passesRegion(element.center, screenRegion, screen: screen) {
                DebugLogger.log("RESOLVE", "LABEL_CACHE_HIT, skipped L3 — '\(cachedLabel)' \(element.center)")
                DebugLogger.logResolution("label-cache-AX", found: true, point: element.center, label: cachedLabel)
                DebugState.shared.update(layer: "cache→L0 AX", dot: element.center)
                return Resolution(axPoint: element.center, updatedInstruction: "", axElement: element.axElement)
            }
            // Cache hit but AX still can't find it — fall through to L3 as normal.
            DebugLogger.log("RESOLVE", "cache label '\(cachedLabel)' present but L0 missed — continuing to L3")
        } else {
            DebugState.shared.update(cache: "MISS")
            DebugLogger.log("RESOLVE", "LABEL_CACHE lookup MISS")
        }

        // --- Layer 2.5: Dual-model YOLO (OmniParser + Screen2AX) -----------
        // For ICON / logo targets (the planner marks these). YOLO locates icons
        // that have no readable text; text targets skip it and go to Nova.
        if targetType == .icon || targetLabel.isEmpty {
            DebugLogger.log("PIPELINE", "icon target → trying L2.5 YOLO")
            if let point = await YOLODetector.shared.detect(
                capture: capture,
                targetLabel: targetLabel,
                elementDescription: elementDescription,
                screenRegion: screenRegion,
                stepInstruction: stepInstruction
            ) {
                DebugLogger.log("PIPELINE", "L2.5 HIT at (\(Int(point.x)),\(Int(point.y)))")
                return Resolution(axPoint: point, updatedInstruction: "")
            }
            DebugLogger.log("PIPELINE", "L2.5 miss → falling through to L3 Nova")
        } else {
            DebugLogger.log("PIPELINE", "L2.5 skipped (text target '\(targetLabel)') → L3 Nova")
        }

        // --- Layer 3: Nova 2 Lite fallback ---------------------------------
        guard ScreenRecordingPermission.isGranted else {
            DebugLogger.log("RESOLVE", "L3 skipped — Screen Recording permission NOT granted")
            DebugState.shared.update(layer: "FAILED (no screen perm)")
            return nil
        }
        print("[Resolver] L3 Nova fallback")
        DebugLogger.log("RESOLVE", "L3 Nova fallback invoked")
        // Fold any positional anchor into the description so Nova aims correctly
        // (e.g. "Send button … (located to the right of 'Add a caption')").
        var novaDescription = elementDescription
        if !anchorText.isEmpty && !anchorPosition.isEmpty {
            novaDescription += " (located to the \(anchorPosition) of \"\(anchorText)\")"
        }
        if let result = await novaFallback.findElement(
            targetLabel: targetLabel,
            elementDescription: novaDescription,
            stepInstruction: stepInstruction,
            task: task,
            stepIndex: stepIndex,
            totalSteps: totalSteps,
            image: image,
            screen: screen
        ) {
            if let point = result.axPoint {
                print("[Resolver] L3 hit \(point)")
                DebugLogger.logResolution("L3-Nova", found: true, point: point, label: targetLabel)
                DebugState.shared.update(layer: "L3 Nova", dot: point)
                // Cache the working label so the next run of this step resolves
                // via AX (L0) and skips L1/L2/L3 entirely. Fire-and-forget.
                if !appName.isEmpty, !cacheKey.isEmpty, !result.novaLabel.isEmpty {
                    WayloAPIClient.shared.storeLabel(appName: appName, stepDescription: cacheKey, axLabel: result.novaLabel)
                    DebugLogger.log("RESOLVE", "LABEL_CACHE_STORED: \(result.novaLabel)")
                    DebugState.shared.update(cache: "STORED \(result.novaLabel)")
                }
                // Log a labelled example for future YOLO fine-tuning.
                if let bbox = result.rawBBox {
                    let app = appName.isEmpty ? TargetAppTracker.shared.targetName : appName
                    YOLODetector.shared.logTrainingExample(
                        appName: app,
                        targetLabel: targetLabel,
                        screenRegion: screenRegion.rawValue,
                        novaBBox: bbox,
                        pixelWidth: image.width,
                        pixelHeight: image.height
                    )
                }
                return Resolution(axPoint: point, updatedInstruction: result.updatedInstruction)
            }
            let refined = result.updatedFindDescription
            if !refined.isEmpty {
                if let element = axSearch(refined, region: screenRegion, screen: screen) {
                    DebugLogger.logResolution("L3-Nova-refine-AX", found: true, point: element.center, label: refined)
                    DebugState.shared.update(layer: "L3 Nova→AX", dot: element.center)
                    return Resolution(axPoint: element.center, updatedInstruction: result.updatedInstruction, axElement: element.axElement)
                }
                if let point = await visionDetector.findLabel(refined, in: image, on: screen, region: screenRegion) {
                    DebugLogger.logResolution("L3-Nova-refine-OCR", found: true, point: point, label: refined)
                    DebugState.shared.update(layer: "L3 Nova→OCR", dot: point)
                    return Resolution(axPoint: point, updatedInstruction: result.updatedInstruction)
                }
            }
        }

        print("[Resolver] all layers failed for '\(targetLabel)'")
        DebugLogger.logResolution("FAILED", found: false, point: nil, label: targetLabel)
        DebugState.shared.update(layer: "FAILED (all layers)")
        return nil
    }

    /// Dev tool: runs EVERY detection layer independently against `label` and
    /// returns one human-readable result line per layer (hit point or miss).
    /// Backs the panel's "layer self-test" so each layer can be verified in
    /// isolation on the real screen.
    func diagnose(capture: ScreenCapturer.Capture, label: String) async -> [String] {
        var lines: [String] = []
        let screen = capture.screen
        let appName = TargetAppTracker.shared.targetName
        lines.append("target app: \(appName.isEmpty ? "?" : appName)")

        if let el = axSearch(label, region: .fullScreen, screen: screen, allowSystemUI: true) {
            let title = el.title.isEmpty ? el.description : el.title
            lines.append("L0 AX: HIT '\(title)' [\(el.role)] (\(Int(el.center.x)),\(Int(el.center.y)))")
        } else {
            lines.append("L0 AX: miss")
        }

        if let m = await visionDetector.findLabelScored(label, in: capture.image, on: screen, region: .fullScreen) {
            let verdict = m.score >= 0.8 ? "HIT" : "below 0.8 → reject"
            lines.append(String(format: "L1 OCR: score %.2f (%d,%d) — %@", m.score, Int(m.point.x), Int(m.point.y), verdict))
        } else {
            lines.append("L1 OCR: no text matched at all")
        }

        if let cached = await WayloAPIClient.shared.lookupLabel(appName: appName, stepDescription: label) {
            lines.append("Label cache: HIT '\(cached)'")
        } else {
            lines.append("Label cache: miss")
        }

        if let p = await YOLODetector.shared.detect(capture: capture, targetLabel: label,
                                                    elementDescription: label, screenRegion: .fullScreen,
                                                    stepInstruction: "find \(label)") {
            lines.append("L2.5 YOLO: HIT (\(Int(p.x)),\(Int(p.y)))")
        } else {
            lines.append("L2.5 YOLO: miss")
        }

        if let r = await novaFallback.findElement(targetLabel: label, elementDescription: label,
                                                  stepInstruction: "find \(label)", task: "layer self-test",
                                                  stepIndex: 0, totalSteps: 1,
                                                  image: capture.image, screen: screen),
           let p = r.axPoint {
            lines.append("L3 Nova: HIT '\(r.novaLabel)' (\(Int(p.x)),\(Int(p.y)))")
        } else {
            lines.append("L3 Nova: miss")
        }

        for line in lines { DebugLogger.log("SELFTEST", line) }
        return lines
    }

    /// Region is used SOFTLY elsewhere (to filter AX candidates and crop OCR).
    /// We no longer hard-reject a resolved point by absolute coordinates: that
    /// threw away correct hits (e.g. an Apple-menu dropdown item sits below the
    /// menu-bar strip, and movable windows make sidebar/ribbon coords unreliable).
    private func passesRegion(_ p: CGPoint, _ region: ScreenRegion, screen: NSScreen) -> Bool {
        return true
    }

    /// Accessibility-tree search filtered to the given region.
    /// `allowSystemUI`: only the precise targetLabel should be allowed to match
    /// Dock / menu-bar-extra items. Verbose descriptions ("… in System Settings")
    /// must NOT, or they hijack the dot onto the Dock icon.
    private func axSearch(_ query: String, region: ScreenRegion, screen: NSScreen, allowSystemUI: Bool = false,
                          preferredRole: String? = nil, anchor: (point: CGPoint, position: String)? = nil) -> AXElementInfo? {
        axSearchDetailed(query, region: region, screen: screen, allowSystemUI: allowSystemUI,
                         preferredRole: preferredRole, anchor: anchor)?.best
    }

    /// Full variant that also surfaces near-tied confident alternates (used by
    /// the primary targetLabel search so ambiguity can be shown to the user).
    private func axSearchDetailed(_ query: String, region: ScreenRegion, screen: NSScreen, allowSystemUI: Bool = false,
                                  preferredRole: String? = nil, anchor: (point: CGPoint, position: String)? = nil)
        -> (best: AXElementInfo, alternates: [AXElementInfo])? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let all = AccessibilityReader.shared.getTargetAppElements()

        if !all.isEmpty {
            var candidates: [AXElementInfo]
            if region != .fullScreen, let rect = ScreenRegionHelper.axGlobalRect(for: region, on: screen) {
                let expanded = rect.insetBy(dx: -24, dy: -24)
                let filtered = all.filter { expanded.intersects($0.frame) }
                candidates = filtered.isEmpty ? all : filtered // fall back to all if region empties
            } else {
                candidates = all
            }
            // When a DIALOG/SHEET is focused, prefer elements inside it: its
            // "Empty Bin" button must outrank the identical toolbar "Empty"
            // sitting behind it — the user can only interact with the modal
            // anyway. Applies only to modal surfaces (normal windows return
            // nil) so menu-bar and dropdown-menu targets aren't filtered out.
            if let dialogFrame = AccessibilityReader.shared.targetFocusedDialogFrame() {
                let inDialog = candidates.filter { dialogFrame.insetBy(dx: -8, dy: -8).intersects($0.frame) }
                if !inDialog.isEmpty {
                    DebugLogger.log("AX", "dialog filter: \(candidates.count) → \(inDialog.count) candidates")
                    candidates = inDialog
                }
            }
            if let hit = ElementFinder.shared.findElementWithAlternates(description: query, in: candidates, preferredRole: preferredRole, anchor: anchor) {
                return hit
            }
        }

        // Fallback: system UI (Dock icons, menu-bar extras). Only for a precise
        // targetLabel, and only accepted when the element's title strongly matches.
        guard allowSystemUI else { return nil }
        let systemElements = AccessibilityReader.shared.getSystemUIElements()
        guard !systemElements.isEmpty,
              let hit = ElementFinder.shared.findElement(description: query, in: systemElements),
              isStrongTitleMatch(query: query, element: hit) else { return nil }
        DebugLogger.log("AX", "system-UI hit '\(hit.title)' role=\(hit.role)")
        return (hit, [])
    }

    /// True when every word of `query` appears in the element's title — a strong,
    /// specific match (guards the Dock fallback against generic keyword hits).
    private func isStrongTitleMatch(query: String, element: AXElementInfo) -> Bool {
        let titleWords = Set(element.title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let queryWords = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !queryWords.isEmpty, !titleWords.isEmpty else { return false }
        return queryWords.allSatisfy { titleWords.contains($0) }
    }

    /// Builds an ordered, de-duplicated list of text labels to try via OCR.
    /// Prefers the explicit targetLabel, then quoted phrases, then capitalized
    /// words from the instruction/description. Generic UI words are dropped so
    /// OCR doesn't chase the word "Dock"/"icon" in surrounding (e.g. IDE) text.
    /// OCR-based location: evaluates all candidate labels and returns the best
    /// confident match's AX point (≥0.8), preferring the most complete label.
    private func locateByOCR(targetLabel: String, elementDescription: String, instruction: String,
                             image: CGImage, screen: NSScreen, region: ScreenRegion) async -> CGPoint? {
        let candidates = ocrCandidates(targetLabel: targetLabel, elementDescription: elementDescription, instruction: instruction)
        var bestOCR: (point: CGPoint, score: Double, label: String)?
        for label in candidates {
            var matches: [LocalVisionDetector.OCRMatch] = []
            if let m = await visionDetector.findLabelScored(label, in: image, on: screen, region: region) {
                matches.append(m)
            }
            if region != .fullScreen,
               let m = await visionDetector.findLabelScored(label, in: image, on: screen, region: .fullScreen) {
                matches.append(m)
            }
            for m in matches {
                let better = bestOCR == nil
                    || m.score > bestOCR!.score
                    || (m.score == bestOCR!.score && label.count > bestOCR!.label.count)
                if better { bestOCR = (m.point, m.score, label) }
            }
        }
        if let best = bestOCR, best.score >= 0.8 {
            print("[Resolver] OCR hit '\(best.label)' score=\(best.score) \(best.point)")
            DebugLogger.logResolution("L1-OCR", found: true, point: best.point, label: "\(best.label) (\(String(format: "%.2f", best.score)))")
            DebugState.shared.update(layer: "OCR", dot: best.point)
            return best.point
        }
        if let best = bestOCR {
            DebugLogger.log("RESOLVE", "OCR best '\(best.label)' score=\(String(format: "%.2f", best.score)) < 0.8")
        }
        return nil
    }

    private func ocrCandidates(targetLabel: String, elementDescription: String, instruction: String) -> [String] {
        // Words that carry no visual-label signal — they describe UI generically
        // and frequently appear in on-screen instruction text, causing false hits.
        let generic: Set<String> = [
            "icon", "logo", "button", "app", "application", "dock", "menu",
            "menubar", "toolbar", "bar", "image", "the", "your", "click", "tap"
        ]
        var result: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // Reject too-short, purely-generic, or already-present candidates.
            guard t.count >= 3 else { return }
            if generic.contains(t.lowercased()) { return }
            guard !result.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
            result.append(t)
        }

        // When the planner gave a precise targetLabel, TRUST IT and search only
        // the full phrase (plus quoted phrases). Do NOT fragment it into single
        // words — that's what made "Change Password" chase a stray "Password".
        if !targetLabel.isEmpty {
            add(targetLabel)
            for match in quotedPhrases(in: instruction) { add(match) }
            return result
        }

        // No precise label: fall back to quoted phrases + capitalized runs.
        for text in [instruction, elementDescription] {
            for match in quotedPhrases(in: text) { add(match) }
        }
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
