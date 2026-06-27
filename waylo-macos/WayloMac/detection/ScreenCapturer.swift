import AppKit
import ScreenCaptureKit

/// Captures a still image of a display using ScreenCaptureKit (the modern,
/// non-deprecated API). Returns both the CGImage and the NSScreen it came from
/// so callers can map normalized/pixel coordinates back to screen points.
final class ScreenCapturer {
    static let shared = ScreenCapturer()

    private init() {}

    struct Capture {
        let image: CGImage
        let screen: NSScreen
    }

    /// Captures the display the user is currently working on (the one under the
    /// cursor), excluding Waylo's own windows so the overlay/dot never appears
    /// in the screenshot.
    func captureActiveScreen() async -> Capture? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            // Pick the display under the cursor; fall back to the first display.
            let mouse = NSEvent.mouseLocation
            let targetScreen = NSScreen.screens.first {
                NSMouseInRect(mouse, $0.frame, false)
            } ?? NSScreen.main ?? NSScreen.screens.first

            guard let screen = targetScreen,
                  let screenID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == screenID })
                    ?? content.displays.first else {
                return nil
            }

            // Exclude our own app's windows (the overlay dot / panel).
            let myAppPID = ProcessInfo.processInfo.processIdentifier
            let myApps = content.applications.filter { $0.processID == myAppPID }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: myApps,
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            // Resolve the NSScreen for the chosen display.
            let nsScreen = NSScreen.screens.first { $0.displayID == display.displayID } ?? screen
            return Capture(image: cgImage, screen: nsScreen)
        } catch {
            print("[ScreenCapturer] capture failed: \(error)")
            return nil
        }
    }
}

extension NSScreen {
    /// The CoreGraphics display ID backing this screen.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension ScreenCapturer {
    /// Compresses a CGImage to a base64 JPEG (max `maxWidth` px wide, quality 0.6).
    /// Returns the base64 string and the compressed pixel size.
    static func compressedJPEGBase64(_ cgImage: CGImage, maxWidth: CGFloat = 1280) -> (String, CGSize)? {
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)
        guard originalWidth > 0, originalHeight > 0 else { return nil }

        let scale = min(1.0, maxWidth / originalWidth)
        let targetWidth = Int(originalWidth * scale)
        let targetHeight = Int(originalHeight * scale)

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let resized = context.makeImage() else { return nil }

        let bitmap = NSBitmapImageRep(cgImage: resized)
        guard let jpegData = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.6]
        ) else { return nil }

        return (jpegData.base64EncodedString(), CGSize(width: targetWidth, height: targetHeight))
    }
}
