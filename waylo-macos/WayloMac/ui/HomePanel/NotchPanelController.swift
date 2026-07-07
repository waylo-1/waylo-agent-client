import Cocoa
import SwiftUI
import Combine

/// Hosts a Dynamic-Island / Boring-Notch style UI hanging from the Mac notch.
///
/// Interaction is CLICK-DRIVEN (modeled on farzaa/clicky's MenuBarPanelManager),
/// not hover-polling — the old 20Hz cursor poll + fixed oversized window was
/// the source of the lag and the "stuck / swallows clicks" bugs. Instead:
///   - collapsed while a guide runs → a small click-through-ish pill at the
///     notch showing progress; clicking it opens the full panel;
///   - not running & not open → the window is hidden (the menu-bar icon opens it);
///   - open → the window is sized to FIT the content (no dead transparent area),
///     takes key focus for typing, and a click-outside monitor dismisses it
///     (exactly like an NSPopover).
@MainActor
final class NotchPanelController: NSWindowController {

    static let expansion = NotchExpansion()

    private let panelWidth: CGFloat = 380

    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?
    private var hostingController: NSHostingController<NotchRootView>!

    convenience init() {
        let panel = NotchWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 40),
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
        self.hostingController = hosting

        // Re-layout when the open state or the running state changes. These are
        // discrete events (a click, a guide starting/finishing) — no polling.
        NotchPanelController.expansion.$expanded
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.applyState() } }
            .store(in: &cancellables)
        GuidanceEngine.shared.$isRunning
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in self?.applyState() } }
            .store(in: &cancellables)
        // The running indicator changes height between states; keep it snug.
        GuidanceEngine.shared.$state
            .removeDuplicates()
            .sink { [weak self] _ in Task { @MainActor in if !NotchPanelController.expansion.expanded { self?.applyState() } } }
            .store(in: &cancellables)
    }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() { applyState() }

    /// Menu-bar icon / ⌃⌥⌘W: toggle the full panel open/closed.
    func toggle() {
        NotchPanelController.expansion.expanded.toggle()
        applyState()
    }

    func expand() {
        NotchPanelController.expansion.expanded = true
        applyState()
    }

    // MARK: - Layout (content-sized, no fixed oversized window)

    private func applyState() {
        // Anchor to the BUILT-IN (notched) display when there is one — a notch
        // panel floating on an external monitor makes no sense.
        guard let window = window, let screen = NotchMetrics.anchorScreen else { return }
        let expanded = NotchPanelController.expansion.expanded
        let running = GuidanceEngine.shared.isRunning

        // Neither open nor guiding → hide entirely; the menu-bar icon reopens it.
        if !expanded && !running {
            hidePanel()
            return
        }

        // Size the window to the SwiftUI content's natural height so there is no
        // transparent dead zone to swallow clicks (the old bug).
        window.setContentSize(NSSize(width: panelWidth, height: 10)) // let it grow from small
        let fitting = hostingController.view.fittingSize
        let height = max(28, min(fitting.height, screen.frame.height - 40))

        // On a notched Mac the panel hugs the physical notch (that center strip
        // has no menu items). On non-notch Macs the menu bar center is REAL
        // menu-bar space, so hang the panel just below it instead of covering it.
        var top = screen.frame.maxY
        if !NotchMetrics.current().hasNotch {
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            top -= max(0, menuBarHeight)
        }

        let rect = NSRect(
            x: screen.frame.midX - panelWidth / 2,
            y: top - height,
            width: panelWidth,
            height: height
        )
        window.setFrame(rect, display: true)

        // Collapsed pill is clickable (small window → no dead zone). Expanded
        // panel is interactive and takes key focus for the text field.
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()

        if expanded {
            // Nonactivating panel: becoming key is enough for the text field.
            // Do NOT activate the app — that would steal focus from the target
            // app mid-guide (closing its menus), which clicky also avoids.
            window.makeKeyAndOrderFront(nil)
            installClickOutsideMonitor()
        } else {
            removeClickOutsideMonitor()
        }
    }

    private func hidePanel() {
        removeClickOutsideMonitor()
        window?.orderOut(nil)
    }

    // MARK: - Click-outside dismissal (NSPopover-style, like clicky)

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        // Global monitor fires only for clicks in OTHER apps (not our panel),
        // so any click outside collapses the panel — clicks inside are handled
        // by SwiftUI and never reach here.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let window = self.window else { return }
                let click = NSEvent.mouseLocation
                if window.frame.contains(click) { return }
                NotchPanelController.expansion.expanded = false
                self.applyState()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }
}

/// Shared open state. `expanded` drives the full panel; the collapsed pill is
/// shown automatically while a guide runs. No hover state — interaction is
/// click-driven (open via menu-bar icon / hotkey / clicking the pill; close
/// via the chevron or a click outside).
final class NotchExpansion: ObservableObject {
    @Published var expanded = false
}
