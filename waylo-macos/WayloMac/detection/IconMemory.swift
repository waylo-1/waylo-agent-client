import AppKit

/// On-device memory of icons Waylo has already located — the free, instant,
/// pixel-exact layer (Tier 5). When a paid vision call (Nova / Set-of-Mark)
/// successfully finds a textless icon, we store a tiny PERCEPTUAL HASH of that
/// icon keyed by app + concept. Next time the same icon appears we recognise it
/// by hash in O(1) — no model, ~1ms, and it can't drift onto the wrong control
/// because a hash match is near-exact. It starts empty and fills as the app is
/// used: the same self-improving loop as the label/plan caches, for pixels.
///
/// Average-hash (aHash): downscale a crop to 8×8 grayscale, threshold each
/// pixel against the mean → a 64-bit fingerprint. Two icons match when their
/// hashes are within a few bits (Hamming distance). Robust to small rendering
/// differences, decisive enough to never confuse two different icons.
final class IconMemory {
    static let shared = IconMemory()

    /// key "app|concept" → set of known 64-bit hashes.
    private var store: [String: Set<UInt64>] = [:]
    private let queue = DispatchQueue(label: "waylo.iconmemory")
    private let fileURL: URL

    /// Match when within this Hamming distance (out of 64). Tight on purpose:
    /// better to miss and fall through to vision than to click the wrong icon.
    static let maxHamming = 6

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sahayak", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("icon_memory.json")
        load()
    }

    private func key(app: String, concept: String) -> String {
        "\(app.lowercased())|\(Self.normalizeConcept(concept))"
    }

    /// Reduce a target label/description to a stable concept token.
    static func normalizeConcept(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\b(the|a|an|button|icon|in|on|to|of|toolbar)\b"#,
                                  with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Remember (write) — called on a confirmed vision hit

    func remember(crop: CGImage, app: String, concept: String) {
        guard !app.isEmpty, !concept.isEmpty, let hash = Self.aHash(crop) else { return }
        let k = key(app: app, concept: concept)
        queue.sync {
            var set = store[k] ?? []
            // Skip near-duplicates to keep the set small.
            if set.contains(where: { Self.hamming($0, hash) <= 2 }) { return }
            set.insert(hash)
            store[k] = set
            persist()
        }
        DebugLogger.log("ICONMEM", "remembered '\(concept)' in \(app) (\(store[k]?.count ?? 0) known)")
    }

    // MARK: - Recall (read) — pick the box that matches a known icon

    /// Given candidate crops (in the same order as their boxes), returns the
    /// index of the one that matches a remembered icon for app+concept, or nil.
    func bestMatch(crops: [CGImage], app: String, concept: String) -> Int? {
        guard !app.isEmpty, !concept.isEmpty else { return nil }
        let known: Set<UInt64> = queue.sync { store[key(app: app, concept: concept)] ?? [] }
        guard !known.isEmpty else { return nil }

        var best: (idx: Int, dist: Int)? = nil
        for (i, crop) in crops.enumerated() {
            guard let h = Self.aHash(crop) else { continue }
            let d = known.map { Self.hamming($0, h) }.min() ?? 64
            if d <= Self.maxHamming, best == nil || d < best!.dist { best = (i, d) }
        }
        if let b = best {
            DebugLogger.log("ICONMEM", "recall HIT '\(concept)' in \(app) → box \(b.idx) (dist \(b.dist))")
            return b.idx
        }
        return nil
    }

    var isEmpty: Bool { queue.sync { store.isEmpty } }

    // MARK: - Perceptual hash

    /// 8×8 average hash of a CGImage → 64-bit fingerprint.
    static func aHash(_ image: CGImage) -> UInt64? {
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n)
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let mean = px.reduce(0) { $0 + Int($1) } / (n * n)
        var hash: UInt64 = 0
        for (i, p) in px.enumerated() where Int(p) > mean { hash |= (1 << UInt64(i)) }
        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    // MARK: - Persistence

    private func persist() {
        // Store as { key: [hashes as strings] } (UInt64 exceeds JSON int range).
        let dict = store.mapValues { $0.map(String.init) }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: fileURL)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return }
        store = dict.mapValues { Set($0.compactMap(UInt64.init)) }
        DebugLogger.log("ICONMEM", "loaded \(store.count) icon concepts")
    }
}

extension CGImage {
    /// Crop a normalized (0–1, top-left) box out of this image.
    func cropNormalized(x: Double, y: Double, w: Double, h: Double) -> CGImage? {
        let rect = CGRect(x: Double(width) * x, y: Double(height) * y,
                          width: Double(width) * w, height: Double(height) * h)
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        return cropping(to: rect)
    }
}
