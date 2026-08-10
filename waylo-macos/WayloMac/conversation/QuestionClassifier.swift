import Foundation

/// Classifies a transcribed voice question during a guide.
enum QuestionType {
    case concept                                   // "what is a VLOOKUP?" → text answer
    case location(targetLabel: String, region: ScreenRegion) // "where is X?" → dot
    case navigation(direction: String)             // "continue" / "go back" / "repeat"
    case task(query: String)                       // "how do I make text bold" → GUIDE it
    case unknown
}

/// Pure, local classification — no API call.
final class QuestionClassifier {

    private let locationKeywords = [
        "where", "find", "show me", "can't find", "cannot find", "locate",
        "point to", "which button", "where is", "where do i", "how do i get to",
        "i don't see", "i can't see", "not seeing", "don't see"
    ]

    // Note: bare "again" is deliberately NOT a keyword — it appears in genuine
    // questions ("where is the Bold button again?") and would misroute them to
    // navigation. Only unambiguous repeat phrasings count.
    private let navigationKeywords = [
        "continue", "carry on", "go back", "previous", "next step", "skip",
        "repeat", "say again", "once again", "one more time", "show me again",
        "start over", "restart"
    ]

    // A real EXPLAIN question ("what is…", "why…") → narrate. Everything that
    // asks HOW to do something, or commands an action, is a TASK we should GUIDE.
    private let conceptStarters = ["what is", "what's", "what are", "what does",
        "why ", "explain", "tell me about", "what do you", "meaning of", "difference between"]
    private let taskStarters = ["how do i", "how to", "how can i", "how would i",
        "help me", "can you", "i want to", "i need to", "let's", "lets "]
    private let actionVerbs = ["make", "add", "insert", "create", "change", "turn on",
        "turn off", "enable", "disable", "delete", "remove", "select", "format",
        "set ", "write", "type", "send", "attach", "share", "download", "copy",
        "paste", "bold", "italic", "underline", "highlight", "resize", "rename",
        "move", "open ", "close", "save", "print", "align", "indent", "bullet"]

    func classify(_ text: String) -> QuestionType {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        for keyword in navigationKeywords where lower.contains(keyword) {
            return .navigation(direction: lower)
        }
        for keyword in locationKeywords where lower.contains(keyword) {
            return .location(targetLabel: extractTarget(from: lower), region: inferRegion(from: lower))
        }
        // Genuine "what is / why" explain questions stay concept (narrate).
        if conceptStarters.contains(where: { lower.hasPrefix($0) || lower.contains($0) }) {
            return .concept
        }
        // "How do I / how to …" or a bare action command ("make this bold", "add a
        // bar chart") is a follow-up TASK — GUIDE it, don't just narrate. This is
        // the heart of learn-mode: ask, and Waylo shows you how, in context.
        if taskStarters.contains(where: { lower.hasPrefix($0) })
            || actionVerbs.contains(where: { lower.hasPrefix($0) || lower.contains(" " + $0) }) {
            return .task(query: text)
        }
        return text.isEmpty ? .unknown : .concept
    }

    private func extractTarget(from text: String) -> String {
        let patterns = [
            "where is the (.+?)\\??$",
            "where is (.+?)\\??$",
            "find the (.+?)\\??$",
            "show me the (.+?)\\??$",
            "can'?t find the (.+?)\\??$",
            "cannot find the (.+?)\\??$",
            "i don'?t see the (.+?)\\??$",
            "locate the (.+?)\\??$"
        ]
        for pattern in patterns {
            if let capture = text.firstCapture(for: pattern) {
                return capture.trimmingCharacters(in: .whitespaces)
            }
        }
        return text
    }

    private func inferRegion(from text: String) -> ScreenRegion {
        if text.contains("toolbar") || text.contains("ribbon") || text.contains("format") { return .ribbon }
        if text.contains("menu") || text.contains("file") || text.contains("edit") { return .menuBar }
        if text.contains("sidebar") || text.contains("panel") { return .sidebar }
        return .fullScreen
    }
}

extension String {
    /// Returns the first capture group of `pattern`, if any.
    func firstCapture(for pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: self) else {
            return nil
        }
        return String(self[range])
    }
}
