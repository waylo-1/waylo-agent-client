import AppKit

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

    private var observer: Any?
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    func start() {
        let workspace = NSWorkspace.shared

        // Seed with the current frontmost app if it isn't us.
        if let front = workspace.frontmostApplication, front.processIdentifier != selfPID {
            targetPID = front.processIdentifier
            targetName = front.localizedName ?? ""
        }

        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            // Ignore activations of Waylo itself.
            if app.processIdentifier != self.selfPID {
                self.targetPID = app.processIdentifier
                self.targetName = app.localizedName ?? ""
            }
        }
    }
}
