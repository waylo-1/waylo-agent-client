import AppKit
import CoreGraphics

/// Helpers for the Screen Recording permission, which is required for the
/// vision fallback (capturing the screen to send to the model). Without it,
/// `CGWindowListCreateImage` silently returns a black image.
enum ScreenRecordingPermission {

    /// Whether the app currently has Screen Recording access.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt to grant Screen Recording access. Safe to call
    /// repeatedly; the system only shows the prompt once per launch.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings directly to the Screen Recording pane.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
