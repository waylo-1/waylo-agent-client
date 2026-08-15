import AppKit

/// Remembers WHICH one the user picked when detection was ambiguous — the
/// "ask once, never ask again" half of the numbered-badges fallback.
///
/// When a target (text, icon, or button) appears at several look-alike spots,
/// the resolver can't safely guess, so it shows numbered badges and the user
/// clicks the right one. We store that choice as a RELATIVE position inside the
/// target app's window (fractions 0–1), keyed by app + step. Next time the same
/// step is ambiguous we convert the remembered fraction back to a point on the
/// current window and auto-pick the nearest candidate — no question asked.
///
/// Position, not text, is the key: three buttons all labelled "Empty" have the
/// same label but different places, and "where you clicked last time" is what
/// actually disambiguates them. Layouts are stable per app/screen, so the
/// fraction transfers across window moves/resizes. Near-exact isn't required —
/// we only need the remembered point to fall closest to the right candidate.
final class PickMemory {
    static let shared = PickMemory()

    /// key "app|stepKey" → relative point (x,y in 0…1) within the window.
    private var store: [String: CGPoint] = [:]
    private let queue = DispatchQueue(label: "waylo.pickmemory")
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sahayak", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("pick_memory.json")
        load()
    }

    private func key(app: String, stepKey: String) -> String {
        "\(app.lowercased())|\(stepKey.lowercased())"
    }

    /// Store the user's pick as a fraction of the window it landed in.
    func remember(app: String, stepKey: String, axPoint: CGPoint, window: CGRect) {
        guard !app.isEmpty, !stepKey.isEmpty, window.width > 1, window.height > 1 else { return }
        let rel = CGPoint(x: (axPoint.x - window.minX) / window.width,
                          y: (axPoint.y - window.minY) / window.height)
        // Ignore a point that fell outside the window (bad frame) — a wild
        // fraction would mislead the next recall.
        guard (-0.05...1.05).contains(rel.x), (-0.05...1.05).contains(rel.y) else { return }
        let k = key(app: app, stepKey: stepKey)
        queue.sync {
            store[k] = rel
            persist()
        }
        DebugLogger.log("PICKMEM", "remembered pick for '\(stepKey)' in \(app) at rel (\(String(format: "%.2f", rel.x)),\(String(format: "%.2f", rel.y)))")
        // Fleet-wide: the same app lays out the same for everyone, so one user's
        // confirmed pick auto-resolves this step for all of them. Fire-and-forget.
        WayloAPIClient.shared.storePick(app: app.lowercased(), stepKey: stepKey.lowercased(),
                                        relX: Double(rel.x), relY: Double(rel.y))
    }

    /// Ensure the fleet's pick for this step is in the local store before an
    /// ambiguity is shown, so the (synchronous) recall can use it. No-op when we
    /// already have a local pick. Best-effort — a network miss just means we ask.
    func prefetch(app: String, stepKey: String) async {
        guard !app.isEmpty, !stepKey.isEmpty else { return }
        let k = key(app: app, stepKey: stepKey)
        if queue.sync(execute: { store[k] != nil }) { return }   // already known locally
        guard let remote = await WayloAPIClient.shared.lookupPick(app: app.lowercased(), stepKey: stepKey.lowercased()) else { return }
        let rel = CGPoint(x: remote.relX, y: remote.relY)
        queue.sync {
            if store[k] == nil { store[k] = rel; persist() }
        }
        DebugLogger.log("PICKMEM", "prefetched fleet pick for '\(stepKey)' in \(app) at rel (\(String(format: "%.2f", rel.x)),\(String(format: "%.2f", rel.y)))")
    }

    /// The remembered pick as an ABSOLUTE AX point on the given window, or nil.
    func recall(app: String, stepKey: String, window: CGRect) -> CGPoint? {
        guard !app.isEmpty, !stepKey.isEmpty, window.width > 1, window.height > 1 else { return nil }
        guard let rel = queue.sync(execute: { store[key(app: app, stepKey: stepKey)] }) else { return nil }
        return CGPoint(x: window.minX + rel.x * window.width,
                       y: window.minY + rel.y * window.height)
    }

    // MARK: - Persistence

    private func persist() {
        let dict = store.mapValues { [$0.x, $0.y] }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: fileURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Double]] else { return }
        store = dict.compactMapValues { arr in
            arr.count == 2 ? CGPoint(x: arr[0], y: arr[1]) : nil
        }
        DebugLogger.log("PICKMEM", "loaded \(store.count) remembered picks")
    }
}
