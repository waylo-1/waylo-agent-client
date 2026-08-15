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
        // ── Mail / messaging ──
        ("envelope.open", "open mail"), ("envelope.badge", "unread mail"),
        ("tray.full", "all mail"), ("tray.2", "inbox"),
        ("paperplane.fill", "send"), ("arrow.up.circle", "send"),
        ("exclamationmark.circle", "important"), ("nosign", "spam"),
        ("folder.badge.person.crop", "shared folder"), ("at", "mention"),
        ("text.badge.plus", "add label"), ("mail.stack", "mailboxes"),
        // ── Files / Finder ──
        ("doc.badge.plus", "new document"), ("doc.on.doc.fill", "duplicate"),
        ("square.and.arrow.down.on.square", "save"), ("externaldrive", "drive"),
        ("internaldrive", "disk"), ("icloud", "icloud"),
        ("icloud.and.arrow.up", "upload"), ("icloud.and.arrow.down", "download"),
        ("folder.fill", "folder"), ("doc.zipper", "compress"),
        ("sidebar.left", "sidebar"), ("sidebar.right", "inspector"),
        ("rectangle.split.3x1", "columns"), ("square.grid.3x3", "grid"),
        ("photo.on.rectangle", "gallery"), ("tag.fill", "tag"),
        ("folder.badge.gearshape", "folder settings"), ("shippingbox", "box"),
        // ── Text / document editing ──
        ("textformat.size", "text size"), ("textformat.abc", "spelling"),
        ("character", "font"), ("a.magnify", "find text"),
        ("text.justify", "justify"), ("text.indent", "indent"),
        ("increase.indent", "indent"), ("decrease.indent", "outdent"),
        ("list.bullet.indent", "list"), ("checklist", "checklist"),
        ("highlighter", "highlight"), ("pencil.tip", "draw"),
        ("textformat.superscript", "superscript"), ("textformat.subscript", "subscript"),
        ("paintpalette", "colors"), ("eyedropper", "color picker"),
        ("text.quote", "quote"), ("function", "formula"),
        ("tablecells.badge.ellipsis", "table options"), ("chart.pie", "chart"),
        ("chart.line.uptrend.xyaxis", "chart"), ("photo.badge.plus", "insert image"),
        // ── Media / playback ──
        ("backward.fill", "previous"), ("forward.fill", "next"),
        ("backward.end.fill", "rewind"), ("forward.end.fill", "skip"),
        ("shuffle", "shuffle"), ("repeat", "repeat"),
        ("speaker.wave.3", "volume up"), ("speaker.wave.1", "volume down"),
        ("volume.fill", "volume"), ("record.circle", "record"),
        ("camera.fill", "camera"), ("camera.rotate", "flip camera"),
        ("video.fill", "video"), ("video.slash", "stop video"),
        ("mic.slash", "mute mic"), ("waveform", "audio"),
        ("airplayvideo", "airplay"), ("rectangle.on.rectangle", "picture in picture"),
        ("arrow.up.left.and.arrow.down.right", "fullscreen"), ("captions.bubble", "captions"),
        // ── Communication ──
        ("bubble.left.and.bubble.right", "chat"), ("message", "message"),
        ("phone.fill", "call"), ("phone.arrow.up.right", "outgoing call"),
        ("person.2", "contacts"), ("person.badge.plus", "add contact"),
        ("person.crop.circle.badge.plus", "add person"), ("hand.wave", "greeting"),
        ("bell.slash", "mute notifications"), ("bell.badge", "notifications"),
        // ── Navigation / arrows ──
        ("chevron.up", "up"), ("chevron.down", "down"),
        ("arrow.up", "up"), ("arrow.down", "down"),
        ("arrow.up.right", "open link"), ("arrow.turn.up.right", "forward"),
        ("arrow.backward.circle", "back"), ("arrow.forward.circle", "forward"),
        ("chevron.up.chevron.down", "expand"), ("chevron.right.2", "expand"),
        ("arrow.up.and.down", "resize"), ("arrow.left.and.right", "resize"),
        ("arrowtriangle.down.fill", "dropdown"), ("chevron.down.circle", "expand"),
        // ── System / status ──
        ("bolt.fill", "power"), ("battery.25", "low battery"),
        ("wifi.slash", "no wifi"), ("antenna.radiowaves.left.and.right", "signal"),
        ("airplane", "airplane mode"), ("moon.fill", "do not disturb"),
        ("sun.max.fill", "brightness"), ("display", "display"),
        ("keyboard", "keyboard"), ("cursorarrow", "pointer"),
        ("gauge", "performance"), ("thermometer", "temperature"),
        ("lock.open", "unlock"), ("key", "password"),
        ("faceid", "face id"), ("touchid", "touch id"),
        ("shield", "security"), ("hand.raised", "privacy"),
        ("network", "network"), ("globe", "web"),
        // ── Editing / actions ──
        ("plus.circle.fill", "add"), ("minus.circle", "remove"),
        ("multiply", "close"), ("checkmark.seal", "verified"),
        ("arrow.triangle.2.circlepath", "sync"), ("arrow.2.squarepath", "refresh"),
        ("square.and.pencil", "edit"), ("rectangle.and.pencil.and.ellipsis", "edit"),
        ("trash.slash", "restore"), ("arrow.uturn.left", "undo"),
        ("arrow.uturn.right", "redo"), ("wand.and.stars", "auto"),
        ("crop", "crop"), ("rotate.left", "rotate left"), ("rotate.right", "rotate right"),
        ("selection.pin.in.out", "select"), ("lasso", "select"),
        ("scissors.badge.ellipsis", "cut"), ("square.on.square", "layers"),
        // ── Shapes / misc ──
        ("circle", "circle"), ("square", "square"),
        ("app", "app"), ("app.badge", "app badge"),
        ("puzzlepiece", "extension"), ("cube", "3d"),
        ("bookmark.fill", "bookmark"), ("flag.fill", "flag"),
        ("pin", "pin"), ("pin.fill", "pin"),
        ("bag", "shopping"), ("bag.badge.plus", "add to bag"),
        ("dollarsign.circle", "money"), ("percent", "discount"),
        ("calendar.badge.plus", "add event"), ("clock.arrow.circlepath", "history"),
        ("alarm", "alarm"), ("timer", "timer"),
        ("hourglass", "loading"), ("ellipsis.circle.fill", "more options"),
    ]

    /// Seed once (guarded by UserDefaults). Only marks itself done when the
    /// uploads actually land, so it safely RETRIES on a later launch if the
    /// backend wasn't reachable/redeployed yet. Bump the key to re-seed.
    static func seedOnceIfNeeded() {
        let key = "waylo.seededIconRefs.v3"   // bumped: much larger SF Symbols set
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        Task.detached(priority: .utility) {
            var ok = 0
            for (symbol, label) in entries {
                guard let cg = render(symbol: symbol),
                      let (b64, _) = ScreenCapturer.compressedJPEGBase64(cg, maxWidth: 128) else { continue }
                if await WayloAPIClient.shared.uploadIconReferenceResult(label: label, imageBase64: b64) {
                    ok += 1
                }
            }
            // Mark done only if most uploads succeeded — else retry next launch.
            if ok >= entries.count / 2 {
                UserDefaults.standard.set(true, forKey: key)
                DebugLogger.log("ICONREF", "seeded \(ok)/\(entries.count) SF Symbol reference icons")
            } else {
                DebugLogger.log("ICONREF", "seed incomplete (\(ok)/\(entries.count) landed) — will retry next launch (deploy the /icon-reference backend)")
            }
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
