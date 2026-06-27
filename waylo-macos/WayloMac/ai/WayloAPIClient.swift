import Foundation

/// HTTP client for the existing Waylo Railway backend (shared with Android).
final class WayloAPIClient {
    static let shared = WayloAPIClient()

    private let session: URLSession
    private var baseURL: String { AppConfig.backendBaseURL }

    private init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - POST /plan

    /// Generates a step plan from a natural-language task description.
    func generatePlan(task: String) async throws -> GuidePlan {
        guard let url = URL(string: "\(baseURL)/plan") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body = ["task": task, "platform": "macos"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        return try PlanParser.parsePlan(from: data, fallbackTask: task)
    }

    // MARK: - POST /vision-fallback

    /// Sends a screenshot + step context and gets a corrected element description.
    func visionFallback(
        screenshotBase64: String,
        task: String,
        stepIndex: Int,
        totalSteps: Int,
        findDescription: String,
        imageWidth: Int,
        imageHeight: Int
    ) async throws -> VisionFallbackResponse {
        guard let url = URL(string: "\(baseURL)/vision-fallback") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "screenshot": screenshotBase64,
            "task": task,
            "stepIndex": stepIndex,
            "totalSteps": totalSteps,
            "findDescription": findDescription,
            "imageWidth": imageWidth,
            "imageHeight": imageHeight,
            "platform": "macos"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }
        do {
            return try JSONDecoder().decode(VisionFallbackResponse.self, from: data)
        } catch {
            throw APIError.decodingError
        }
    }

    // MARK: - Step label cache

    /// Returns a previously-cached working AX label for a step, or nil.
    func lookupLabel(appName: String, stepDescription: String) async -> String? {
        guard !appName.isEmpty, !stepDescription.isEmpty,
              let url = URL(string: "\(baseURL)/label/lookup") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "appName": appName, "stepDescription": stepDescription
        ])
        guard let body = request.httpBody else { return nil }
        request.httpBody = body
        do {
            let (data, _) = try await session.data(for: request)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["found"] as? Bool) == true,
                  let label = obj["axLabel"] as? String, !label.isEmpty else { return nil }
            return label
        } catch {
            return nil
        }
    }

    /// Caches a working AX label for a step (fire-and-forget).
    func storeLabel(appName: String, stepDescription: String, axLabel: String) {
        guard !appName.isEmpty, !stepDescription.isEmpty, !axLabel.isEmpty,
              let url = URL(string: "\(baseURL)/label/store"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "appName": appName, "stepDescription": stepDescription, "axLabel": axLabel
              ]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = self.session
        Task { _ = try? await session.data(for: request) }
    }

    // MARK: - POST /qa (concept question answer)

    func askConcept(question: String, appName: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/qa") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body: [String: Any] = ["question": question, "appName": appName, "platform": "macos"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = obj["answer"] as? String else {
            throw APIError.decodingError
        }
        return answer
    }

    // MARK: - POST /nova-vision (Nova 2 Lite object detection)

    /// Returns a bounding box on a 0–1000 normalized scale (top-left origin).
    func novaVision(
        imageBase64: String,
        targetLabel: String,
        stepInstruction: String
    ) async throws -> NovaVisionResponse {
        guard let url = URL(string: "\(baseURL)/nova-vision") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "image_base64": imageBase64,
            "target_label": targetLabel,
            "step_instruction": stepInstruction
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return NovaVisionResponse(found: false, bbox: nil, label: nil)
        }
        let found = (obj["found"] as? Bool) ?? false
        let bbox = (obj["bbox"] as? [Double])
        let label = obj["label"] as? String
        return NovaVisionResponse(found: found, bbox: bbox, label: label)
    }

    // MARK: - POST /recover (self-healing)

    /// Sends a screenshot when local detection fails. The model can correct the
    /// element label for the current step, or replan all remaining steps.
    func recover(
        screenshotBase64: String,
        imageWidth: Int,
        imageHeight: Int,
        task: String,
        stepIndex: Int,
        totalSteps: Int,
        instruction: String,
        targetLabel: String
    ) async throws -> RecoverResult {
        guard let url = URL(string: "\(baseURL)/recover") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "screenshot": screenshotBase64,
            "imageWidth": imageWidth,
            "imageHeight": imageHeight,
            "task": task,
            "stepIndex": stepIndex,
            "totalSteps": totalSteps,
            "instruction": instruction,
            "targetLabel": targetLabel,
            "platform": "macos"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError
        }
        return PlanParser.parseRecover(from: data)
    }

    // MARK: - POST /guide

    /// Saves a guide and returns a shareable link.
    func saveGuide(task: String, steps: [Step]) async throws -> SavedGuide {
        guard let url = URL(string: "\(baseURL)/guide") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        let stepsPayload = steps.map {
            ["index": $0.index, "instruction": $0.instruction, "findDescription": $0.findDescription] as [String: Any]
        }
        // The existing backend's /guide expects `taskName` and `language`.
        let body: [String: Any] = ["taskName": task, "language": "en", "steps": stepsPayload]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }
        do {
            return try PlanParser.parseSavedGuide(from: data)
        } catch {
            throw APIError.decodingError
        }
    }
}

/// Result of asking the backend to recover from a failed locate.
struct RecoverResult {
    let visibleLabel: String
    let updatedInstruction: String
    let replan: Bool
    let steps: [Step]
}

/// Nova 2 Lite object-detection response.
struct NovaVisionResponse {
    let found: Bool
    let bbox: [Double]?   // [xMin, yMin, xMax, yMax] on a 0–1000 scale
    let label: String?
}

struct VisionFallbackResponse: Codable {
    let elementFound: Bool
    let x: Double?
    let y: Double?
    let confidence: Double?
    let updatedFindDescription: String
    let instruction: String
    let reasoning: String
}

struct SavedGuide: Codable {
    let id: String
    let url: String
}

enum APIError: Error, LocalizedError {
    case invalidURL
    case serverError
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The backend URL is invalid."
        case .serverError: return "The server returned an error."
        case .decodingError: return "Could not decode the server response."
        }
    }
}
