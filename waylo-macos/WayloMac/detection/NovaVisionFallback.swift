import Foundation
import AppKit

/// Layer 3: cloud grounding via Nova 2 Lite's object-detection mode (through the
/// Railway backend's `/nova-vision` route). Nova returns a bounding box on a
/// 0–1000 normalized scale, which we map to an AX global point.
///
/// The normalized scale is resolution-independent, so JPEG compression does not
/// affect coordinate accuracy.
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
    }

    /// `image`/`screen`: the captured display image and its screen.
    func findElement(
        targetLabel: String,
        elementDescription: String,
        stepInstruction: String,
        task: String,
        stepIndex: Int,
        totalSteps: Int,
        image: CGImage,
        screen: NSScreen
    ) async -> Result? {
        // Nova 2 Lite normalises coordinates, so compression ratio is irrelevant.
        // Downscale only to keep the upload payload small/fast.
        guard let (base64, sentSize) = ScreenCapturer.compressedJPEGBase64(image, maxWidth: 1280) else {
            return nil
        }
        DebugLogger.log("NOVA", "sending image \(Int(sentSize.width))x\(Int(sentSize.height)) (orig \(image.width)x\(image.height)) screen=\(Int(screen.frame.width))x\(Int(screen.frame.height)) scale=\(screen.backingScaleFactor) target='\(targetLabel)'")

        // Use the most descriptive label available for the detection target.
        let label = [targetLabel, elementDescription]
            .first(where: { !$0.isEmpty }) ?? stepInstruction

        do {
            let response = try await WayloAPIClient.shared.novaVision(
                imageBase64: base64,
                targetLabel: label,
                stepInstruction: stepInstruction
            )
            guard response.found, let bbox = response.bbox, bbox.count == 4 else {
                DebugLogger.log("NOVA", "not found (found=\(response.found))")
                return Result(axPoint: nil, axFrame: nil, updatedInstruction: "", updatedFindDescription: "", novaLabel: "", rawBBox: nil)
            }
            DebugLogger.log("NOVA", "raw bbox=[\(bbox.map { Int($0) }.map(String.init).joined(separator: ","))] (0-1000)")
            let axPoint = bboxToAX(bbox, screen: screen)
            let axFrame = axPoint != nil ? bboxToAXRect(bbox, screen: screen) : nil
            DebugLogger.log("NOVA", "computed axPoint=\(axPoint.map { String(format: "(%.1f,%.1f)", $0.x, $0.y) } ?? "nil")")
            // Prefer the label Nova returns; fall back to the label we sent.
            let resolvedLabel = (response.label?.isEmpty == false) ? response.label! : label
            return Result(axPoint: axPoint, axFrame: axFrame, updatedInstruction: "", updatedFindDescription: "", novaLabel: resolvedLabel, rawBBox: bbox)
        } catch {
            print("[NovaVisionFallback] request failed: \(error)")
            DebugLogger.log("NOVA", "request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Nova bbox [xMin,yMin,xMax,yMax] on 0–1000 (top-left origin) → AX global point.
    private func bboxToAX(_ bbox: [Double], screen: NSScreen) -> CGPoint? {
        let xMin = bbox[0], yMin = bbox[1], xMax = bbox[2], yMax = bbox[3]
        guard xMin >= 0, yMin >= 0, xMax <= 1000, yMax <= 1000, xMin < xMax, yMin < yMax else {
            print("[NovaVisionFallback] out-of-range bbox: \(bbox)")
            return nil
        }
        // Normalized center (0...1), top-left origin.
        let cx = ((xMin + xMax) / 2.0) / 1000.0
        let cy = ((yMin + yMax) / 2.0) / 1000.0

        let frame = screen.frame
        let cocoaX = frame.minX + CGFloat(cx) * frame.width
        let cocoaY = frame.maxY - CGFloat(cy) * frame.height // top-left → Cocoa bottom-left
        return ScreenCoordinates.cocoaToAX(CGPoint(x: cocoaX, y: cocoaY))
    }

    /// Same mapping as bboxToAX but for the full rect (AX-global, top-left).
    private func bboxToAXRect(_ bbox: [Double], screen: NSScreen) -> CGRect {
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
