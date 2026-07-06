import Cocoa
import SwiftUI

/// Manages the transparent always-on-top overlay window and the red dot.
@MainActor
final class OverlayWindowController: NSWindowController {
    static let shared = OverlayWindowController()

    private var dotHostingView: NSView?
    /// Extra overlay views (numbered candidate badges). Cleared by hideDot and
    /// whenever a new dot/banner replaces them.
    private var extraHostingViews: [NSView] = []

    private func clearExtraViews() {
        extraHostingViews.forEach { $0.removeFromSuperview() }
        extraHostingViews = []
    }

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

    /// Shows a dotted region highlight around the target element's bounds with
    /// the instruction below — a clickable AREA instead of a bare point.
    /// `axRect` is the element's frame in AX (top-left origin) global coords.
    func showHighlight(axRect: CGRect, caption: String) {
        guard let window = window, let contentView = window.contentView else { return }
        window.setFrame(ScreenCoordinates.globalFrame, display: true)
        dotHostingView?.removeFromSuperview()
        dotHostingView = nil
        clearExtraViews()

        let pad: CGFloat = 6
        let box = CGSize(width: axRect.width + pad * 2, height: axRect.height + pad * 2)
        let hostW = max(box.width, 320)
        let captionH: CGFloat = 70
        let hostH = box.height + 8 + captionH

        // Box center in Cocoa coords; the hosting view is top-aligned so the
        // box sits over the element and the caption flows below it.
        let cocoaCenter = ScreenCoordinates.axToCocoa(CGPoint(x: axRect.midX, y: axRect.midY))
        let origin = window.frame.origin
        let boxTopCocoa = cocoaCenter.y + box.height / 2
        let host = NSHostingView(rootView: AnyView(
            HighlightBoxView(boxSize: box, caption: caption)
                .frame(width: hostW, height: hostH, alignment: .top)
        ))
        host.frame = CGRect(x: cocoaCenter.x - origin.x - hostW / 2,
                            y: boxTopCocoa - hostH - origin.y,
                            width: hostW, height: hostH)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        contentView.addSubview(host)
        dotHostingView = host
        window.orderFrontRegardless()
        DebugLogger.log("DOT", "highlight box \(Int(axRect.width))x\(Int(axRect.height)) at (\(Int(axRect.midX)),\(Int(axRect.midY)))")
        DebugState.shared.update(dot: CGPoint(x: axRect.midX, y: axRect.midY))
    }

    /// Shows numbered badges over several candidate matches plus an instruction
    /// banner. Used when detection is confident about MULTIPLE spots ("Empty"
    /// in three places) — the user clicks the correct one to continue.
    func showCandidateBadges(at axPoints: [CGPoint], caption: String) {
        guard let window = window, let contentView = window.contentView, !axPoints.isEmpty else { return }
        window.setFrame(ScreenCoordinates.globalFrame, display: true)
        dotHostingView?.removeFromSuperview()
        dotHostingView = nil
        clearExtraViews()

        let origin = window.frame.origin
        for (i, p) in axPoints.enumerated() {
            let cocoa = ScreenCoordinates.axToCocoa(ScreenCoordinates.clampToScreens(p))
            let size = CGSize(width: 56, height: 56)
            let host = NSHostingView(rootView: AnyView(CandidateBadgeView(number: i + 1, isPrimary: i == 0)))
            host.frame = CGRect(x: cocoa.x - origin.x - size.width / 2,
                                y: cocoa.y - origin.y - size.height / 2,
                                width: size.width, height: size.height)
            host.wantsLayer = true
            host.layer?.backgroundColor = .clear
            contentView.addSubview(host)
            extraHostingViews.append(host)
        }
        DebugLogger.log("DOT", "candidate badges shown: \(axPoints.count)")

        // Caption banner at the top of the screen the first candidate is on.
        let screen = NSScreen.screens.first {
            NSMouseInRect(ScreenCoordinates.axToCocoa(axPoints[0]), $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? .zero
        let size = CGSize(width: 460, height: 90)
        let host = NSHostingView(rootView: AnyView(BannerView(text: caption)))
        host.frame = CGRect(x: frame.midX - origin.x - size.width / 2,
                            y: frame.maxY - 120 - origin.y - size.height / 2,
                            width: size.width, height: size.height)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        contentView.addSubview(host)
        extraHostingViews.append(host)
        window.orderFrontRegardless()
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
        clearExtraViews()

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
        clearExtraViews()

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
        clearExtraViews()
        window?.orderOut(nil)
    }
}
