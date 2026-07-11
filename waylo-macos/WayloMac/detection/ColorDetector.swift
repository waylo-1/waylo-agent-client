import AppKit

/// Finds a distinctly-coloured control by its COLOUR — the red camera/record
/// button, the green send arrow, a blue primary button. These are textless
/// (OCR can't help), invisible to the accessibility tree, and just "a shape"
/// to YOLO — but their colour is unmistakable. Pure on-device pixel analysis:
/// no model, ~30ms, runs before the paid vision layers when the target's
/// description names a colour.
///
/// Approach: downscale → mask pixels matching the target hue (in HSV, which is
/// robust to brightness/shadow) → find the largest connected blob → return its
/// centre in AX-global coordinates.
final class ColorDetector {

    /// Named colours the planner/description might use → an HSV predicate.
    /// Hue is 0–360; we also require enough saturation & value so grey/white/
    /// black UI chrome never matches a "colour".
    private struct HSVRange {
        let test: (_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> Bool
    }

    private static let colors: [String: HSVRange] = [
        "red":    HSVRange { h, s, v in (h <= 12 || h >= 348) && s > 0.45 && v > 0.30 },
        "orange": HSVRange { h, s, v in h > 12 && h <= 40 && s > 0.45 && v > 0.40 },
        "yellow": HSVRange { h, s, v in h > 40 && h <= 66 && s > 0.40 && v > 0.50 },
        "green":  HSVRange { h, s, v in h > 80 && h <= 165 && s > 0.35 && v > 0.30 },
        "teal":   HSVRange { h, s, v in h > 165 && h <= 195 && s > 0.35 && v > 0.30 },
        "blue":   HSVRange { h, s, v in h > 195 && h <= 255 && s > 0.35 && v > 0.30 },
        "purple": HSVRange { h, s, v in h > 255 && h <= 295 && s > 0.30 && v > 0.30 },
        "pink":   HSVRange { h, s, v in h > 295 && h < 348 && s > 0.25 && v > 0.55 },
    ]

    /// Returns the colour name mentioned in `text`, or nil.
    static func colorMentioned(in text: String) -> String? {
        let t = text.lowercased()
        // Longest/most specific first isn't needed — names are distinct words.
        for name in colors.keys where t.contains(name) { return name }
        if t.contains("grey") || t.contains("gray") { return nil } // not a "colour" target
        return nil
    }

    struct Hit {
        let point: CGPoint   // AX-global centre of the blob
        let frame: CGRect    // AX-global bounding box (for the region outline)
    }

    /// Finds the largest blob of `colorName` and returns its AX-global centre
    /// and bounding box. `within` (AX-global) restricts the search — pass the
    /// target app's window so a red Dock icon can't win a "red camera button"
    /// step; `region` is the coarser fallback when there's no window.
    func find(colorName: String, in image: CGImage, on screen: NSScreen,
              region: ScreenRegion = .fullScreen, within: CGRect? = nil) -> Hit? {
        guard let range = Self.colors[colorName] else { return nil }

        // Downscale for speed — 200px wide is plenty to locate a button. The
        // downscaled image represents the screen's LOGICAL frame (coordinates
        // are mapped back via frame/scaled, so retina 2x is handled).
        let scaleW = 200
        let scaleH = max(1, Int(CGFloat(scaleW) * CGFloat(image.height) / CGFloat(image.width)))

        var pixels = [UInt8](repeating: 0, count: scaleW * scaleH * 4)
        guard let ctx = CGContext(
            data: &pixels, width: scaleW, height: scaleH, bitsPerComponent: 8,
            bytesPerRow: scaleW * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: scaleW, height: scaleH))

        // Restrict the search rectangle (in downscaled px). Prefer the app
        // window (`within`, AX-global), else the coarse region. This is what
        // keeps a red Dock icon or menu-bar glyph from beating the real
        // in-window control.
        var xMin = 0, xMax = scaleW, yMin = 0, yMax = scaleH
        let axTopForCrop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        let localRect: CGRect? = {
            if let w = within {
                return CGRect(x: w.minX - screen.frame.minX, y: w.minY - axTopForCrop,
                              width: w.width, height: w.height)
            }
            return ScreenRegionHelper.localRect(for: region, on: screen)
        }()
        if let local = localRect {
            let s = CGFloat(scaleW) / screen.frame.width
            xMin = max(0, Int(local.minX * s)); xMax = min(scaleW, Int(local.maxX * s))
            yMin = max(0, Int(local.minY * s)); yMax = min(scaleH, Int(local.maxY * s))
            if xMax - xMin < 4 || yMax - yMin < 4 { xMin = 0; xMax = scaleW; yMin = 0; yMax = scaleH }
        }

        // Binary mask of matching pixels.
        var mask = [Bool](repeating: false, count: scaleW * scaleH)
        var anyMatch = false
        for y in yMin..<yMax {
            for x in xMin..<xMax {
                let i = (y * scaleW + x) * 4
                let (h, s, v) = Self.rgbToHSV(pixels[i], pixels[i+1], pixels[i+2])
                if range.test(h, s, v) { mask[y * scaleW + x] = true; anyMatch = true }
            }
        }
        guard anyMatch else { return nil }

        // Largest 4-connected blob via iterative flood fill (tracking bounds).
        var visited = [Bool](repeating: false, count: scaleW * scaleH)
        var best: (count: Int, sx: Int, sy: Int, minX: Int, maxX: Int, minY: Int, maxY: Int) = (0,0,0,0,0,0,0)
        var stack: [Int] = []
        for start in 0..<(scaleW * scaleH) where mask[start] && !visited[start] {
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            var count = 0, sumX = 0, sumY = 0
            var minX = scaleW, maxX = 0, minY = scaleH, maxY = 0
            while let p = stack.popLast() {
                count += 1
                let px = p % scaleW, py = p / scaleW
                sumX += px; sumY += py
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
                for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let nx = px + dx, ny = py + dy
                    guard nx >= 0, nx < scaleW, ny >= 0, ny < scaleH else { continue }
                    let np = ny * scaleW + nx
                    if mask[np] && !visited[np] { visited[np] = true; stack.append(np) }
                }
            }
            if count > best.count { best = (count, sumX, sumY, minX, maxX, minY, maxY) }
        }

        // Reject noise (too small) and full-window fills (too big — a coloured
        // background, not a control).
        let total = (xMax - xMin) * (yMax - yMin)
        guard best.count >= 12, Double(best.count) < Double(total) * 0.4 else {
            DebugLogger.log("COLOR", "\(colorName): largest blob \(best.count)px rejected (noise or too big)")
            return nil
        }

        // Blob centroid + bounds (downscaled px) → LOGICAL screen-local →
        // AX-global. The downscaled scaleW×scaleH image maps onto the screen's
        // LOGICAL frame (not the retina pixel size), so scale by frame/scaled —
        // this is what keeps the coords correct on a 2x display.
        let kx = screen.frame.width / CGFloat(scaleW)
        let ky = screen.frame.height / CGFloat(scaleH)
        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        let cxDown = CGFloat(best.sx) / CGFloat(best.count)
        let cyDown = CGFloat(best.sy) / CGFloat(best.count)
        let point = CGPoint(x: screen.frame.minX + cxDown * kx, y: axTop + cyDown * ky)
        // Bounding box, padded a touch so the outline sits around the control.
        let frame = CGRect(
            x: screen.frame.minX + CGFloat(best.minX) * kx - 4,
            y: axTop + CGFloat(best.minY) * ky - 4,
            width: CGFloat(best.maxX - best.minX + 1) * kx + 8,
            height: CGFloat(best.maxY - best.minY + 1) * ky + 8)
        DebugLogger.log("COLOR", "\(colorName): blob \(best.count)px → ax=(\(Int(point.x)),\(Int(point.y)))")
        return Hit(point: point, frame: frame)
    }

    /// RGB (0–255) → HSV with H in 0–360, S and V in 0–1.
    private static func rgbToHSV(_ r8: UInt8, _ g8: UInt8, _ b8: UInt8) -> (CGFloat, CGFloat, CGFloat) {
        let r = CGFloat(r8) / 255, g = CGFloat(g8) / 255, b = CGFloat(b8) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h: CGFloat = 0
        if d != 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        if h < 0 { h += 360 }
        let s = mx == 0 ? 0 : d / mx
        return (h, s, mx)
    }
}
