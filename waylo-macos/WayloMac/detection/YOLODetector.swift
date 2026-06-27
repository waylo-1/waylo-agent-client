import CoreML
import Vision
import AppKit

/// Layer 2: CoreML object detector for icon-only buttons (no text label).
/// Stub for now — always returns nil so the resolver falls through to Nova.
/// The interface is fixed so a real YOLOv8-nano CoreML model can be slotted in
/// later without touching CoordinateResolver.
final class YOLODetector {

    /// `elementDescription`: natural-language icon description, e.g.
    /// "bold button icon", "hamburger menu".
    /// Returns an AX global point or nil.
    func findElement(_ elementDescription: String, in image: CGImage, on screen: NSScreen) async -> CGPoint? {
        // TODO: load YOLOv8nano_macUI.mlpackage from the bundle, run a
        // VNCoreMLRequest, map the best box's center to an AX point.
        // Requires labeled macOS toolbar-icon training data we don't have yet.
        return nil
    }
}
