import Foundation

/// Classifies a transcribed voice question during a guide.
enum QuestionType {
    case concept                                   // "what is a VLOOKUP?" → text answer
    case location(targetLabel: String, region: ScreenRegion) // "where is X?" → dot
    case navigation(direction: String)             // "continue" / "go back" / "repeat"
    case unknown
}

/// Pure, local classification — no API call.
final class QuestionClassifier {

    private let locationKeywords = [
        "where", "find", "show me", "can't find", "cannot find", "locate",
        "point to", "which button", "where is", "where do i", "how do i get to",
        "i don't see", "i can't see", "not seeing", "don't see"
    ]

    private let navigationKeywords = [
        "continue", "carry on", "go back", "previous", "next step", "skip",
        "repeat", "say again", "again", "start over", "restart"
    ]

    func classify(_ text: String) -> QuestionType {
        let lower = text.lowercased()

        for keyword in navigationKeywords where lower.contains(keyword) {
            return .navigation(direction: lower)
        }
        for keyword in locationKeywords where lower.contains(keyword) {
            return .location(targetLabel: extractTarget(from: lower), region: inferRegion(from: lower))
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
