import AppKit

/// Orchestrates the layered element-location pipeline. Returns a point in AX
/// global coordinates (what OverlayWindowController.showDot expects).
///
/// The flow BRANCHES on targetType/controlKind (cheapest, most private first):
///   - plain text target      → OCR first (visual ground truth), then AX
///   - real control (button…) → AX first (role/anchor beat header text), OCR fallback
///   - icon target             → AX-by-description → label cache → YOLO (L2.5) → Nova (L3)
///   - WEB-CONTENT step (browser page, not chrome) → OCR first even for
///     controls, and every AX search hard-restricted to the web-content frame
/// `localOnly` (scroll-assist polling) stops after AX + OCR — no network.
/// Every Nova hit is harvested: label cached for next-run AX resolution and a
/// YOLO training example logged.
@MainActor
final class CoordinateResolver {
    static let shared = CoordinateResolver()

    private let visionDetector = LocalVisionDetector()
    private let novaFallback = NovaVisionFallback()
    private let colorDetector = ColorDetector()

    /// Below this Nova self-reported confidence, we describe the target instead
    /// of pointing at what Nova admits is a guess. Conservative: a miss costs a
    /// spoken description; a false accept points the user at the wrong icon.
    static let novaMinConfidence = 0.55

    private init() {}

    struct Resolution {
        let axPoint: CGPoint
        /// A refined instruction if a cloud layer produced one (else empty).
        let updatedInstruction: String
        /// The AX element when L0 resolved — lets assist mode press it via
        /// AXUIElementPerformAction instead of a synthetic click.
        var axElement: AXUIElement? = nil
        /// AX-global bounding rect of the target when the layer knows it —
        /// drives the dotted region highlight instead of a bare dot.
        var targetFrame: CGRect? = nil
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
        anchorPosition: String = "",
        preferRect: CGRect? = nil
    ) async -> Resolution? {
        let image = capture.image
        let screen = capture.screen

        DebugLogger.log("RESOLVE", "start target='\(targetLabel)' desc='\(elementDescription)' region=\(screenRegion) step=\(stepIndex)/\(totalSteps)")
        DebugState.shared.update(targetApp: TargetAppTracker.shared.targetName, layer: "resolving…", screen: screen.frame)

        // If a modal sheet/dialog is up (e.g. the "Empty the Trash?" confirm),
        // its frame focuses BOTH AX (candidate filter) and OCR (crop) on the
        // modal, so we never point at an identical label behind it. An explicit
        // caller preferRect (a freshly-opened window) still takes precedence.
        let dialogFrame = AccessibilityReader.shared.targetFocusedDialogFrame()
        let effectivePreferRect = preferRect ?? dialogFrame

        // WEB-AWARE ROUTING: inside a browser, the PAGE is rendered by the web
        // engine — its content is either absent from the AX tree or nested in
        // an AXWebArea, while the tree is dominated by browser chrome (tabs,
        // bookmarks, the address bar) whose titles collide with page words
        // ("Docs", "Compose", "Bar"…). For a step that targets page content
        // (not the browser's own UI, not the macOS menu bar):
        //   - OCR runs FIRST even for control targets — pixels are the ground
        //     truth for web "buttons", which are drawn text;
        //   - AX candidates are HARD-restricted to the web-content frame, so a
        //     chrome element can never win by word collision (in-page AX
        //     elements, when Chrome exposes them, still win pixel-exact);
        //   - misses fall through to vision/recovery exactly as before.
        // A native modal (print/save dialog) suspends this — that surface is
        // real AppKit and the normal rules apply.
        var webContentFrame: CGRect?
        if TargetAppTracker.shared.isBrowser,
           dialogFrame == nil,
           screenRegion != .menuBar,
           !Self.targetsBrowserChrome(label: targetLabel, description: elementDescription, controlKind: controlKind) {
            webContentFrame = AccessibilityReader.shared.targetWebContentFrame()
            if let wf = webContentFrame {
                DebugLogger.log("RESOLVE", "WEB-CONTENT step in \(TargetAppTracker.shared.targetName) — OCR-first, AX restricted to \(Int(wf.width))x\(Int(wf.height)) web area")
            }
        }

        // Resolve an anchor location (nearby text the planner gave) once, so AX
        // can prefer the target in the right direction from it.
        var anchorInfo: (point: CGPoint, position: String)?
        if !anchorText.isEmpty {
            if let el = axSearch(anchorText, region: screenRegion, screen: screen, restrictRect: webContentFrame) {
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
        // WEB-CONTENT steps are OCR-first even for controls (see above).
        if targetType == .text && (!isControl || webContentFrame != nil) {
            if let hit = await locateByOCR(targetLabel: targetLabel, elementDescription: elementDescription,
                                           instruction: stepInstruction, image: image, screen: screen,
                                           region: screenRegion, preferRect: effectivePreferRect ?? webContentFrame) {
                return Resolution(axPoint: hit.point, updatedInstruction: "", targetFrame: hit.frame)
            }
        }

        // --- Layer 0: Accessibility tree (role + anchor aware) -------------
        // Try the planner's label, then locale/dialect variants of it: on an
        // en_IN/en_GB Mac the Dock item is "Bin", never "Trash", and an exact
        // AX match on the planner's word legitimately fails.
        for candidate in Self.labelVariants(targetLabel) where !candidate.isEmpty {
            guard let found = axSearchDetailed(candidate, region: screenRegion, screen: screen, allowSystemUI: true,
                                               preferredRole: controlKind, anchor: anchorInfo, preferRect: effectivePreferRect,
                                               restrictRect: webContentFrame)
            else { continue }
            if candidate != targetLabel {
                DebugLogger.log("RESOLVE", "matched locale variant '\(candidate)' for planner label '\(targetLabel)'")
            }
            var element = found.best

            // A TEXT target must resolve to an element that actually carries
            // matching text. Two confident-wrong-dot bugs live here:
            //  - a completely UNNAMED element won via anchor/role proximity
            //    (Gmail's "+" tab accepted for "Compose"), and
            //  - a PARTIAL word match beat the real item ("Show Fonts" accepted
            //    for "Show Colors" because they share "Show").
            // NOTE: label text ONLY — allText includes the ROLE string, which
            // let an unnamed AXCheckBox pass as "named" (accepted for 'Red' in
            // the Colors window) because "axcheckbox" is non-empty text.
            let hay = [element.title, element.description, element.helpText,
                       element.value, AXElementInfo.humanizeIdentifier(element.identifier)]
                .joined(separator: " ").lowercased()
            let words = Self.labelKeywords(candidate)
            if hay.trimmingCharacters(in: .whitespaces).isEmpty {
                DebugLogger.log("RESOLVE", "L0 match for '\(candidate)' is UNNAMED (role=\(element.role)) — refusing to guess")
                continue
            }
            if words.count >= 2, words.contains(where: { !hay.contains($0) }) {
                DebugLogger.log("RESOLVE", "L0 match '\(element.title)' covers only PART of '\(candidate)' — rejecting (partial word match)")
                continue
            }
            // Single-word targets ('Red', 'Save') must ALSO appear in the label —
            // an element named something else entirely is a different control.
            if words.count == 1, let w = words.first, !hay.contains(w) {
                DebugLogger.log("RESOLVE", "L0 match '\(element.title.isEmpty ? element.role : element.title)' doesn't contain '\(w)' — rejecting")
                continue
            }
            // A TEXT-INPUT element (address bar, search box) is never a menu
            // item / button / link / tab. It kept winning by substring — "Bar"
            // grabbed Chrome's "Address and search BAR", "Compose" grabbed a
            // field. Reject a field match unless the step actually types here.
            // NB: field HINTS come from the DESCRIPTION intent, never the word
            // "bar"/"box" (the chart type IS literally "Bar").
            let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"]
            let intent = "\(targetLabel) \(elementDescription)".lowercased()
            let wantsField = controlKind.lowercased() == "field"
                || ["field", "type ", "input", "search", "address", "url", "enter"].contains(where: { intent.contains($0) })
            if fieldRoles.contains(element.role), !wantsField {
                DebugLogger.log("RESOLVE", "L0 match is a text FIELD (\(element.role)) but step wants a \(controlKind.isEmpty ? "control" : controlKind) — rejecting")
                continue
            }

            // TOGGLE REDIRECT: "turn on X" steps match the SETTING'S NAME (an
            // AXStaticText), but the thing to click is the switch beside it.
            // If the step wants a toggle and we matched plain text, point at
            // the checkbox/switch in the same row instead.
            if let toggle = Self.rowToggleRedirect(for: element, step: (controlKind: controlKind, instruction: stepInstruction), screen: screen) {
                DebugLogger.log("RESOLVE", "toggle redirect: '\(element.title)' text → \(toggle.role) at (\(Int(toggle.center.x)),\(Int(toggle.center.y)))")
                element = toggle
            }

            print("[Resolver] L0 AX hit '\(element.title)' \(element.center)")
            DebugLogger.logResolution("L0-AX", found: true, point: element.center, label: "\(element.title) [\(element.role)]")
            DebugState.shared.update(layer: "L0 AX", dot: element.center)
            return Resolution(axPoint: element.center, updatedInstruction: "",
                              axElement: element.axElement,
                              targetFrame: element.frame,
                              alternates: found.alternates.map(\.center))
        }
        let axQuery = elementDescription.isEmpty ? findDescription : elementDescription
        // The verbose description is only used for AX when there's NO precise
        // targetLabel, or for icon targets (which rely on AXDescription/tooltips).
        // For a labelled text target it pollutes the match — e.g. matching the
        // "System Settings" header for an "Appearance" step — so we skip it.
        // A description-only match is weak evidence. If the element has NO name
        // of its own (empty title AND description) we matched on role or an
        // incidental value — pointing at it is a guess, and a wrong dot is
        // worse than an honest "look here, it's the small colour wheel".
        let descMatch = axSearch(axQuery, region: screenRegion, screen: screen, allowSystemUI: false,
                                 preferredRole: controlKind, anchor: anchorInfo, preferRect: effectivePreferRect,
                                 restrictRect: webContentFrame)
            .flatMap { el -> AXElementInfo? in
                let named = !el.title.trimmingCharacters(in: .whitespaces).isEmpty
                    || !el.description.trimmingCharacters(in: .whitespaces).isEmpty
                if !named {
                    DebugLogger.log("RESOLVE", "L0-AX-desc match is UNNAMED (role=\(el.role)) — refusing to guess")
                    return nil
                }
                // For an ICON target the description names the thing itself
                // ("camera button"). If the matched element's LABEL shares NO
                // real keyword with it (only generic words like "button"), we
                // matched a different labelled control — "camera button" grabbed
                // "Effects". Reject and let colour/vision find the real icon.
                if !Self.descShareKeyword(query: axQuery, element: el) {
                    DebugLogger.log("RESOLVE", "L0-AX-desc '\(el.title.isEmpty ? el.description : el.title)' shares no keyword with '\(axQuery)' — not the icon, deferring")
                    return nil
                }
                return el
            }

        if (targetType == .icon || targetLabel.isEmpty), let element = descMatch {
            if passesRegion(element.center, screenRegion, screen: screen) {
                print("[Resolver] L0 AX hit (desc) '\(element.title)' \(element.center)")
                DebugLogger.logResolution("L0-AX-desc", found: true, point: element.center, label: element.title)
                DebugState.shared.update(layer: "L0 AX (desc)", dot: element.center)
                return Resolution(axPoint: element.center, updatedInstruction: "",
                                  axElement: element.axElement, targetFrame: element.frame)
            }
            DebugLogger.log("RESOLVE", "REGION_MISMATCH L0-AX-desc '\(element.title)' \(element.center) region=\(screenRegion) — trying next layer")
        }
        print("[Resolver] L0 AX miss")
        DebugLogger.logResolution("L0-AX", found: false, point: nil, label: axQuery)

        // CONTROL targets: OCR fallback after AX (a button's text sits on it, so
        // OCR of the label still lands on the control). Web-content control
        // steps already ran OCR first — don't run it twice.
        if targetType == .text && isControl && webContentFrame == nil {
            if let hit = await locateByOCR(targetLabel: targetLabel, elementDescription: elementDescription,
                                           instruction: stepInstruction, image: image, screen: screen,
                                           region: screenRegion, preferRect: effectivePreferRect) {
                return Resolution(axPoint: hit.point, updatedInstruction: "", targetFrame: hit.frame)
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
            // The cached label may itself be in the wrong dialect (an older run
            // cached the planner's "Trash" on a Mac whose Dock says "Bin").
            for candidate in Self.labelVariants(cachedLabel) {
                guard let element = axSearch(candidate, region: screenRegion, screen: screen, allowSystemUI: true,
                                             restrictRect: webContentFrame),
                      passesRegion(element.center, screenRegion, screen: screen) else { continue }
                DebugLogger.log("RESOLVE", "LABEL_CACHE_HIT, skipped L3 — '\(candidate)' \(element.center)")
                DebugLogger.logResolution("label-cache-AX", found: true, point: element.center, label: candidate)
                DebugState.shared.update(layer: "cache→L0 AX", dot: element.center)
                return Resolution(axPoint: element.center, updatedInstruction: "",
                                  axElement: element.axElement, targetFrame: element.frame)
            }
            // Cache hit but AX still can't find it — fall through to L3 as normal.
            DebugLogger.log("RESOLVE", "cache label '\(cachedLabel)' present but L0 missed — continuing to L3")
        } else {
            DebugState.shared.update(cache: "MISS")
            DebugLogger.log("RESOLVE", "LABEL_CACHE lookup MISS")
        }

        // For a textless icon the vision layers need a CONCISE object name, not
        // the planner's verbose location sentence ("The colour wheel icon is
        // located to the right of the 'Text Colour' row…"). Sending that whole
        // sentence made CLIP score every box 0.00 and Nova return not-found.
        let visionQuery = targetLabel.isEmpty
            ? Self.conciseObjectPhrase(elementDescription.isEmpty ? findDescription : elementDescription)
            : targetLabel

        // --- Colour layer: a distinctly-coloured control (red camera button,
        // green send arrow…). On-device pixel analysis, ~30ms, only when the
        // description names a colour and the target is an icon. Runs BEFORE the
        // paid vision layers because it's fast and very specific.
        if targetType == .icon || targetLabel.isEmpty {
            // Only the TARGET's own descriptors — NOT the full instruction. The
            // instruction is a sentence that often names a coloured LANDMARK
            // ("click the photo below the RED camera button"); feeding it here
            // fired the red detector on a step whose real target is the photo,
            // pointing back at the camera button. The concise element/find
            // description names the target itself.
            let colorText = "\(elementDescription) \(findDescription)"
            // Confine the colour search to the app's window (or the just-opened
            // window) so a red Dock icon / menu-bar glyph can't win.
            let colorWindow = effectivePreferRect ?? AccessibilityReader.shared.targetFocusedWindowFrame()
            if let colorName = ColorDetector.colorMentioned(in: colorText),
               let hit = colorDetector.find(colorName: colorName, in: image, on: screen,
                                            region: screenRegion, within: colorWindow),
               passesRegion(hit.point, screenRegion, screen: screen) {
                DebugLogger.logResolution("COLOR", found: true, point: hit.point, label: "\(colorName) blob")
                DebugState.shared.update(layer: "Colour \(colorName)")
                return Resolution(axPoint: hit.point, updatedInstruction: "", targetFrame: hit.frame)
            }
        }

        // --- Layer 2.5: Dual-model YOLO (OmniParser + Screen2AX) -----------
        // For ICON / logo targets (the planner marks these). YOLO locates icons
        // that have no readable text; text targets skip it and go to Nova.
        if targetType == .icon || targetLabel.isEmpty {
            DebugLogger.log("PIPELINE", "icon target → trying L2.5 YOLO (query='\(visionQuery)')")
            if let detection = await YOLODetector.shared.detect(
                capture: capture,
                targetLabel: visionQuery,
                elementDescription: elementDescription,
                screenRegion: screenRegion,
                stepInstruction: stepInstruction
            ) {
                DebugLogger.log("PIPELINE", "L2.5 HIT at (\(Int(detection.point.x)),\(Int(detection.point.y)))")
                return Resolution(axPoint: detection.point, updatedInstruction: "", targetFrame: detection.frame)
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
        // Use the CONCISE object name for a textless icon (see visionQuery).
        var novaDescription = targetLabel.isEmpty ? visionQuery : elementDescription
        if !anchorText.isEmpty && !anchorPosition.isEmpty {
            novaDescription += " (located to the \(anchorPosition) of \"\(anchorText)\")"
        }
        // Local OCR words as grounding context (~80ms, only on this paid path).
        let ocrContext = await visionDetector.visibleTextSummary(in: image)
        if let result = await novaFallback.findElement(
            targetLabel: targetLabel,
            elementDescription: novaDescription,
            stepInstruction: stepInstruction,
            task: task,
            stepIndex: stepIndex,
            totalSteps: totalSteps,
            image: image,
            screen: screen,
            ocrContext: ocrContext
        ) {
            // Nova low-confidence guard: if Nova admits it's guessing at the
            // element (common for tiny unlabelled icons in AX-hostile apps like
            // WhatsApp/Electron), do NOT plant a dot on a likely-wrong icon —
            // return nil so the engine describes the target and lets the user
            // click. "Don't point when unsure" > a confident wrong dot.
            if let point = result.axPoint, let conf = result.confidence, conf < Self.novaMinConfidence {
                DebugLogger.log("RESOLVE", "L3 Nova REJECTED: confidence \(String(format: "%.2f", conf)) < \(Self.novaMinConfidence) — describing instead of pointing at a guess")
                DebugLogger.logResolution("L3-Nova", found: false, point: point, label: "low-conf \(targetLabel)")
                DebugState.shared.update(layer: "L3 Nova (low-conf → describe)")
                return nil
            }
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
                // Tier 5: remember this icon's PIXELS (perceptual hash) so the
                // next run recognises it for free — only for textless icons,
                // where it pays off. Near-exact, so it can't drift to a
                // different control.
                if (targetType == .icon || targetLabel.isEmpty), let bb = result.rawBBox, bb.count == 4,
                   let crop = image.cropNormalized(x: bb[0] / 1000, y: bb[1] / 1000,
                                                   w: (bb[2] - bb[0]) / 1000, h: (bb[3] - bb[1]) / 1000) {
                    let concept = targetLabel.isEmpty ? elementDescription : targetLabel
                    IconMemory.shared.remember(crop: crop, app: TargetAppTracker.shared.targetName, concept: concept)
                }
                // STAGE a training example — nothing is written yet. Nova's box
                // is only a hypothesis; it earns its place in the training set
                // when the user clicks inside it and then marks the guide ✓.
                if let bbox = result.rawBBox {
                    let app = appName.isEmpty ? TargetAppTracker.shared.targetName : appName
                    let label = targetLabel.isEmpty ? elementDescription : targetLabel
                    await TrainingHarvest.shared.stage(
                        stepIndex: stepIndex,
                        appName: app,
                        targetLabel: label,
                        controlKind: controlKind,
                        screenRegion: screenRegion.rawValue,
                        bbox: bbox,
                        image: image
                    )
                }
                return Resolution(axPoint: point, updatedInstruction: result.updatedInstruction, targetFrame: result.axFrame)
            }
            let refined = result.updatedFindDescription
            if !refined.isEmpty {
                if let element = axSearch(refined, region: screenRegion, screen: screen, restrictRect: webContentFrame) {
                    DebugLogger.logResolution("L3-Nova-refine-AX", found: true, point: element.center, label: refined)
                    DebugState.shared.update(layer: "L3 Nova→AX", dot: element.center)
                    return Resolution(axPoint: element.center, updatedInstruction: result.updatedInstruction,
                                      axElement: element.axElement, targetFrame: element.frame)
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

        if let d = await YOLODetector.shared.detect(capture: capture, targetLabel: label,
                                                    elementDescription: label, screenRegion: .fullScreen,
                                                    stepInstruction: "find \(label)") {
            lines.append("L2.5 YOLO: HIT (\(Int(d.point.x)),\(Int(d.point.y)))")
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
                          preferredRole: String? = nil, anchor: (point: CGPoint, position: String)? = nil,
                          preferRect: CGRect? = nil, restrictRect: CGRect? = nil) -> AXElementInfo? {
        axSearchDetailed(query, region: region, screen: screen, allowSystemUI: allowSystemUI,
                         preferredRole: preferredRole, anchor: anchor, preferRect: preferRect,
                         restrictRect: restrictRect)?.best
    }

    /// Full variant that also surfaces near-tied confident alternates (used by
    /// the primary targetLabel search so ambiguity can be shown to the user).
    /// `restrictRect` is a HARD filter (web-content steps): elements outside it
    /// are browser chrome — a word collision, never the target — so unlike
    /// preferRect there is no fallback to the full candidate list.
    private func axSearchDetailed(_ query: String, region: ScreenRegion, screen: NSScreen, allowSystemUI: Bool = false,
                                  preferredRole: String? = nil, anchor: (point: CGPoint, position: String)? = nil,
                                  preferRect: CGRect? = nil, restrictRect: CGRect? = nil)
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
            if let restrict = restrictRect {
                let before = candidates.count
                candidates = candidates.filter { restrict.insetBy(dx: -4, dy: -4).intersects($0.frame) }
                if candidates.count != before {
                    DebugLogger.log("AX", "web-content filter: \(before) → \(candidates.count) candidates")
                }
                if candidates.isEmpty { return nil }
            }
            // The macOS MENU BAR (File/Edit/Format…) must only satisfy a
            // menuBar-region step. Otherwise "the Format button in the toolbar"
            // matched Pages' menu-bar Format MENU on an exact title tie and the
            // whole guide walked into the wrong menu. A dropped-down menu's
            // items (AXMenuItem) are NOT excluded — those are legit targets.
            if region != .menuBar {
                let noMenuBar = candidates.filter { $0.role != "AXMenuBarItem" }
                if noMenuBar.count != candidates.count {
                    DebugLogger.log("AX", "menu-bar filter (region=\(region.rawValue)): \(candidates.count) → \(noMenuBar.count)")
                    candidates = noMenuBar
                }
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
            // A window that just appeared (the Trash window after clicking the
            // Dock icon): the next target is almost always inside it. Soft
            // preference — falls back to all candidates when none intersect.
            if let prefer = preferRect {
                let inRect = candidates.filter { prefer.insetBy(dx: -8, dy: -8).intersects($0.frame) }
                if !inRect.isEmpty, inRect.count != candidates.count {
                    DebugLogger.log("AX", "new-window filter: \(candidates.count) → \(inRect.count) candidates")
                    candidates = inRect
                }
            }
            if let hit = ElementFinder.shared.findElementWithAlternates(description: query, in: candidates, preferredRole: preferredRole, anchor: anchor) {
                return hit
            }
        }

        // Fallback: system UI (Dock icons, menu-bar extras). Only for a precise
        // targetLabel, and only accepted when the element's title strongly
        // matches. Never for a web-content step — its target is on the page.
        guard allowSystemUI, restrictRect == nil else { return nil }
        let systemElements = AccessibilityReader.shared.getSystemUIElements()
        guard !systemElements.isEmpty,
              let hit = ElementFinder.shared.findElement(description: query, in: systemElements),
              isStrongTitleMatch(query: query, element: hit) else { return nil }
        DebugLogger.log("AX", "system-UI hit '\(hit.title)' role=\(hit.role)")
        return (hit, [])
    }

    /// True when every word of `query` appears in the element's title — a strong,
    /// specific match (guards the Dock fallback against generic keyword hits).
    /// macOS renames core UI elements by region. On an en_IN / en_GB / en_AU
    /// Mac the Dock's Trash is titled **"Bin"** ("Empty Trash" → "Empty Bin"),
    /// while the filesystem still calls it Trash — so `FileManager.displayName`
    /// can't be trusted either. The planner writes US English; the screen may
    /// not. Every pair below is checked in BOTH directions, so this works
    /// whichever dialect the planner and the Mac happen to use.
    private static let dialectPairs: [(String, String)] = [
        ("trash", "bin"),
        ("preferences", "settings"),
        ("favorites", "favourites"),
        ("color", "colour"),
        ("customize", "customise"),
        ("organize", "organise"),
        ("center", "centre"),
        ("gray", "grey"),
        ("catalog", "catalogue"),
        ("license", "licence"),
        ("dialog", "dialogue"),
        ("fullscreen", "full screen"),
    ]

    /// Meaningful lowercase keywords of a target label ("Show Colors…" →
    /// ["show","colors"]). Used to require FULL coverage on multi-word labels
    /// so "Show Fonts" can never win for "Show Colors".
    static func labelKeywords(_ label: String) -> [String] {
        let stop: Set<String> = ["the", "a", "an", "of", "to", "in", "on", "and", "or"]
        return label.lowercased()
            .replacingOccurrences(of: "…", with: " ")
            .replacingOccurrences(of: "...", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stop.contains($0) }
    }

    /// When a step wants a TOGGLE ("turn on X", controlKind checkbox/toggle)
    /// but AX matched the setting's NAME (static text), find the actual
    /// checkbox/switch in the same row (same vertical band, to the right —
    /// macOS Settings layout) and return it. nil = no redirect needed/found.
    static func rowToggleRedirect(for element: AXElementInfo,
                                  step: (controlKind: String, instruction: String),
                                  screen: NSScreen) -> AXElementInfo? {
        guard element.role == "AXStaticText" || element.role == "AXCell" else { return nil }
        let kind = step.controlKind.lowercased()
        let instr = step.instruction.lowercased()
        let wantsToggle = ["checkbox", "toggle", "switch"].contains(kind)
            || instr.contains("turn on") || instr.contains("turn off")
            || instr.contains("enable") || instr.contains("disable")
            || instr.contains("toggle") || instr.contains("switch on") || instr.contains("switch off")
        guard wantsToggle else { return nil }

        let toggles = AccessibilityReader.shared.getTargetAppElements().filter {
            ($0.role == "AXCheckBox" || $0.role == "AXSwitch")
                && abs($0.center.y - element.center.y) < 22          // same row
                && $0.center.x > element.frame.minX                   // at/right of the label
                && $0.center.x - element.center.x < 700               // same pane, not across the screen
        }
        return toggles.min(by: {
            abs($0.center.y - element.center.y) < abs($1.center.y - element.center.y)
        })
    }

    /// True when the step explicitly targets the BROWSER'S OWN UI (address bar,
    /// tabs, bookmarks…) rather than page content — those live in the chrome
    /// strip and must stay findable via AX with no web-area restriction.
    /// Deliberately NARROW: page-side words ("search", "back", a site's own
    /// "tab") must not trip it, so single ambiguous words are excluded.
    static func targetsBrowserChrome(label: String, description: String, controlKind: String) -> Bool {
        let intent = "\(label) \(description)".lowercased()
        let chromeMarkers = [
            "address bar", "address and search", "url bar", "omnibox", "search bar of",
            "new tab", "tab bar", "browser tab", "tab strip",
            "bookmark", "reading list",
            "browser toolbar", "browser window", "browser's", "of the browser",
            "of chrome", "of safari", "in chrome's", "in safari's",
            "reload button", "refresh button", "back button", "forward button",
            "extension", "incognito", "private window", "downloads button",
        ]
        return chromeMarkers.contains { intent.contains($0) }
    }

    /// The label plus its dialect variants, original first (so an exact match
    /// on what the planner said always wins when both exist on screen).
    static func labelVariants(_ label: String) -> [String] {
        guard !label.isEmpty else { return [] }
        var out = [label]
        let lower = label.lowercased()
        for (a, b) in dialectPairs {
            if lower.contains(a) {
                out.append(label.replacingOccurrences(of: a, with: b, options: .caseInsensitive))
            } else if lower.contains(b) {
                out.append(label.replacingOccurrences(of: b, with: a, options: .caseInsensitive))
            }
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    /// Reduces a verbose planner description to the OBJECT it names, dropping
    /// the location clause. "The colour wheel icon is located to the right of
    /// the 'Text Colour' row in the Style tab" → "colour wheel icon". Vision
    /// models need the thing, not directions to it (the anchor carries those).
    static func conciseObjectPhrase(_ desc: String) -> String {
        var s = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cut at the first locational connective.
        let cutMarkers = [" is located", " located ", " to the right", " to the left",
                          " that appears", " which appears", " in the ", " on the ",
                          " at the ", " next to ", " below ", " above ", " near "]
        let lower = s.lowercased()
        var cut = s.count
        for m in cutMarkers {
            if let r = lower.range(of: m) {
                cut = min(cut, lower.distance(from: lower.startIndex, to: r.lowerBound))
            }
        }
        if cut < s.count {
            s = String(s.prefix(cut))
        }
        // Drop a leading article.
        s = s.replacingOccurrences(of: #"(?i)^\s*(the|a|an)\s+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the matched element's label shares at least one real
    /// (non-stop-word) keyword with the query. Guards icon-by-description
    /// matches from latching onto an unrelated labelled control.
    static func descShareKeyword(query: String, element: AXElementInfo) -> Bool {
        let stop: Set<String> = ["the", "a", "an", "button", "icon", "in", "on", "of",
                                 "to", "for", "and", "or", "menu", "item", "click", "tap",
                                 "bar", "top", "bottom", "left", "right", "toolbar", "at"]
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && !stop.contains($0) })
        }
        let q = words(query)
        guard !q.isEmpty else { return true }  // nothing to check against
        let el = words("\(element.title) \(element.description) \(element.helpText)")
        return !q.isDisjoint(with: el)
    }

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
                             image: CGImage, screen: NSScreen, region: ScreenRegion,
                             preferRect: CGRect? = nil) async -> (point: CGPoint, frame: CGRect)? {
        let candidates = ocrCandidates(targetLabel: targetLabel, elementDescription: elementDescription, instruction: instruction)
        var bestOCR: (point: CGPoint, frame: CGRect, score: Double, label: String)?
        for label in candidates {
            var matches: [LocalVisionDetector.OCRMatch] = []
            // A newly-opened window takes priority over the coarse region crop.
            if let prefer = preferRect,
               let m = await visionDetector.findLabelScored(label, in: image, on: screen, cropAXRect: prefer) {
                matches.append(m)
            }
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
                if better { bestOCR = (m.point, m.frame, m.score, label) }
            }
        }
        if let best = bestOCR, best.score >= 0.8 {
            print("[Resolver] OCR hit '\(best.label)' score=\(best.score) \(best.point)")
            DebugLogger.logResolution("L1-OCR", found: true, point: best.point, label: "\(best.label) (\(String(format: "%.2f", best.score)))")
            DebugState.shared.update(layer: "OCR", dot: best.point)
            return (best.point, best.frame)
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
            // Include locale variants ("Empty Trash" → "Empty Bin") so OCR can
            // read what's actually printed on an en_IN / en_GB screen.
            for variant in Self.labelVariants(targetLabel) { add(variant) }
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
