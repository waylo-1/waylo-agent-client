import Cocoa
import ApplicationServices

/// Global hotkeys via a CGEventTap (session level). Unlike
/// `NSEvent.addGlobalMonitorForEvents`, this:
///   1. fires regardless of which app is focused — including Waylo itself, and
///   2. CONSUMES the matched event, so neither the OS nor other apps also react
///      to the combo (no more clashing with input-source switching etc).
///
/// Requires Accessibility permission (Waylo already needs it). All combos use
/// Control+Option+Command, which the OS and apps essentially never reserve.
///
/// The tap is installed on the MAIN run loop, so its callback runs on the main
/// thread. Registered actions hop to the main actor via `Task { @MainActor }`.
final class HotkeyManager: @unchecked Sendable {
    static let shared = HotkeyManager()

    struct Hotkey {
        let keyCode: CGKeyCode
        let flags: CGEventFlags     // required modifier set
        let name: String
        let action: () -> Void
    }

    /// An observe-only matcher: fires when a key combo is pressed but does NOT
    /// consume the event, so the combo still reaches the OS / focused app (e.g.
    /// ⌘Space still opens Spotlight while also advancing a Waylo guide step).
    struct KeyObserver {
        let id: UUID
        let keyCode: CGKeyCode
        let flags: CGEventFlags     // required modifier set ([] = no modifiers)
        let action: () -> Void
    }

    /// Observe-only click matcher. Unlike NSEvent global monitors — which miss
    /// clicks consumed by menu/Dock tracking loops — the event tap sees every
    /// click, so click-to-advance works on menu items and Dock icons too.
    /// `axPoint` is the click location in AX/Quartz global coords (top-left).
    struct ClickObserver {
        let id: UUID
        let action: (_ axPoint: CGPoint, _ isRight: Bool) -> Void
    }

    private var hotkeys: [Hotkey] = []
    private var observers: [KeyObserver] = []
    private var clickObservers: [ClickObserver] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Modifiers we treat as significant when matching (ignore caps-lock, fn…).
    private static let significantMask: UInt64 =
        CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskShift.rawValue

    /// Control+Option+Command — the safe "almost never reserved" modifier set.
    static let cmdOptCtrl: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    private init() {}

    func register(keyCode: CGKeyCode, flags: CGEventFlags = HotkeyManager.cmdOptCtrl, name: String, action: @escaping () -> Void) {
        hotkeys.append(Hotkey(keyCode: keyCode, flags: flags, name: name, action: action))
    }

    /// Adds a transient observe-only matcher (does NOT consume the event). Returns
    /// an id to remove it with `removeKeyObserver`. Used by the guidance engine to
    /// advance a "press this key combo" step the instant the user presses it —
    /// including system combos like ⌘Space that an NSEvent global monitor never
    /// sees (the OS consumes them for Spotlight before the monitor fires).
    @discardableResult
    func addKeyObserver(keyCode: CGKeyCode, flags: CGEventFlags, action: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers.append(KeyObserver(id: id, keyCode: keyCode, flags: flags, action: action))
        return id
    }

    func removeKeyObserver(_ id: UUID?) {
        guard let id = id else { return }
        observers.removeAll { $0.id == id }
    }

    /// Adds an observe-only click matcher (never consumes). Returns an id for
    /// `removeClickObserver`. The action runs on the main run loop thread.
    @discardableResult
    func addClickObserver(action: @escaping (_ axPoint: CGPoint, _ isRight: Bool) -> Void) -> UUID {
        let id = UUID()
        clickObservers.append(ClickObserver(id: id, action: action))
        return id
    }

    func removeClickObserver(_ id: UUID?) {
        guard let id = id else { return }
        clickObservers.removeAll { $0.id == id }
    }

    /// Creates and enables the event tap. If Accessibility isn't granted yet the
    /// tap can't be created — retry every few seconds so hotkeys come alive the
    /// moment the user grants permission (previously they stayed dead until the
    /// app was relaunched).
    func start() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,            // .defaultTap can consume events
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DebugLogger.log("HOTKEY", "could not create event tap (Accessibility not granted?) — retrying in 3s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.start()
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        DebugLogger.log("HOTKEY", "event tap active — \(hotkeys.count) hotkeys (⌃⌥⌘ combos)")
    }

    // MARK: - Event handling (runs on the main run loop thread)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap on timeout / heavy input — re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Clicks: observe-only, NEVER consumed. event.location is already in
        // Quartz global coordinates (top-left origin) — i.e. AX coords.
        if type == .leftMouseDown || type == .rightMouseDown {
            let point = event.location
            let isRight = type == .rightMouseDown
                || (type == .leftMouseDown && event.flags.contains(.maskControl))
            for obs in clickObservers { obs.action(point, isRight) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.rawValue & Self.significantMask
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        for hotkey in hotkeys where hotkey.keyCode == keyCode && mods == hotkey.flags.rawValue {
            // Consume the combo (incl. auto-repeats) so it never leaks to other
            // apps, but only FIRE the action on the initial press.
            if !isRepeat {
                DebugLogger.log("HOTKEY", "matched '\(hotkey.name)' — consuming event")
                hotkey.action()
            }
            return nil
        }

        // Observe-only matchers: fire on the initial press but DO NOT consume —
        // the combo must still reach the OS / focused app.
        if !isRepeat {
            for obs in observers where obs.keyCode == keyCode
                && mods == (obs.flags.rawValue & Self.significantMask) {
                obs.action()
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
