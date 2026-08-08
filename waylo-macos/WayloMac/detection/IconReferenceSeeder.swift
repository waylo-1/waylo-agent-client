import AppKit

/// Day-one seed for the icon dataset: renders ~120 common UI icons from Apple's
/// SF Symbols — the ACTUAL macOS icon language, so they closely match real app
/// toolbar icons (Mail's archive, Finder's share, …) — and uploads them as
/// labelled references to the fleet-wide image-match library. Runs ONCE.
///
/// SF Symbols are the right seed (unlike generic font glyphs, which didn't
/// transfer): most macOS apps draw these exact shapes. The library then keeps
/// growing from real confirmed finds, converging on pixel-exact per app.
enum IconReferenceSeeder {

    /// (SF Symbol name, concept label). One symbol may map to several labels
    /// (synonyms the planner might use). Unknown symbols are skipped safely.
    private static let entries: [(symbol: String, label: String)] = [
        ("archivebox", "archive"),
        ("trash", "delete"), ("trash", "trash"),
        ("arrowshape.turn.up.left", "reply"),
        ("arrowshape.turn.up.left.2", "reply all"),
        ("arrowshape.turn.up.right", "forward"),
        ("flag", "flag"),
        ("paperplane", "send"),
        ("paperclip", "attach"),
        ("magnifyingglass", "search"),
        ("gearshape", "settings"),
        ("plus", "add"), ("plus.circle", "add"),
        ("minus", "remove"),
        ("xmark", "close"), ("xmark.circle", "close"),
        ("star", "star"), ("star", "favorite"),
        ("heart", "like"),
        ("square.and.arrow.up", "share"),
        ("square.and.arrow.down", "download"),
        ("pencil", "edit"),
        ("doc", "document"), ("doc.text", "document"),
        ("folder", "folder"),
        ("folder.badge.plus", "new folder"),
        ("printer", "print"),
        ("envelope", "mail"),
        ("bell", "notifications"),
        ("person.crop.circle", "profile"), ("person", "profile"),
        ("calendar", "calendar"),
        ("clock", "time"),
        ("house", "home"),
        ("chevron.left", "back"), ("arrow.left", "back"),
        ("chevron.right", "next"), ("arrow.right", "next"),
        ("arrow.clockwise", "refresh"), ("arrow.clockwise", "reload"),
        ("ellipsis", "more"), ("ellipsis.circle", "more"),
        ("line.3.horizontal", "menu"),
        ("camera", "camera"),
        ("photo", "image"), ("photo", "photo"),
        ("mic", "microphone"),
        ("speaker.wave.2", "volume"),
        ("speaker.slash", "mute"),
        ("play.fill", "play"),
        ("pause.fill", "pause"),
        ("stop.fill", "stop"),
        ("checkmark", "done"), ("checkmark.circle", "confirm"),
        ("lock", "lock"),
        ("eye", "show"), ("eye.slash", "hide"),
        ("bookmark", "bookmark"),
        ("tag", "tag"), ("tag", "label"),
        ("bold", "bold"),
        ("italic", "italic"),
        ("underline", "underline"),
        ("strikethrough", "strikethrough"),
        ("text.alignleft", "align left"),
        ("text.aligncenter", "align center"),
        ("text.alignright", "align right"),
        ("list.bullet", "bulleted list"),
        ("list.number", "numbered list"),
        ("link", "link"),
        ("face.smiling", "emoji"),
        ("info.circle", "info"),
        ("questionmark.circle", "help"),
        ("exclamationmark.triangle", "warning"),
        ("line.3.horizontal.decrease.circle", "filter"),
        ("slider.horizontal.3", "adjust"),
        ("square.grid.2x2", "grid view"),
        ("list.bullet.rectangle", "list view"),
        ("arrow.up.arrow.down", "sort"),
        ("plus.magnifyingglass", "zoom in"),
        ("minus.magnifyingglass", "zoom out"),
        ("square.and.pencil", "compose"),
        ("tray", "inbox"),
        ("tray.and.arrow.down", "archive"),
        ("bin.xmark", "delete"),
        ("hand.thumbsup", "like"),
        ("bubble.left", "comment"),
        ("phone", "call"),
        ("phone.down.fill", "end call"),
        ("video", "video"),
        ("gift", "gift"),
        ("cart", "cart"),
        ("creditcard", "payment"),
        ("map", "map"),
        ("location", "location"),
        ("wifi", "wifi"),
        ("battery.100", "battery"),
        ("power", "power"),
        ("moon", "dark mode"),
        ("sun.max", "light mode"),
        ("bolt", "flash"),
        ("wrench.and.screwdriver", "tools"),
        ("chart.bar", "chart"),
        ("tablecells", "table"),
        ("textformat", "format"),
        ("paintbrush", "format"),
        ("scissors", "cut"),
        ("doc.on.doc", "copy"),
        ("doc.on.clipboard", "paste"),
        ("arrow.uturn.backward", "undo"),
        ("arrow.uturn.forward", "redo"),
        ("plus.app", "new"),
        ("rectangle.portrait.and.arrow.right", "sign out"),
        ("questionmark.circle.fill", "help"),
        ("gearshape.fill", "settings"),
    ]

    /// Seed once (guarded by UserDefaults). Renders + uploads in the background.
    /// Bump the key suffix to re-seed after changing the set.
    static func seedOnceIfNeeded() {
        let key = "waylo.seededIconRefs.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.global(qos: .utility).async {
            var uploaded = 0
            for (symbol, label) in entries {
                guard let cg = render(symbol: symbol),
                      let (b64, _) = ScreenCapturer.compressedJPEGBase64(cg, maxWidth: 128) else { continue }
                WayloAPIClient.shared.uploadIconReference(label: label, imageBase64: b64)
                uploaded += 1
                usleep(40_000)   // gentle pacing so we don't hammer the box
            }
            UserDefaults.standard.set(true, forKey: key)
            DebugLogger.log("ICONREF", "seeded \(uploaded) SF Symbol reference icons to the dataset")
        }
    }

    /// Render an SF Symbol as a black glyph centered on a white square — the
    /// look of a real toolbar icon. nil if the symbol name isn't available.
    static func render(symbol: String, canvas: CGFloat = 128) -> CGImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: canvas * 0.55, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let glyph = base.withSymbolConfiguration(cfg) else { return nil }

        // 1. Tint the glyph solid black on a transparent canvas.
        let gs = glyph.size
        guard gs.width > 0, gs.height > 0 else { return nil }
        let tinted = NSImage(size: gs)
        tinted.lockFocus()
        glyph.draw(at: .zero, from: NSRect(origin: .zero, size: gs), operation: .sourceOver, fraction: 1)
        NSColor.black.set()
        NSRect(origin: .zero, size: gs).fill(using: .sourceAtop)
        tinted.unlockFocus()

        // 2. Composite the black glyph, centered, onto a white square.
        let size = NSSize(width: canvas, height: canvas)
        let out = NSImage(size: size)
        out.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let scale = min((canvas * 0.66) / gs.width, (canvas * 0.66) / gs.height)
        let w = gs.width * scale, h = gs.height * scale
        tinted.draw(in: NSRect(x: (canvas - w) / 2, y: (canvas - h) / 2, width: w, height: h))
        out.unlockFocus()

        var rect = CGRect(origin: .zero, size: size)
        return out.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
