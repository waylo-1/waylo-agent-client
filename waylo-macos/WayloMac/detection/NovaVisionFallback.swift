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
        let updatedInstruction: String
        let updatedFindDescription: String
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
        guard let (base64, _) = ScreenCapturer.compressedJPEGBase64(image, maxWidth: 1280) else {
            return nil
        }

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
                return Result(axPoint: nil, updatedInstruction: "", updatedFindDescription: "")
            }
            let axPoint = bboxToAX(bbox, screen: screen)
            return Result(axPoint: axPoint, updatedInstruction: "", updatedFindDescription: "")
        } catch {
            print("[NovaVisionFallback] request failed: \(error)")
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
}
