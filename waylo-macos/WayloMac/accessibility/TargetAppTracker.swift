import AppKit
import ApplicationServices

/// Tracks the application the user is actually working in — i.e. the most
/// recently activated app that is NOT Waylo itself.
///
/// This matters because opening Waylo's panel makes Waylo the frontmost app, so
/// `NSWorkspace.frontmostApplication` would point at Waylo and the AX reader
/// would read Waylo's own (tiny) UI instead of Word / Finder / Safari.
final class TargetAppTracker {
    static let shared = TargetAppTracker()

    /// PID of the app to guide the user through.
    private(set) var targetPID: pid_t?
    private(set) var targetName: String = ""
    private(set) var targetBundleID: String = ""

    /// Bundle-ID prefixes of web browsers. Page content in these apps is
    /// rendered by the web engine, not AppKit — the AX tree either lacks it
    /// entirely or nests it inside an AXWebArea, while browser chrome (tabs,
    /// bookmarks, the address bar) dominates the tree and collides with page
    /// words. `CoordinateResolver` routes web-content steps on this.
    /// Electron apps are NOT browsers here: AXManualAccessibility gives them a
    /// full, reliable tree.
    private static let browserBundlePrefixes = [
        "com.google.chrome",          // Chrome + Beta/Dev/Canary
        "com.apple.safari",           // Safari + Technology Preview
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.browser",
        "company.thebrowser.browser", // Arc
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
    ]

    /// True when the app the user is working in is a web browser.
    var isBrowser: Bool {
        let bid = targetBundleID.lowercased()
        return Self.browserBundlePrefixes.contains { bid.hasPrefix($0) }
    }

    private var observer: Any?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    func start() {
        let workspace = NSWorkspace.shared

        // Seed with the current frontmost app if it isn't us.
        if let front = workspace.frontmostApplication, front.processIdentifier != selfPID {
            targetPID = front.processIdentifier
            targetName = front.localizedName ?? ""
            targetBundleID = front.bundleIdentifier ?? ""
            enableElectronAccessibility(pid: front.processIdentifier)
            DebugLogger.logDuringTask("TRACKER", "seed target='\(targetName)' pid=\(targetPID ?? -1)")
        }

        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }

            let bid = (app.bundleIdentifier ?? "").lowercased()
            let isSelf = app.processIdentifier == self.selfPID
                || bid.contains("waylo") || bid.contains("sahayak")

            if isSelf {
                DebugLogger.logDuringTask("TRACKER", "WARNING ignoring activation of self/app '\(app.localizedName ?? "?")' (\(bid)) — keeping target='\(self.targetName)'")
                return
            }

            // Transient system UI (a notification banner, Spotlight, Control
            // Center, the screenshot bar) briefly "activates" and would
            // otherwise HIJACK the target mid-guide — the AX reader would then
            // search the notification instead of the user's app.
            if Self.isTransientSystemUI(app) {
                DebugLogger.logDuringTask("TRACKER", "ignoring transient system UI '\(app.localizedName ?? "?")' (\(bid)) — keeping target='\(self.targetName)'")
                return
            }

            let old = self.targetName
            self.targetPID = app.processIdentifier
            self.targetName = app.localizedName ?? ""
            self.targetBundleID = app.bundleIdentifier ?? ""
            self.enableElectronAccessibility(pid: app.processIdentifier)
            DebugLogger.logDuringTask("TRACKER", "target changed: '\(old)' -> '\(self.targetName)' pid=\(self.targetPID ?? -1)")
        }
    }

    /// True for system UI that momentarily takes focus but is never the app
    /// the user is being guided through: notification banners, Spotlight,
    /// Control Center, the screenshot toolbar, Dock, etc.
    private static func isTransientSystemUI(_ app: NSRunningApplication) -> Bool {
        // Agents/accessory processes never own a real document window.
        if app.activationPolicy != .regular { return true }
        let bid = (app.bundleIdentifier ?? "").lowercased()
        let blocked = [
            "com.apple.usernotificationcenter",
            "com.apple.notificationcenterui",
            "com.apple.spotlight",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
            "com.apple.dock",
            "com.apple.screencaptureui",
            "com.apple.wifi.wifiagent",
            "com.apple.coreservices.uiagent",
            "com.apple.loginwindow",
        ]
        return blocked.contains { bid == $0 || bid.hasPrefix($0) }
    }

    /// PIDs we've already unlocked, so the attribute isn't re-set (and
    /// re-logged) on every single app switch.
    private var electronUnlocked = Set<pid_t>()
    /// PIDs that don't support AXManualAccessibility (native apps: Chrome,
    /// Finder, Pages…). Remembered so we stop retrying and flooding the log.
    private var electronUnavailable = Set<pid_t>()

    /// Chromium/Electron apps (Slack, Spotify, VS Code, Discord, Chrome…)
    /// render their AX tree ONLY after a client sets AXManualAccessibility on
    /// them — otherwise they look empty to L0 and everything falls to vision.
    /// Idempotent and ignored by native apps, so it's safe to set on every
    /// target change. (Not AXEnhancedUserInterface — that one changes window
    /// behavior and is known to break window managers.)
    private func enableElectronAccessibility(pid: pid_t) {
        guard !electronUnlocked.contains(pid), !electronUnavailable.contains(pid) else { return }
        let app = AXUIElementCreateApplication(pid)
        let result = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result == .success {
            electronUnlocked.insert(pid)
            DebugLogger.logDuringTask("TRACKER", "AXManualAccessibility enabled for pid \(pid) (Electron-style app)")
            return
        }
        // Electron/Chromium apps often reject the attribute until their window
        // exists, so a set at activation time silently fails and their whole AX
        // tree stays invisible (Spotify's every step fell through to Nova).
        // Retry once shortly after; log the failure either way so it can't hide.
        DebugLogger.logDuringTask("TRACKER", "AXManualAccessibility set failed for pid \(pid) (AXError \(result.rawValue)) — retrying in 1.5s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, !self.electronUnlocked.contains(pid) else { return }
            let retry = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if retry == .success {
                self.electronUnlocked.insert(pid)
                DebugLogger.logDuringTask("TRACKER", "AXManualAccessibility enabled on retry for pid \(pid)")
            } else {
                self.electronUnavailable.insert(pid)   // native app — stop retrying/logging
                DebugLogger.logDuringTask("TRACKER", "AXManualAccessibility unavailable for pid \(pid) — native app (won't retry)")
            }
        }
    }
}
