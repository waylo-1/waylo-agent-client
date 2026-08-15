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

    /// LOCATION fast-path: one remembered spot per app|concept — the icon's
    /// relative position in the window plus a hash of a fixed box there. Next
    /// run we crop that exact spot and, IF the hash still matches (the icon is
    /// still there), click it WITHOUT the slow YOLO call. A moved/changed
    /// toolbar simply fails the hash check and falls through to vision.
    private struct LocEntry: Codable { var relX: Double; var relY: Double; var hash: String }
    private var locations: [String: LocEntry] = [:]
    private let locFileURL: URL
    /// Fixed crop size (points) for the location hash, so learn-time and
    /// recall-time framings match and the hashes are comparable.
    private static let locBoxPt: CGFloat = 48

    /// Match when within this Hamming distance (out of 64). Tight on purpose:
    /// better to miss and fall through to vision than to click the wrong icon.
    static let maxHamming = 6

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sahayak", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("icon_memory.json")
        locFileURL = dir.appendingPathComponent("icon_locations.json")
        load()
        loadLocations()
    }

    // MARK: - Location fast-path (skip YOLO for a learned icon)

    /// Remember WHERE a located icon is (relative to the window) + a hash of a
    /// fixed box there, so a later run can verify-and-click without YOLO.
    func rememberLocation(app: String, concept: String, axPoint: CGPoint, window: CGRect,
                          image: CGImage, screen: NSScreen) {
        guard !app.isEmpty, !concept.isEmpty, window.width > 1, window.height > 1 else { return }
        guard let crop = Self.cropBox(around: axPoint, in: image, screen: screen),
              let h = Self.aHash(crop) else { return }
        let rel = CGPoint(x: (axPoint.x - window.minX) / window.width,
                          y: (axPoint.y - window.minY) / window.height)
        guard (0...1).contains(rel.x), (0...1).contains(rel.y) else { return }
        let k = key(app: app, concept: concept)
        queue.sync {
            locations[k] = LocEntry(relX: Double(rel.x), relY: Double(rel.y), hash: String(h))
            persistLocations()
        }
        DebugLogger.log("ICONMEM", "remembered LOCATION '\(concept)' in \(app) at rel (\(String(format: "%.2f", rel.x)),\(String(format: "%.2f", rel.y)))")
    }

    /// If we remember this icon's spot AND the pixels there still hash-match,
    /// return the AX-global point to click — no YOLO, no vision, ~2ms. Else nil.
    func recallLocation(app: String, concept: String, window: CGRect,
                        image: CGImage, screen: NSScreen) -> CGPoint? {
        guard !app.isEmpty, !concept.isEmpty, window.width > 1, window.height > 1 else { return nil }
        guard let entry = queue.sync(execute: { locations[key(app: app, concept: concept)] }),
              let storedHash = UInt64(entry.hash) else { return nil }
        let point = CGPoint(x: window.minX + CGFloat(entry.relX) * window.width,
                            y: window.minY + CGFloat(entry.relY) * window.height)
        guard let crop = Self.cropBox(around: point, in: image, screen: screen),
              let h = Self.aHash(crop) else { return nil }
        let dist = Self.hamming(storedHash, h)
        guard dist <= Self.maxHamming else {
            DebugLogger.log("ICONMEM", "LOCATION recall miss '\(concept)' (dist \(dist) > \(Self.maxHamming)) — icon moved/changed")
            return nil
        }
        DebugLogger.log("ICONMEM", "LOCATION recall HIT '\(concept)' in \(app) at (\(Int(point.x)),\(Int(point.y))) dist \(dist) — skipping YOLO")
        return point
    }

    /// Crop a fixed `locBoxPt` square around an AX-global point out of the
    /// captured image (same conversion the detectors use).
    static func cropBox(around axPoint: CGPoint, in image: CGImage, screen: NSScreen) -> CGImage? {
        guard screen.frame.width > 1, screen.frame.height > 1 else { return nil }
        let axTop = ScreenCoordinates.primaryHeight - screen.frame.maxY
        let nx = (axPoint.x - screen.frame.minX) / screen.frame.width
        let ny = (axPoint.y - axTop) / screen.frame.height
        let halfW = Double(locBoxPt) / 2 / Double(screen.frame.width)
        let halfH = Double(locBoxPt) / 2 / Double(screen.frame.height)
        return image.cropNormalized(x: Double(nx) - halfW, y: Double(ny) - halfH, w: halfW * 2, h: halfH * 2)
    }

    private func persistLocations() {
        if let data = try? JSONEncoder().encode(locations) { try? data.write(to: locFileURL) }
    }
    private func loadLocations() {
        guard let data = try? Data(contentsOf: locFileURL),
              let dict = try? JSONDecoder().decode([String: LocEntry].self, from: data) else { return }
        locations = dict
        DebugLogger.log("ICONMEM", "loaded \(locations.count) icon location(s)")
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
        var inserted = false
        queue.sync {
            var set = store[k] ?? []
            // Skip near-duplicates to keep the set small.
            if set.contains(where: { Self.hamming($0, hash) <= 2 }) { return }
            set.insert(hash)
            store[k] = set
            persist()
            inserted = true
        }
        guard inserted else { return }
        DebugLogger.log("ICONMEM", "remembered '\(concept)' in \(app) (\(store[k]?.count ?? 0) known)")
        // Fleet-wide: the same app renders the same pixels on every Mac, so
        // one user's verified icon makes it instantly recognizable for all.
        WayloAPIClient.shared.storeIconHash(app: app.lowercased(),
                                            concept: Self.normalizeConcept(concept),
                                            hash: String(hash))
    }

    /// Merges the fleet's learned icon hashes into the local store (called at
    /// launch; best-effort, additive only).
    func syncFromBackend() async {
        let icons = await WayloAPIClient.shared.syncIconHashes()
        guard !icons.isEmpty else { return }
        var merged = 0
        queue.sync {
            for entry in icons {
                let k = "\(entry.app)|\(entry.concept)"
                var set = store[k] ?? []
                for h in entry.hashes.compactMap(UInt64.init) where !set.contains(h) {
                    set.insert(h)
                    merged += 1
                }
                store[k] = set
            }
            if merged > 0 { persist() }
        }
        if merged > 0 {
            DebugLogger.log("ICONMEM", "synced \(merged) fleet icon hash(es) across \(icons.count) concepts")
        }
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
