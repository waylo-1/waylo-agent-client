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
    /// `screenContext`: compact live AX-tree snapshot (ScreenContextBuilder)
    /// so the planner grounds steps in what's actually on screen.
    func generatePlan(task: String, screenContext: String = "") async throws -> GuidePlan {
        guard let url = URL(string: "\(baseURL)/plan") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Plan generation is a full LLM call; a cold Claude/Bedrock response can
        // exceed 30s, which used to abort real (slow but successful) plans.
        request.timeoutInterval = 90

        var body: [String: Any] = ["task": task, "platform": "macos"]
        if !screenContext.isEmpty { body["screenContext"] = screenContext }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // The backend reports actionable failures as {error, details}
            // (e.g. the Bedrock daily token quota being exhausted). Surface
            // that instead of a generic "server error".
            if let detail = Self.serverErrorDetail(from: data) {
                throw APIError.serverMessage(detail)
            }
            throw APIError.serverError
        }

        return try PlanParser.parsePlan(from: data, fallbackTask: task)
    }

    /// Extracts a human-readable failure reason from an error response body.
    private static func serverErrorDetail(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let detail = (obj["details"] as? String) ?? (obj["error"] as? String) ?? ""
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "appName": appName, "stepDescription": stepDescription
        ]) else { return nil }
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

    // MARK: - POST /ask-screen (vision Q&A about the current screen)

    /// Answers a free-form question using a screenshot of the current screen.
    func askScreen(question: String, imageBase64: String, appName: String) async throws -> String {
        guard let url = URL(string: "\(baseURL)/ask-screen") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [String: Any] = ["question": question, "screenshot": imageBase64, "appName": appName]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answer = obj["answer"] as? String else {
            throw APIError.serverError
        }
        return answer
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
        stepInstruction: String,
        ocrContext: String = ""
    ) async throws -> NovaVisionResponse {
        guard let url = URL(string: "\(baseURL)/nova-vision") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20

        var body: [String: Any] = [
            "image_base64": imageBase64,
            "target_label": targetLabel,
            "step_instruction": stepInstruction
        ]
        if !ocrContext.isEmpty { body["ocr_context"] = ocrContext }
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
        let confidence = (obj["confidence"] as? Double)
            ?? (obj["confidence"] as? NSNumber)?.doubleValue
        return NovaVisionResponse(found: found, bbox: bbox, label: label, confidence: confidence)
    }

    // MARK: - POST /plan/learn (remember a corrected plan)

    /// After a guide completes whose plan was corrected mid-run, persist the
    /// corrected steps keyed by the original task so it's right next time.
    /// Fire-and-forget.
    func learnPlan(task: String, steps: [Step]) {
        guard !task.isEmpty, !steps.isEmpty,
              let url = URL(string: "\(baseURL)/plan/learn") else { return }
        let stepDicts: [[String: Any]] = steps.map { s in
            [
                "index": s.index,
                "action": s.action.rawValue,
                "instruction": s.instruction,
                "targetLabel": s.targetLabel,
                "elementDescription": s.elementDescription,
                "findDescription": s.findDescription,
                "screenRegion": s.screenRegion.rawValue,
                "targetType": s.targetType.rawValue,
                "key": s.key as Any
            ]
        }
        let body: [String: Any] = ["task": task, "platform": "macos", "steps": stepDicts]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let session = self.session
        Task { _ = try? await session.data(for: request) }
    }

    /// Marks a plan wrong — removes it from the cache so it isn't reused. Fire-and-forget.
    func forgetPlan(task: String) {
        guard !task.isEmpty, let url = URL(string: "\(baseURL)/plan/forget"),
              let data = try? JSONSerialization.data(withJSONObject: ["task": task, "platform": "macos"]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let session = self.session
        Task { _ = try? await session.data(for: request) }
    }

    // MARK: - POST /detect-elements (Layer 2.5 dual-model YOLO)

    /// Sends a screenshot to the Railway proxy → Python YOLO microservice.
    /// Returns merged OmniParser + Screen2AX detections (normalized 0–1 boxes).
    func detectElements(
        imageBase64: String,
        targetLabel: String,
        stepInstruction: String,
        screenRegion: String
    ) async throws -> YOLODetectResponse {
        guard let url = URL(string: "\(baseURL)/detect-elements") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Two YOLO models + SigLIP matching on a CPU-only server measure ~5.5s;
        // 8s left almost no headroom and aborted valid detections. The server's
        // own proxy timeout (12s) is the real ceiling.
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "screenshot_b64": imageBase64,
            "target_label": targetLabel,
            "step_instruction": stepInstruction,
            "screen_region": screenRegion
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError
        }
        return try JSONDecoder().decode(YOLODetectResponse.self, from: data)
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
        targetLabel: String,
        userMessage: String = ""
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
            "userMessage": userMessage,
            "platform": "macos"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.serverError
        }
        return PlanParser.parseRecover(from: data)
    }

    // MARK: - POST /failure (detection analytics: successes, misses, corrections)

    /// One session id per app run, so events can be grouped server-side.
    static let sessionID = UUID().uuidString

    /// Fire-and-forget detection event. `source`: "auto_success" (a layer hit —
    /// includes which layer and the chosen box), "auto_miss" (all layers missed;
    /// include the screenshot), or "user_correction" (the user clicked elsewhere
    /// and the screen changed — their element is ground truth). Two weeks of
    /// this data shows exactly where accuracy is lost.
    func reportDetectionEvent(
        source: String,
        task: String,
        stepNumber: Int,
        findDescription: String,
        elementType: String = "",
        screenRegion: String = "",
        appName: String = "",
        layerReached: Int = -1,
        chosenBox: [String: Any]? = nil,
        correctedTarget: [String: Any]? = nil,
        screenshotBase64: String? = nil,
        screenWidth: Int = 0,
        screenHeight: Int = 0
    ) {
        guard !findDescription.isEmpty, let url = URL(string: "\(baseURL)/failure") else { return }
        var body: [String: Any] = [
            "sessionId": Self.sessionID,
            "taskDescription": task,
            "stepNumber": stepNumber,
            "findDescription": findDescription,
            "elementType": elementType,
            "screenRegion": screenRegion,
            "targetPackage": appName,      // app name plays the package role on macOS
            "layerReached": layerReached,
            "source": source,
        ]
        if let box = chosenBox { body["chosenBox"] = box }
        if let corrected = correctedTarget { body["correctedTarget"] = corrected }
        if let shot = screenshotBase64 {
            body["screenshotBase64"] = shot
            body["screenWidth"] = screenWidth
            body["screenHeight"] = screenHeight
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let session = self.session
        Task { _ = try? await session.data(for: request) }
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
    let scrollDirection: String   // "up" | "down" | "left" | "right" | ""
}

/// Nova 2 Lite object-detection response.
struct NovaVisionResponse {
    let found: Bool
    let bbox: [Double]?   // [xMin, yMin, xMax, yMax] on a 0–1000 scale
    let label: String?
    var confidence: Double? = nil  // Nova's self-reported 0–1 confidence
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
    /// A server failure with a human-readable reason from the backend
    /// (e.g. "Too many tokens per day, please wait before trying again.").
    case serverMessage(String)
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The backend URL is invalid."
        case .serverError: return "The server returned an error."
        case .serverMessage(let detail): return detail
        case .decodingError: return "Could not decode the server response."
        }
    }
}
