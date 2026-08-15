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

    /// In-memory ring buffer of recent lines, powering the panel's
    /// "Copy debug report" — testers can paste a failure without ever
    /// touching `log show`. Guarded by a lock: log() is called from the main
    /// actor, detection tasks, and the nonisolated training logger.
    private static let bufferLock = NSLock()
    private static var buffer: [String] = []
    private static let bufferCap = 300
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ tag: String, _ message: String) {
        guard isEnabled else { return }
        // .public so the dynamic values aren't redacted to <private>.
        logger.log("[\(tag, privacy: .public)] \(message, privacy: .public)")

        bufferLock.lock()
        buffer.append("\(timeFormatter.string(from: Date())) [\(tag)] \(message)")
        if buffer.count > bufferCap { buffer.removeFirst(buffer.count - bufferCap) }
        bufferLock.unlock()

        #if DEBUG
        // Mirror to stderr for Xcode console runs; skipped in Release so
        // production builds don't pay for (or leak) per-line stderr writes.
        FileHandle.standardError.write("[Sahayak][\(tag)] \(message)\n".data(using: .utf8) ?? Data())
        #endif
    }

    /// Logs ONLY while a guide or agent task is running. For continuous
    /// observers (frontmost-app tracking) that would otherwise write an
    /// idle-time activity trail into the buffer — Waylo should record nothing
    /// about what the user does between tasks.
    static func logDuringTask(_ tag: String, _ message: String) {
        let active = Thread.isMainThread
            ? MainActor.assumeIsolated { GuidanceEngine.shared.isRunning || AgentEngine.shared.isRunning }
            : false
        guard active else { return }
        log(tag, message)
    }

    /// The most recent log lines (newest last).
    static func recentLines(_ count: Int = 200) -> [String] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return Array(buffer.suffix(count))
    }

    static func logCoordinate(_ tag: String, point: CGPoint, context: String) {
        log(tag, String(format: "point=(%.1f, %.1f) | %@", point.x, point.y, context))
    }

    static func logResolution(_ layer: String, found: Bool, point: CGPoint?, label: String?) {
        let p = point.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) } ?? "nil"
        log("RESOLVE", "layer=\(layer) found=\(found) point=\(p) label=\(label ?? "-")")
    }
}
