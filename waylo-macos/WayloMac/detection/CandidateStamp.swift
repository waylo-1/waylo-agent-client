import AppKit

/// Judge-Mode Set-of-Mark: draws numbered red badges at AX-global candidate
/// points on a screenshot, so Gemini can CHOOSE which number is the target. The
/// badges sit on the real candidate elements, so whatever Gemini picks resolves
/// to a real element's exact centre — the reliable way to use vision (a
/// multiple-choice, not a raw-coordinate hunt).
enum CandidateStamp {
    /// Returns a base64 JPEG of the capture with badges "1..N" drawn at `points`
    /// (AX-global). Numbers match the order of `points` (badge i ⇒ points[i-1]).
    static func stamp(points: [CGPoint], on image: CGImage, screen: NSScreen,
                      maxWidth: CGFloat = 1280) -> String? {
        guard !points.isEmpty, screen.frame.width > 1, screen.frame.height > 1 else { return nil }
        let scale = min(1, maxWidth / CGFloat(image.width))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        // AX-global (top-left origin from primary) → captured image pixels.
        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        for (i, p) in points.enumerated() {
            let nx = (p.x - screen.frame.minX) / screen.frame.width
            let ny = (p.y - axTop) / screen.frame.height
            let cx = nx * CGFloat(w)
            let cy = (1 - ny) * CGFloat(h)   // CGContext origin is bottom-left → flip
            let label = "\(i + 1)"
            let r: CGFloat = label.count > 1 ? 15 : 13
            let badge = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
            NSColor(calibratedRed: 1, green: 0.15, blue: 0.2, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: badge).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: badge); ring.lineWidth = 2; ring.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: cx - size.width / 2, y: cy - size.height / 2), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let out = ctx.makeImage(),
              let (b64, _) = ScreenCapturer.compressedJPEGBase64(out, maxWidth: maxWidth) else { return nil }
        return b64
    }
}
