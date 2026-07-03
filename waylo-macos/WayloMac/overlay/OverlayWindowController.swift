import Cocoa
import SwiftUI

/// Manages the transparent always-on-top overlay window and the red dot.
@MainActor
final class OverlayWindowController: NSWindowController {
    static let shared = OverlayWindowController()

    private var dotHostingView: NSView?

    private convenience init() {
        let overlayWindow = OverlayWindow()
        self.init(window: overlayWindow)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Show the pulsing dot centered on the given point, with an optional caption
    /// shown just below it. `axPoint` is in AX (top-left origin) global coordinates.
    func showDot(at axPoint: CGPoint, caption: String = "") {
        let primary = ScreenCoordinates.primaryScreen?.frame ?? .zero

        // Clamp to the union of all displays (AX space) so a stray/out-of-bounds
        // point is never drawn off every screen. Multi-monitor points stay valid.
        let clamped = ScreenCoordinates.clampToScreens(axPoint)
        if clamped != axPoint {
            DebugLogger.log("DOT", String(format: "WARNING out-of-bounds axPoint=(%.1f,%.1f) clamped=(%.1f,%.1f) bounds=%@",
                axPoint.x, axPoint.y, clamped.x, clamped.y, "\(ScreenCoordinates.axGlobalBounds)"))
        }

        let inBounds = ScreenCoordinates.axGlobalBounds.insetBy(dx: -1, dy: -1).contains(axPoint)
        DebugLogger.logCoordinate("DOT", point: clamped,
            context: "primaryScreen=\(Int(primary.width))x\(Int(primary.height)) inBounds=\(inBounds)")
        DebugState.shared.update(dot: clamped, screen: primary)
        present(view: AnyView(DotWithCaption(caption: caption)), at: clamped, size: CGSize(width: 280, height: 120))
    }

    /// Show a loading spinner at the given point while a fallback is running.
    func showLoading(at axPoint: CGPoint) {
        present(view: AnyView(LoadingDotView()), at: axPoint, size: CGSize(width: 44, height: 44))
    }

    /// Show a bouncing up/down arrow at the scroll bar, prompting the user to
    /// scroll to reveal an off-screen target. `axPoint` is the scroll-bar anchor.
    func showScrollArrow(at axPoint: CGPoint, down: Bool, caption: String) {
        let clamped = ScreenCoordinates.clampToScreens(axPoint)
        DebugLogger.logCoordinate("SCROLL", point: clamped, context: "arrow down=\(down)")
        DebugState.shared.update(dot: clamped)
        present(view: AnyView(ScrollArrowView(down: down, caption: caption)),
                at: clamped, size: CGSize(width: 240, height: 130))
    }

    /// Show a centered instruction banner near the top of the active screen
    /// (used for non-click steps like "type the name" or "press Enter").
    /// Pass `autoDismissAfter` for transient banners (errors, spoken answers)
    /// that would otherwise linger on screen forever; step banners omit it and
    /// stay until the next step replaces them.
    func showBanner(_ text: String, autoDismissAfter seconds: TimeInterval? = nil) {
        guard let window = window, let contentView = window.contentView else { return }
        window.setFrame(ScreenCoordinates.globalFrame, display: true)
        dotHostingView?.removeFromSuperview()

        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? .zero

        let size = CGSize(width: 460, height: 90)
        let windowOrigin = window.frame.origin
        // Top-center of the active screen, ~120pt down from the top.
        let cocoaCenterX = frame.midX
        let cocoaCenterY = frame.maxY - 120
        let localX = cocoaCenterX - windowOrigin.x
        let localY = cocoaCenterY - windowOrigin.y

        let host = NSHostingView(rootView: AnyView(BannerView(text: text)))
        host.frame = CGRect(x: localX - size.width / 2, y: localY - size.height / 2, width: size.width, height: size.height)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        contentView.addSubview(host)
        dotHostingView = host
        window.orderFrontRegardless()

        if let seconds = seconds {
            Task { @MainActor [weak self, weak host] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                // Only dismiss if THIS banner is still the visible overlay —
                // a newer dot/banner must not be torn down by a stale timer.
                guard let self = self, let host = host, self.dotHostingView === host else { return }
                self.hideDot()
            }
        }
    }

    /// Places a SwiftUI overlay view centered horizontally on an AX point, with
    /// the dot anchored at the point and the caption flowing below.
    private func present(view: AnyView, at axPoint: CGPoint, size: CGSize) {
        guard let window = window, let contentView = window.contentView else { return }

        // Keep the overlay spanning all current displays.
        window.setFrame(ScreenCoordinates.globalFrame, display: true)

        // Remove any existing overlay view.
        dotHostingView?.removeFromSuperview()

        // AX (top-left) → Cocoa global (bottom-left), then relative to the
        // window origin (may be negative on multi-display setups).
        let cocoaGlobal = ScreenCoordinates.axToCocoa(axPoint)
        let windowOrigin = window.frame.origin
        let localCenter = CGPoint(
            x: cocoaGlobal.x - windowOrigin.x,
            y: cocoaGlobal.y - windowOrigin.y
        )

        // The hosting view is sized so the DOT sits at the top-center; the
        // caption extends downward. Position the view so its top-center anchor
        // lands exactly on localCenter.
        let frame = CGRect(
            x: localCenter.x - size.width / 2,
            y: localCenter.y - size.height + 22, // 22 = half the dot, keep dot on point
            width: size.width,
            height: size.height
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = frame
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        contentView.addSubview(hostingView)
        dotHostingView = hostingView
        window.orderFrontRegardless()
        DebugLogger.log("DOT", "present frame=\(frame.integral) winVisible=\(window.isVisible) winFrame=\(window.frame.integral)")
    }

    /// Hide the dot and remove the overlay window from screen.
    func hideDot() {
        dotHostingView?.removeFromSuperview()
        dotHostingView = nil
        window?.orderOut(nil)
    }
}
