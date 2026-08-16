import Foundation
import AppKit

/// Scoring-based element search. Ported from Android's ElementFinder.kt and
/// hardened for desktop AX trees (stop-word filtering, off-screen rejection,
/// size-aware tie-breaking).
final class ElementFinder {
    static let shared = ElementFinder()

    /// Elements scoring below this are rejected outright so a fallback can trigger.
    private let minimumScore = 40

    /// Matches scoring in the [minimumScore, confidentScore) band are treated as
    /// LOW CONFIDENCE: logged and NOT returned, so a (often better) OCR result can
    /// win instead of a wrong-but-close AX match blocking it.
    private let confidentScore = 55

    /// Words that carry no matching signal — they appear in almost every
    /// findDescription and would otherwise inflate scores for wrong elements.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "in", "on", "at", "of", "to", "for", "and", "or",
        "with", "your", "you", "click", "tap", "select", "press", "open",
        "button", "menu", "item", "field", "input", "text", "tab", "icon",
        "toolbar", "bar", "top", "bottom", "left", "right", "this", "that",
        "into", "from", "is", "it"
    ]

    private init() {}

    /// Main entry point: takes a findDescription string, returns best matching element.
    func findElement(description: String) -> AXElementInfo? {
        let elements = AccessibilityReader.shared.getTargetAppElements()
        return findElement(description: description, in: elements)
    }

    /// Testable variant that scores against a provided element list.
    /// `preferredRole`: a controlKind ("button","menuItem",…) the target should
    /// be — real controls beat plain header/label text. `anchor`: a nearby text
    /// location + relative position ("below"/"right"/…) to disambiguate.
    func findElement(description: String, in elements: [AXElementInfo],
                     preferredRole: String? = nil,
                     anchor: (point: CGPoint, position: String)? = nil) -> AXElementInfo? {
        findElementWithAlternates(description: description, in: elements,
                                  preferredRole: preferredRole, anchor: anchor)?.best
    }

    /// Like findElement, but also returns near-tied CONFIDENT matches at other
    /// on-screen locations, so the caller can ASK the user instead of guessing
    /// when e.g. "Empty" appears in three places. Alternates must be spatially
    /// distinct — a row and the static text inside it are the same thing, not
    /// an ambiguity.
    func findElementWithAlternates(description: String, in elements: [AXElementInfo],
                                   preferredRole: String? = nil,
                                   anchor: (point: CGPoint, position: String)? = nil)
        -> (best: AXElementInfo, alternates: [AXElementInfo])? {
        guard !elements.isEmpty else { return nil }

        let query = description.lowercased()
        let allWords = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // Keywords used for word-level scoring exclude generic stop words.
        let keywords = allWords.filter { !Self.stopWords.contains($0) }
        let roleSet = Self.rolesFor(preferredRole)

        var scored: [(el: AXElementInfo, score: Int)] = []
        for element in elements {
            let score = scoreElement(element, query: query, keywords: keywords, roleSet: roleSet, anchor: anchor)
            if score >= minimumScore { scored.append((element, score)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            // Tie-break: prefer the more compact (control-sized) element over
            // a large container that happens to contain the same text.
            return area(a.el.frame) < area(b.el.frame)
        }

        guard let top = scored.first, top.score >= confidentScore else {
            if let first = scored.first { _ = lowConfidence(first.el, first.score) }
            return nil
        }

        var alternates: [AXElementInfo] = []
        for cand in scored.dropFirst() {
            guard cand.score >= confidentScore, top.score - cand.score <= 12 else { break }
            let distinct = ([top.el] + alternates).allSatisfy { existing in
                hypot(existing.center.x - cand.el.center.x,
                      existing.center.y - cand.el.center.y) > 40
            }
            if distinct { alternates.append(cand.el) }
            if alternates.count >= 3 { break }
        }
        if !alternates.isEmpty {
            DebugLogger.log("AX", "AMBIGUOUS: '\(top.el.title)' + \(alternates.count) near-tied matches — asking user")
        }
        return (top.el, alternates)
    }

    /// Maps a controlKind string to the set of acceptable AX roles.
    private static func rolesFor(_ kind: String?) -> Set<String> {
        switch (kind ?? "").lowercased() {
        case "button":   return ["AXButton", "AXMenuButton", "AXToolbarButton", "AXPopUpButton"]
        case "menuitem": return ["AXMenuItem", "AXMenuBarItem"]
        case "checkbox": return ["AXCheckBox", "AXRadioButton"]
        case "tab":      return ["AXTab"]
        case "link":     return ["AXLink"]
        case "field":    return ["AXTextField", "AXComboBox"]
        case "slider":   return ["AXSlider", "AXValueIndicator"]
        default:         return []
        }
    }

    /// True when the controlKind names a real interactive control (not plain text).
    static func isControlKind(_ kind: String) -> Bool { !rolesFor(kind).isEmpty }

    /// Canonicalises common British spellings to American so name matching is
    /// locale-agnostic (macOS labels controls "Control Centre", "Colour", etc.
    /// on en-GB/en-IN systems while planner labels are American).
    static func usSpelling(_ s: String) -> String {
        var t = s
        for (uk, us) in [("centre", "center"), ("colour", "color"), ("grey", "gray"),
                         ("favourite", "favorite"), ("customise", "customize"),
                         ("licence", "license"), ("catalogue", "catalog")] {
            t = t.replacingOccurrences(of: uk, with: us)
        }
        return t
    }

    /// Logs a low-confidence match and returns nil so the resolver falls through
    /// to OCR; returns nil silently for sub-threshold scores.
    private func lowConfidence(_ match: AXElementInfo?, _ score: Int) -> AXElementInfo? {
        if score >= minimumScore, let match = match {
            DebugLogger.log("AX", "LOW_CONFIDENCE_MATCH: '\(match.title.isEmpty ? match.description : match.title)' score=\(score) — falling through to OCR")
        }
        return nil
    }

    func scoreElement(_ element: AXElementInfo, query: String, keywords: [String],
                      roleSet: Set<String> = [], anchor: (point: CGPoint, position: String)? = nil) -> Int {
        // Reject elements that are invisible, zero-size, or off every screen.
        guard isOnScreen(element.frame) else { return Int.min }

        var score = 0
        // Normalise British→American spelling on BOTH sides, so a US query like
        // "Control Center" matches the macOS menu-bar item "Control Centre" (and
        // colour/color, grey/gray, …) instead of scoring too low and being rejected.
        let query = Self.usSpelling(query)
        let keywords = keywords.map { Self.usSpelling($0) }
        let elementText = Self.usSpelling(element.allText)
        let titleLower = Self.usSpelling(element.title.lowercased())
        let descLower = Self.usSpelling(element.description.lowercased())
        let titleWords = wordSet(titleLower)
        let descWords = wordSet(descLower)
        let textWords = wordSet(elementText)

        // Exact full match on title or description — strongest signal.
        if titleLower == query || descLower == query { score += 120 }
        else if elementText.contains(query) { score += 80 }

        // Keyword matches. Whole-word hits beat substring hits (so "file" no
        // longer scores against "profile"), and title hits beat generic text.
        var titleWordHits = 0
        for word in keywords {
            if titleWords.contains(word) {
                score += 35; titleWordHits += 1
            } else if titleLower.contains(word) {
                score += 16
            } else if descWords.contains(word) {
                score += 22
            } else if descLower.contains(word) {
                score += 12
            } else if textWords.contains(word) {
                score += 12
            } else if elementText.contains(word) {
                score += 6
            }
        }
        // Full coverage: every query keyword appears as a whole word in the title.
        if !keywords.isEmpty && titleWordHits == keywords.count { score += 40 }

        // REVERSE coverage: the planner's label is often LONGER than the real
        // control's short title — a step says "Empty Trash" but the actual
        // button is just "Empty". When every word of a short title appears in
        // the query, that's a strong signal. Restricted to real controls so
        // plain header/static text can't ride this bonus, and at least one
        // title word must be a query keyword (not just stop words).
        let isStaticish = element.role == "AXStaticText" || element.role == "AXRow" || element.role == "AXCell"
        if !isStaticish, !titleWords.isEmpty, titleWords.count <= 3,
           titleWords.contains(where: { keywords.contains($0) }),
           titleWords.allSatisfy({ keywords.contains($0) || Self.stopWords.contains($0) }) {
            score += 25
        }

        // Role boost based on intent words in the query.
        if query.contains("button") && (element.role == "AXButton" || element.role == "AXMenuButton" || element.role == "AXToolbarButton") { score += 15 }
        if query.contains("menu") && (element.role == "AXMenuItem" || element.role == "AXMenuBarItem") { score += 15 }
        if (query.contains("field") || query.contains("input") || query.contains("text box")) && element.role == "AXTextField" { score += 15 }
        if query.contains("tab") && element.role == "AXTab" { score += 15 }
        if query.contains("checkbox") && element.role == "AXCheckBox" { score += 15 }
        if query.contains("link") && element.role == "AXLink" { score += 15 }
        // Dock / app-icon intent.
        if (query.contains("dock") || query.contains("icon") || query.contains("app")) && element.role == "AXDockItem" { score += 18 }

        // Slightly prefer small, control-sized elements (real buttons) over
        // very large ones (panels/containers).
        if area(element.frame) > 0 && area(element.frame) < 40_000 { score += 8 }

        // Control-kind preference: a real control should win over plain header /
        // label text. Big boost when the role matches; penalize static text/rows
        // when an actual control was requested (so we don't click a header).
        if !roleSet.isEmpty {
            if roleSet.contains(element.role) {
                score += 45
            } else if element.role == "AXStaticText" || element.role == "AXRow" || element.role == "AXCell" {
                score -= 30
            } else if element.role == "AXMenuBarItem" || element.role == "AXMenuItem" {
                // A toolbar BUTTON step must never match the menu bar. Pages has
                // both a "Format" menu (menu bar) and a "Format" button
                // (toolbar); the menu-bar item used to win on an exact title
                // match and the whole guide then walked into the wrong menu.
                score -= 60
            }
        }

        // Anchor: prefer elements in the requested direction near a known text.
        if let anchor = anchor {
            let dx = element.center.x - anchor.point.x
            let dy = element.center.y - anchor.point.y   // AX: +y is downward
            let correctDirection: Bool
            switch anchor.position {
            case "below": correctDirection = dy > -10
            case "above": correctDirection = dy < 10
            case "left":  correctDirection = dx < 10
            case "right": correctDirection = dx > -10
            default:      correctDirection = true        // "near" / unspecified
            }
            let dist = (dx * dx + dy * dy).squareRoot()
            if correctDirection {
                // Up to +35, fading with distance (within ~400pt of the anchor).
                score += Int(max(0, 35 - dist / 12))
            } else {
                score -= 25
            }
        }

        return score
    }

    /// Lowercased alphanumeric word tokens of a string, for whole-word matching.
    private func wordSet(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    // MARK: - Geometry helpers

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// True if the element has a sane size and overlaps at least one display.
    private func isOnScreen(_ frame: CGRect) -> Bool {
        guard frame.width > 1, frame.height > 1 else { return false }
        // AX frames are top-left origin; convert to Cocoa to test against screens.
        let cocoaOrigin = ScreenCoordinates.axToCocoa(CGPoint(x: frame.minX, y: frame.maxY))
        let cocoaFrame = CGRect(origin: cocoaOrigin, size: frame.size)
        for screen in NSScreen.screens where screen.frame.intersects(cocoaFrame) {
            return true
        }
        return false
    }
}
