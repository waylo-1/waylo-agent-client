import Foundation
import AppKit

/// Scoring-based element search. Ported from Android's ElementFinder.kt and
/// hardened for desktop AX trees (stop-word filtering, off-screen rejection,
/// size-aware tie-breaking).
final class ElementFinder {
    static let shared = ElementFinder()

    /// Elements scoring below this threshold are rejected so a fallback can trigger.
    private let minimumScore = 40

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
    func findElement(description: String, in elements: [AXElementInfo]) -> AXElementInfo? {
        guard !elements.isEmpty else { return nil }

        let query = description.lowercased()
        let allWords = query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        // Keywords used for word-level scoring exclude generic stop words.
        let keywords = allWords.filter { !Self.stopWords.contains($0) }

        var bestMatch: AXElementInfo?
        var bestScore = 0

        for element in elements {
            let score = scoreElement(element, query: query, keywords: keywords)
            if score > bestScore {
                bestScore = score
                bestMatch = element
            } else if score == bestScore, score >= minimumScore, let current = bestMatch {
                // Tie-break: prefer the more compact (control-sized) element over
                // a large container that happens to contain the same text.
                if area(element.frame) < area(current.frame) {
                    bestMatch = element
                }
            }
        }

        return bestScore >= minimumScore ? bestMatch : nil
    }

    func scoreElement(_ element: AXElementInfo, query: String, keywords: [String]) -> Int {
        // Reject elements that are invisible, zero-size, or off every screen.
        guard isOnScreen(element.frame) else { return Int.min }

        var score = 0
        let elementText = element.allText
        let titleLower = element.title.lowercased()
        let descLower = element.description.lowercased()

        // Exact full match on title or description — strongest signal.
        if titleLower == query || descLower == query { score += 120 }
        else if elementText.contains(query) { score += 80 }

        // Keyword matches. Title hits are worth far more than generic text hits.
        for word in keywords {
            if titleLower.contains(word) {
                score += 30
            } else if descLower.contains(word) {
                score += 18
            } else if elementText.contains(word) {
                score += 10
            }
        }

        // Role boost based on intent words in the query.
        if query.contains("button") && (element.role == "AXButton" || element.role == "AXMenuButton" || element.role == "AXToolbarButton") { score += 15 }
        if query.contains("menu") && element.role == "AXMenuItem" { score += 15 }
        if (query.contains("field") || query.contains("input") || query.contains("text box")) && element.role == "AXTextField" { score += 15 }
        if query.contains("tab") && element.role == "AXTab" { score += 15 }
        if query.contains("checkbox") && element.role == "AXCheckBox" { score += 15 }
        if query.contains("link") && element.role == "AXLink" { score += 15 }

        // Slightly prefer small, control-sized elements (real buttons) over
        // very large ones (panels/containers).
        if area(element.frame) > 0 && area(element.frame) < 40_000 { score += 8 }

        return score
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
