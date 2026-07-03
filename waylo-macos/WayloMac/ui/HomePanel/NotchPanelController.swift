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

    /// The window is a FIXED size pinned to the top and is NEVER resized — that
    /// is what kills the hover glitch. Only its click-through flag and the
    /// SwiftUI content (which animates) change between states.
    private let panelWidth: CGFloat = 380
    private let panelMaxHeight: CGFloat = 470

    private var cancellables = Set<AnyCancellable>()
    private var hoverTimer: Timer?
    /// Debounce: number of consecutive ticks the cursor has been outside the
    /// expanded panel. Collapsing only after a couple of ticks stops flicker.
    private var outsideTicks = 0

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

        // Clicking into the panel (e.g. the task text field) makes it key.
        // Treat that as pinning — otherwise a hover-expanded panel collapses
        // the moment the cursor drifts away while the user is typing.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { _ in
            Task { @MainActor in
                let exp = NotchPanelController.expansion
                if !exp.pinned {
                    exp.pinned = true
                    exp.recompute()
                }
            }
        }

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
        if exp.pinned { outsideTicks = 0; return } // pinned stays open until closed

        let mouse = NSEvent.mouseLocation
        let frame = screen.frame
        let winX = frame.midX - panelWidth / 2

        if exp.expanded {
            // Stay open while the cursor is over the VISIBLE content (not the
            // whole fixed window). Collapse only after it's been outside for a
            // couple of ticks. The window itself never moves, so there is no
            // edge to oscillate across.
            let h = contentHeight(expanded: true)
            let active = CGRect(x: winX, y: frame.maxY - h, width: panelWidth, height: h)
                .insetBy(dx: -12, dy: -12)
            if active.contains(mouse) {
                outsideTicks = 0
            } else {
                outsideTicks += 1
                if outsideTicks >= 2 {
                    outsideTicks = 0
                    exp.hovering = false
                    exp.recompute()
                }
            }
        } else {
            // Expand only from the small notch zone at the very top edge. This
            // zone sits INSIDE the expanded content rect, so expanding can never
            // immediately move the cursor "outside" → no flicker loop.
            let m = NotchMetrics.current()
            let triggerW = (m.hasNotch ? m.width : 180) + 40
            let triggerH = max(m.height, 30) + 6
            let trigger = CGRect(
                x: frame.midX - triggerW / 2,
                y: frame.maxY - triggerH,
                width: triggerW,
                height: triggerH
            )
            if trigger.contains(mouse) {
                outsideTicks = 0
                exp.hovering = true
                exp.recompute()
            }
        }
        _ = window
    }

    /// Visible content height for the current state (used only for hit-testing;
    /// the window stays fixed at panelMaxHeight).
    private func contentHeight(expanded: Bool) -> CGFloat {
        let m = NotchMetrics.current()
        if expanded { return GuidanceEngine.shared.isRunning ? panelMaxHeight : 320 }
        return max(m.height, 32)
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

    /// Positions the FIXED-size window at the top and toggles interactivity.
    /// The window is never resized — content animates inside it instead — which
    /// is what eliminates the hover glitch. Click-through when collapsed so it
    /// never blocks the menu bar / notch.
    private func applyState() {
        guard let window = window, let screen = NSScreen.main else { return }
        let expanded = NotchPanelController.expansion.expanded
        let pinned = NotchPanelController.expansion.pinned

        let frame = screen.frame
        let rect = NSRect(
            x: frame.midX - panelWidth / 2,
            y: frame.maxY - panelMaxHeight,
            width: panelWidth,
            height: panelMaxHeight
        )
        if window.frame != rect {
            window.setFrame(rect, display: true)
        }

        // Click-through unless expanded → the wide window never blocks the menu
        // bar, and collapsing/expanding only flips this flag (no geometry change).
        window.ignoresMouseEvents = !expanded
        window.orderFrontRegardless()

        // Only take keyboard focus once the user has pinned it open (clicked in),
        // never on a passive hover — passive focus-stealing was part of the glitch.
        if expanded && pinned {
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
