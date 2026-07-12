import Foundation

/// Decodes the JSON step plan returned by the backend.
/// Tolerant of minor variations (markdown fences, missing `app`, string indices).
enum PlanParser {
    static func parsePlan(from data: Data, fallbackTask: String) throws -> GuidePlan {
        // First try a straight decode.
        if let plan = try? JSONDecoder().decode(GuidePlan.self, from: data) {
            return plan
        }

        // The backend may wrap JSON in markdown fences or return loosely typed
        // values. Normalise and re-parse manually.
        guard let raw = String(data: data, encoding: .utf8) else {
            throw APIError.decodingError
        }
        let cleaned = stripMarkdownFences(raw)

        guard let cleanedData = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: cleanedData) as? [String: Any] else {
            throw APIError.decodingError
        }

        let task = (object["task"] as? String) ?? fallbackTask
        let app = (object["app"] as? String) ?? (object["appName"] as? String) ?? "Unknown"

        // Steps may be at the root ("steps") or, on the existing mobile backend,
        // wrapped in a success envelope with the same key.
        let rawSteps = (object["steps"] as? [[String: Any]]) ?? []

        let steps: [Step] = rawSteps.enumerated().compactMap { offset, dict in
            stepFromDict(dict, fallbackIndex: offset + 1)
        }

        guard !steps.isEmpty else { throw APIError.decodingError }
        return GuidePlan(task: task, app: app, steps: steps, demo: (object["demo"] as? Bool) ?? false)
    }

    /// Builds a Step from a loosely-typed dictionary (shared by plan + replan).
    static func stepFromDict(_ dict: [String: Any], fallbackIndex: Int) -> Step? {
        let index = (dict["index"] as? Int)
            ?? (dict["stepNumber"] as? Int)
            ?? Int("\(dict["index"] ?? dict["stepNumber"] ?? "")")
            ?? fallbackIndex
        guard let instruction = dict["instruction"] as? String else { return nil }

        let findDescription = (dict["findDescription"] as? String)
            ?? (dict["elementDescription"] as? String)
            ?? instruction
        let targetLabel = (dict["targetLabel"] as? String) ?? ""
        let elementDescription = (dict["elementDescription"] as? String) ?? findDescription

        // action defaults to "click" unless specified.
        let actionRaw = (dict["action"] as? String)?.lowercased() ?? "click"
        let action = StepAction(rawValue: actionRaw) ?? .click
        let key = dict["key"] as? String
        let region = ScreenRegion(lenient: dict["screenRegion"] as? String)
        let targetTypeRaw = (dict["targetType"] as? String)?.lowercased() ?? "text"
        let targetType = StepTargetType(rawValue: targetTypeRaw) ?? .text
        let controlKind = ((dict["controlKind"] as? String) ?? "").lowercased()
        let anchorText = (dict["anchorText"] as? String) ?? ""
        let anchorPosition = ((dict["anchorPosition"] as? String) ?? "").lowercased()
        let autoAdvanceSeconds = (dict["autoAdvanceSeconds"] as? Double)
            ?? (dict["autoAdvanceSeconds"] as? NSNumber)?.doubleValue ?? 0
        let silent = (dict["silent"] as? Bool) ?? false
        let advanceOnAnyClick = (dict["advanceOnAnyClick"] as? Bool) ?? false

        return Step(
            index: index,
            instruction: instruction,
            findDescription: findDescription,
            targetLabel: targetLabel,
            elementDescription: elementDescription,
            action: action,
            key: key,
            screenRegion: region,
            targetType: targetType,
            controlKind: controlKind,
            anchorText: anchorText,
            anchorPosition: anchorPosition,
            autoAdvanceSeconds: autoAdvanceSeconds,
            silent: silent,
            advanceOnAnyClick: advanceOnAnyClick
        )
    }

    /// Parses the saved-guide response. The existing backend returns
    /// `{ success, id, link }`; the macOS model uses `{ id, url }`.
    static func parseSavedGuide(from data: Data) throws -> SavedGuide {
        if let guide = try? JSONDecoder().decode(SavedGuide.self, from: data) {
            return guide
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else {
            throw APIError.decodingError
        }
        let url = (object["url"] as? String) ?? (object["link"] as? String) ?? ""
        return SavedGuide(id: id, url: url)
    }

    /// Parses a /recover response: a corrected label/instruction and/or a
    /// replan (new steps from the current point onward).
    static func parseRecover(from data: Data) -> RecoverResult {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return RecoverResult(visibleLabel: "", updatedInstruction: "", replan: false, steps: [], scrollDirection: "")
        }
        let visibleLabel = (object["visibleLabel"] as? String) ?? (object["targetLabel"] as? String) ?? ""
        let instruction = (object["instruction"] as? String) ?? ""
        let replan = (object["replan"] as? Bool) ?? false
        let scrollDirection = (object["scrollDirection"] as? String) ?? ""
        let rawSteps = (object["steps"] as? [[String: Any]]) ?? []
        let steps = rawSteps.enumerated().compactMap { offset, dict in
            stepFromDict(dict, fallbackIndex: offset + 1)
        }
        return RecoverResult(
            visibleLabel: visibleLabel,
            updatedInstruction: instruction,
            replan: replan && !steps.isEmpty,
            steps: steps,
            scrollDirection: ["up", "down", "left", "right"].contains(scrollDirection) ? scrollDirection : ""
        )
    }

    static func stripMarkdownFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            // Drop the opening fence (``` or ```json) and trailing fence.
            result = result.replacingOccurrences(of: "```json", with: "")
            result = result.replacingOccurrences(of: "```", with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
