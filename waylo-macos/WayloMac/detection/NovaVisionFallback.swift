import Foundation
import AppKit

/// Layer 3: cloud vision grounding through the backend's `/nova-vision` route.
/// NOTE: with the backend on AI_PROVIDER=gemini this is **Gemini** object
/// detection — the class name, endpoint, and `/nova-vision` path are historical
/// (like the Android `GeminiClient` naming), kept to avoid a coordinated
/// client+server+route rename. Logs are tagged [GEMINI] so debug reports tell
/// the truth. Returns a bounding box on a 0–1000 normalized scale, mapped to an
/// AX global point; the normalized scale is resolution-independent, so JPEG
/// compression doesn't affect coordinate accuracy.
final class NovaVisionFallback {

    struct Result {
        let axPoint: CGPoint?
        /// AX-global bounding rect of the detection (for region highlights).
        var axFrame: CGRect? = nil
        let updatedInstruction: String
        let updatedFindDescription: String
        /// The label Nova reports for the located element — cached so the next
        /// run of this step can try AX (L0) directly and skip the vision call.
        let novaLabel: String
        /// Raw bounding box [xMin,yMin,xMax,yMax] on the 0–1000 scale, surfaced
        /// for YOLO training-data collection.
        let rawBBox: [Double]?
        /// Nova's self-reported confidence (0–1) that the box is the EXACT
        /// element — low means "I'm guessing", so the caller should describe
        /// rather than plant a dot on a wrong icon.
        var confidence: Double? = nil
        /// AX-global rect of the CONTAINING group (toolbar/panel) the target
        /// sits in — present even when the exact box is missing/low-confidence.
        /// The resolver highlights THIS (a big box it's sure about) and speaks
        /// `hint` when it can't pin the icon precisely.
        var containerFrame: CGRect? = nil
        /// A spoken sentence locating the target within its group.
        var hint: String = ""
    }

    /// `image`/`screen`: the captured display image and its screen.
    /// `ocrContext`: visible on-screen text from local OCR — free grounding.
    func findElement(
        targetLabel: String,
        elementDescription: String,
        stepInstruction: String,
        task: String,
        stepIndex: Int,
        totalSteps: Int,
        image: CGImage,
        screen: NSScreen,
        ocrContext: String = "",
        cropAXRect: CGRect? = nil
    ) async -> Result? {
        // WEB-FRAME CROP: for an in-page target, crop the screenshot to the web
        // content area BEFORE sending, so Gemini physically cannot see — or return
        // — browser chrome (menu bar, toolbar, bookmarks bar, tabs). This stops
        // chrome-vs-page collisions like YouTube's "History" being grounded on
        // Chrome's own History menu. Coordinates map back via the crop rect.
        var sendImage = image
        var cropRect: CGRect? = nil
        var cropNorm: (x: Double, y: Double, w: Double, h: Double)? = nil
        if let r = cropAXRect, r.width > 40, r.height > 40,
           screen.frame.width > 1, screen.frame.height > 1 {
            let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
            let nx = Double((r.minX - screen.frame.minX) / screen.frame.width)
            let ny = Double((r.minY - axTop) / screen.frame.height)
            let nw = Double(r.width / screen.frame.width)
            let nh = Double(r.height / screen.frame.height)
            if let cropped = image.cropNormalized(x: nx, y: ny, w: nw, h: nh) {
                sendImage = cropped
                cropRect = r
                cropNorm = (nx, ny, nw, nh)
                DebugLogger.log("GEMINI", "cropped to web frame \(Int(r.width))x\(Int(r.height)) — browser chrome excluded")
            }
        }
        // Map a crop-relative 0–1000 bbox back to FULL-image 0–1000 coords (the
        // rawBBox contract — used to crop icon pixels out of the full screenshot).
        func toFullBBox(_ b: [Double]) -> [Double] {
            guard let c = cropNorm, b.count == 4 else { return b }
            return [(c.x + b[0] / 1000 * c.w) * 1000, (c.y + b[1] / 1000 * c.h) * 1000,
                    (c.x + b[2] / 1000 * c.w) * 1000, (c.y + b[3] / 1000 * c.h) * 1000]
        }

        // Nova 2 Lite normalises coordinates, so compression ratio is irrelevant.
        // Downscale only to keep the upload payload small/fast.
        guard let (base64, sentSize) = ScreenCapturer.compressedJPEGBase64(sendImage, maxWidth: 1280) else {
            return nil
        }
        DebugLogger.log("GEMINI", "sending image \(Int(sentSize.width))x\(Int(sentSize.height)) (orig \(image.width)x\(image.height)) screen=\(Int(screen.frame.width))x\(Int(screen.frame.height)) scale=\(screen.backingScaleFactor) target='\(targetLabel)'\(cropRect != nil ? " [web-cropped]" : "")")

        // Use the most descriptive label available for the detection target.
        let label = [targetLabel, elementDescription]
            .first(where: { !$0.isEmpty }) ?? stepInstruction

        do {
            let response = try await WayloAPIClient.shared.novaVision(
                imageBase64: base64,
                targetLabel: label,
                stepInstruction: stepInstruction,
                ocrContext: ocrContext
            )
            // Container box + hint arrive independently of the tight box (Gemini
            // returns them even when it can't pin the icon) — compute the AX rect
            // once so both the found and not-found paths can surface them.
            let containerFrame = (response.container?.count == 4)
                ? bboxToAXRect(response.container!, screen: screen, crop: cropRect) : nil
            let hint = response.hint
            if containerFrame != nil {
                DebugLogger.log("GEMINI", "container present\(hint.isEmpty ? "" : " + hint: '\(hint)'")")
            }
            guard response.found, let bbox = response.bbox, bbox.count == 4 else {
                DebugLogger.log("GEMINI", "not found (found=\(response.found))")
                return Result(axPoint: nil, axFrame: nil, updatedInstruction: "", updatedFindDescription: "",
                              novaLabel: "", rawBBox: nil, containerFrame: containerFrame, hint: hint)
            }
            DebugLogger.log("GEMINI", "raw bbox=[\(bbox.map { Int($0) }.map(String.init).joined(separator: ","))] (0-1000)\(cropRect != nil ? " within web crop" : "")")
            let axPoint = bboxToAX(bbox, screen: screen, crop: cropRect)
            let axFrame = axPoint != nil ? bboxToAXRect(bbox, screen: screen, crop: cropRect) : nil
            let fullBBox = toFullBBox(bbox)   // full-image coords for the rawBBox contract
            DebugLogger.log("GEMINI", "computed axPoint=\(axPoint.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) } ?? "nil")")
            // Prefer the label Nova returns; fall back to the label we sent.
            let resolvedLabel = (response.label?.isEmpty == false) ? response.label! : label
            if let c = response.confidence {
                DebugLogger.log("GEMINI", "confidence=\(String(format: "%.2f", c))")
            }
            return Result(axPoint: axPoint, axFrame: axFrame, updatedInstruction: "", updatedFindDescription: "", novaLabel: resolvedLabel, rawBBox: fullBBox, confidence: response.confidence, containerFrame: containerFrame, hint: hint)
        } catch {
            print("[NovaVisionFallback] request failed: \(error)")
            DebugLogger.log("GEMINI", "request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Nova bbox [xMin,yMin,xMax,yMax] on 0–1000 (top-left origin) → AX global
    /// point. When `crop` is set the bbox is relative to that AX rect (the image
    /// sent to Gemini was cropped to it), so it maps directly into the crop —
    /// which is already AX-global top-left, no Cocoa flip needed.
    private func bboxToAX(_ bbox: [Double], screen: NSScreen, crop: CGRect? = nil) -> CGPoint? {
        let xMin = bbox[0], yMin = bbox[1], xMax = bbox[2], yMax = bbox[3]
        guard xMin >= 0, yMin >= 0, xMax <= 1000, yMax <= 1000, xMin < xMax, yMin < yMax else {
            print("[NovaVisionFallback] out-of-range bbox: \(bbox)")
            return nil
        }
        let cx = ((xMin + xMax) / 2.0) / 1000.0
        let cy = ((yMin + yMax) / 2.0) / 1000.0
        if let c = crop {
            return CGPoint(x: c.minX + CGFloat(cx) * c.width, y: c.minY + CGFloat(cy) * c.height)
        }
        let frame = screen.frame
        let cocoaX = frame.minX + CGFloat(cx) * frame.width
        let cocoaY = frame.maxY - CGFloat(cy) * frame.height // top-left → Cocoa bottom-left
        return ScreenCoordinates.cocoaToAX(CGPoint(x: cocoaX, y: cocoaY))
    }

    /// Same mapping as bboxToAX but for the full rect (AX-global, top-left).
    private func bboxToAXRect(_ bbox: [Double], screen: NSScreen, crop: CGRect? = nil) -> CGRect {
        if let c = crop {
            return CGRect(
                x: c.minX + CGFloat(bbox[0] / 1000.0) * c.width,
                y: c.minY + CGFloat(bbox[1] / 1000.0) * c.height,
                width: CGFloat((bbox[2] - bbox[0]) / 1000.0) * c.width,
                height: CGFloat((bbox[3] - bbox[1]) / 1000.0) * c.height
            )
        }
        let frame = screen.frame
        let axTop = ScreenCoordinates.primaryHeight - frame.maxY
        return CGRect(
            x: frame.minX + CGFloat(bbox[0] / 1000.0) * frame.width,
            y: axTop + CGFloat(bbox[1] / 1000.0) * frame.height,
            width: CGFloat((bbox[2] - bbox[0]) / 1000.0) * frame.width,
            height: CGFloat((bbox[3] - bbox[1]) / 1000.0) * frame.height
        )
    }
}
