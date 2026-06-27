import Cocoa
import SwiftUI
import Combine

/// Hosts a Dynamic-Island / Boring-Notch style UI hanging from the Mac notch.
/// Collapsed it hugs the notch (just an activity indicator during a guide);
/// hovering or clicking expands it into the full panel. Sizes are explicit per
/// state (no auto-size feedback loop).
@MainActor
final class NotchPanelController: NSWindowController {

    static let expansion = NotchExpansion()

    private var cancellables = Set<AnyCancellable>()
    private var hoverTimer: Timer?

    convenience init() {
        let panel = NotchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let hosting = NSHostingController(
            rootView: NotchRootView(expansion: NotchPanelController.expansion)
        )
        hosting.view.appearance = NSAppearance(named: .darkAqua)
        panel.contentViewController = hosting

        self.init(window: panel)

        // Re-size/position when expand or running state changes.
        NotchPanelController.expansion.$expanded
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.applyState() } }
            .store(in: &cancellables)
        GuidanceEngine.shared.$isRunning
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.applyState() } }
            .store(in: &cancellables)

        startHoverWatcher()
    }

    /// Polls the cursor: when it reaches the notch region, drop the panel down;
    /// when it leaves the expanded panel, retract. This is more reliable than
    /// SwiftUI .onHover, which doesn't fire under the menu bar / notch.
    private func startHoverWatcher() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHover() }
        }
    }

    private func updateHover() {
        guard let window = window, let screen = NSScreen.main else { return }
        let exp = NotchPanelController.expansion
        if exp.pinned { return } // pinned stays open until explicitly closed

        let mouse = NSEvent.mouseLocation
        let frame = screen.frame
        let m = NotchMetrics.current()

        if exp.expanded {
            // Retract once the cursor leaves the dropped-down panel.
            let bounds = window.frame.insetBy(dx: -6, dy: -6)
            if !bounds.contains(mouse) {
                exp.hovering = false
                exp.recompute()
            }
        } else {
            // Trigger zone: the notch itself, at the very top edge.
            let triggerW = (m.hasNotch ? m.width : 180) + 36
            let triggerH = max(m.height, 32) + 8
            let trigger = CGRect(
                x: frame.midX - triggerW / 2,
                y: frame.maxY - triggerH,
                width: triggerW,
                height: triggerH
            )
            if trigger.contains(mouse) {
                exp.hovering = true
                exp.recompute()
            }
        }
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() { applyState() }

    /// Menu-bar icon / hotkey: pin the panel open (or close it).
    func toggle() {
        NotchPanelController.expansion.pinned.toggle()
        NotchPanelController.expansion.recompute()
        applyState()
    }

    func expand() {
        NotchPanelController.expansion.pinned = true
        NotchPanelController.expansion.recompute()
        applyState()
    }

    /// Sets the window size for the current state, pinned to the notch.
    private func applyState() {
        guard let window = window, let screen = NSScreen.main else { return }
        let m = NotchMetrics.current()
        let expanded = NotchPanelController.expansion.expanded
        let running = GuidanceEngine.shared.isRunning

        let size: CGSize
        if expanded {
            size = CGSize(width: 360, height: running ? 470 : 300)
        } else if running {
            // A tight widening of the notch (step badge + equalizer on the sides).
            size = CGSize(width: m.width + 110, height: m.height)
        } else {
            // Idle: exactly the notch so the transparent content shows nothing.
            size = m.hasNotch
                ? CGSize(width: m.width, height: m.height)
                : CGSize(width: 180, height: 30)
        }

        let frame = screen.frame
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()

        if expanded {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Shared expand state. `expanded` is what the controller sizes against; it is
/// derived from hover (set by the view) OR pinned (set by click / menu toggle).
final class NotchExpansion: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    var hovering = false

    func recompute() {
        let next = hovering || pinned
        if next != expanded { expanded = next }
    }
}
