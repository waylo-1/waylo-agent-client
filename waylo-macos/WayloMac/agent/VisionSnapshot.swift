import AppKit

/// Set-of-Mark observation for AX-hostile apps (Spotify, WhatsApp, Electron
/// apps that expose no accessibility tree). When AgentSnapshot comes back
/// empty, we fall back to VISION: screenshot → YOLO detects every UI box →
/// we stamp a NUMBERED mark on each → a vision model is asked "press #7".
/// This is the exact same "pick from a numbered list" contract as agent mode,
/// but the list is drawn on pixels instead of read from the tree — so the
/// decider never has to output raw coordinates, and textless icons become
/// choosable by number.
struct VisionSnapshot {

    struct Mark {
        let id: Int
        let center: CGPoint   // AX-global — where a press clicks
        let frame: CGRect     // AX-global — for the point outline
        let axClass: String?  // Screen2AX hint (AXButton/AXLink/…) if known
        let caption: String?  // Tier 2 zero-shot concept ("search", "attach")
    }

    let marks: [Mark]
    /// The screenshot with numbered marks stamped on it (base64 JPEG).
    let annotatedBase64: String
    let appName: String

    func mark(for id: Int) -> Mark? { marks.first(where: { $0.id == id }) }

    /// The compact numbered list sent alongside the image.
    var payload: [[String: Any]] {
        marks.map { m in
            var d: [String: Any] = ["id": m.id, "pos": "\(Int(m.center.x)),\(Int(m.center.y))"]
            if let c = m.axClass { d["kind"] = c }
            if let cap = m.caption { d["label"] = cap }   // Tier 2 icon concept
            return d
        }
    }

    /// Captures the screen, runs YOLO, keeps the strongest boxes, stamps marks.
    /// Returns nil if capture or detection fails / finds nothing.
    static func capture(maxMarks: Int = 36) async -> VisionSnapshot? {
        guard let cap = await ScreenCapturer.shared.captureActiveScreen() else {
            DebugLogger.log("AGENT", "vision: screen capture failed"); return nil
        }
        guard let (b64, _) = ScreenCapturer.compressedJPEGBase64(cap.image, maxWidth: 1280) else { return nil }

        let resp: YOLODetectResponse
        do {
            // Empty target → the service returns every merged box (no matching).
            resp = try await WayloAPIClient.shared.detectElements(
                imageBase64: b64, targetLabel: "", stepInstruction: "", screenRegion: "fullScreen")
        } catch {
            DebugLogger.log("AGENT", "vision: YOLO failed (\(error.localizedDescription))"); return nil
        }
        guard !resp.elements.isEmpty else { DebugLogger.log("AGENT", "vision: 0 boxes"); return nil }

        let screen = cap.screen
        // Prefer larger, higher-confidence boxes; drop near-duplicates so the
        // marks stay legible (SoM degrades past ~40 marks).
        let sorted = resp.elements.sorted { $0.confidence > $1.confidence }
        var kept: [YOLOElement] = []
        for el in sorted {
            if el.w < 0.006 || el.h < 0.006 { continue }             // sub-pixel noise
            if el.w > 0.9 && el.h > 0.9 { continue }                 // whole-screen box
            if kept.contains(where: { abs($0.cx - el.cx) < 0.02 && abs($0.cy - el.cy) < 0.02 }) { continue }
            kept.append(el)
            if kept.count >= maxMarks { break }
        }
        guard !kept.isEmpty else { return nil }

        // Number left→right, top→bottom so the list reads like the screen.
        kept.sort { ($0.cy, $0.cx) < ($1.cy, $1.cx) }

        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        var marks: [Mark] = []
        for (i, el) in kept.enumerated() {
            let center = CGPoint(x: screen.frame.minX + CGFloat(el.cx) * screen.frame.width,
                                 y: axTop + CGFloat(el.cy) * screen.frame.height)
            let frame = CGRect(x: screen.frame.minX + CGFloat(el.x) * screen.frame.width,
                               y: axTop + CGFloat(el.y) * screen.frame.height,
                               width: CGFloat(el.w) * screen.frame.width,
                               height: CGFloat(el.h) * screen.frame.height)
            marks.append(Mark(id: i + 1, center: center, frame: frame,
                              axClass: el.axClass, caption: el.caption))
        }

        guard let annotated = stamp(marks: kept, on: cap.image) else { return nil }
        DebugLogger.log("AGENT", "vision: \(marks.count) marks stamped (of \(resp.mergedCount) boxes)")
        return VisionSnapshot(marks: marks, annotatedBase64: annotated,
                              appName: TargetAppTracker.shared.targetName)
    }

    /// Draws a numbered badge at each box centre on a downscaled copy of the
    /// screenshot; returns base64 JPEG. Numbers match `marks[i].id == i+1`.
    private static func stamp(marks: [YOLOElement], on image: CGImage, maxWidth: CGFloat = 1280) -> String? {
        let scale = min(1, maxWidth / CGFloat(image.width))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let nsImage = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsImage
        for (i, el) in marks.enumerated() {
            // CGContext origin is bottom-left; YOLO cy is top-down → flip.
            let cx = CGFloat(el.cx) * CGFloat(w)
            let cy = CGFloat(1 - el.cy) * CGFloat(h)
            let label = "\(i + 1)"
            let r: CGFloat = label.count > 1 ? 15 : 12
            let badge = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            NSColor(calibratedRed: 1, green: 0.15, blue: 0.2, alpha: 0.92).setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: badge); ring.lineWidth = 1.5; ring.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: cx - size.width / 2, y: cy - size.height / 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let out = ctx.makeImage(),
              let (b64, _) = ScreenCapturer.compressedJPEGBase64(out, maxWidth: maxWidth) else { return nil }
        return b64
    }
}
