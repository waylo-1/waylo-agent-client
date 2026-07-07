import Foundation
import CoreGraphics
import os

/// Central debug logging. Messages are emitted via the unified logging system
/// (os.Logger) under a dedicated subsystem so they survive on modern macOS,
/// where NSLog output from a GUI app is not reliably captured.
///
/// Stream them with:
///   log stream --predicate 'subsystem == "com.waylo.macos.debug"' --level debug
/// or after the fact:
///   log show --predicate 'subsystem == "com.waylo.macos.debug"' --last 5m --info --debug
final class DebugLogger {
    static var isEnabled = true

    private static let logger = Logger(subsystem: "com.waylo.macos.debug", category: "Sahayak")

    static func log(_ tag: String, _ message: String) {
        guard isEnabled else { return }
        // .public so the dynamic values aren't redacted to <private>.
        logger.log("[\(tag, privacy: .public)] \(message, privacy: .public)")
        #if DEBUG
        // Mirror to stderr for Xcode console runs; skipped in Release so
        // production builds don't pay for (or leak) per-line stderr writes.
        FileHandle.standardError.write("[Sahayak][\(tag)] \(message)\n".data(using: .utf8) ?? Data())
        #endif
    }

    static func logCoordinate(_ tag: String, point: CGPoint, context: String) {
        log(tag, String(format: "point=(%.1f, %.1f) | %@", point.x, point.y, context))
    }

    static func logResolution(_ layer: String, found: Bool, point: CGPoint?, label: String?) {
        let p = point.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) } ?? "nil"
        log("RESOLVE", "layer=\(layer) found=\(found) point=\(p) label=\(label ?? "-")")
    }
}
