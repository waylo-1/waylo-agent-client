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
    /// `userContext`: an optional free-text note the user typed about where they
    /// are ("Pages is already open") — treated as ground truth for the plan's
    /// starting point, for native apps the AX snapshot can't fully see.
    func generatePlan(task: String, screenContext: String = "", sessionContext: String = "",
                      userContext: String = "") async throws -> GuidePlan {
        guard let url = URL(string: "\(baseURL)/plan") else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Plan generation is a full LLM call; a cold Claude/Bedrock response can
        // exceed 30s, which used to abort real (slow but successful) plans.
        request.timeoutInterval = 90

        var body: [String: Any] = ["task": task, "platform": "macos"]
        if !screenContext.isEmpty { body["screenContext"] = screenContext }
        if !sessionContext.isEmpty { body["sessionContext"] = sessionContext }
        if !userContext.isEmpty { body["userContext"] = userContext }
        if UserAccount.isSignedIn { body["userEmail"] = UserAccount.email }
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

    // MARK: - GET /curriculum/:query (hand-authored lesson lists)

    struct Curriculum: Decodable {
        struct Lesson: Decodable { let title: String; let task: String }
        let id: String
        let displayName: String
        let description: String
        let lessons: [Lesson]
    }

    /// Fetches the authored curriculum for a skill name, or nil (none exists /
    /// offline). Free-form sessions work fine without one.
    func fetchCurriculum(for skill: String) async -> Curriculum? {
        let enc = skill.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? skill
        guard !skill.isEmpty, let url = URL(string: "\(baseURL)/curriculum/\(enc)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Curriculum.self, from: data)
    }

    // MARK: - POST /act (agent mode: observe → ONE next action)

    struct AgentAction: Decodable {
        let act: String
        let id: Int?
        let text: String?
        let submit: Bool?
        let combo: String?
        let path: [String]?
        let name: String?
        let direction: String?
        let seconds: Double?
        let summary: String?
        let question: String?
        let say: String?
        let confirm: Bool?
        /// Computer-use grid coordinates (0-999, top-left origin) for
        /// press_at / type_at actions.
        let x: Int?
        let y: Int?
    }

    /// Sends the current numbered element list + history; returns the single
    /// next action chosen by the model.
    func agentAct(task: String, appName: String, context: String,
                  elements: [[String: Any]], history: [String]) async throws -> AgentAction {
        guard let url = URL(string: "\(baseURL)/act") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "task": task, "appName": appName, "context": context,
            "elements": elements, "history": history,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // A 404 means the backend predates /act — say so instead of a
            // generic "lost connection" (that misdirects debugging).
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                throw APIError.serverMessage("The server needs an update before I can do tasks myself — it doesn't have agent mode yet.")
            }
            if let detail = Self.serverErrorDetail(from: data) { throw APIError.serverMessage(detail) }
            throw APIError.serverError
        }
        return try JSONDecoder().decode(AgentAction.self, from: data)
    }

    /// Gemini COMPUTER-USE decider (experimental, flag-gated): plain screenshot
    /// in, grounded grid-coordinate action out. Errors make the caller fall
    /// back to the Set-of-Mark path for that turn.
    func agentActComputer(task: String, appName: String, imageBase64: String,
                          history: [String]) async throws -> AgentAction {
        guard let url = URL(string: "\(baseURL)/act-computer") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 40
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "task": task, "appName": appName, "imageBase64": imageBase64, "history": history,
        ])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw APIError.serverError }
        return try JSONDecoder().decode(AgentAction.self, from: data)
    }

    /// Set-of-Mark vision decider for AX-hostile apps: annotated screenshot +
    /// numbered marks → one action referencing badge ids.
    func agentActVision(task: String, appName: String, imageBase64: String,
                        marks: [[String: Any]], history: [String]) async throws -> AgentAction {
        guard let url = URL(string: "\(baseURL)/act-vision") else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 35
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "task": task, "appName": appName, "imageBase64": imageBase64,
            "marks": marks, "history": history,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                throw APIError.serverMessage("The server needs an update before I can work on apps like this one.")
            }
            if let detail = Self.serverErrorDetail(from: data) { throw APIError.serverMessage(detail) }
            throw APIError.serverError
        }
        return try JSONDecoder().decode(AgentAction.self, from: data)
    }

    // MARK: - POST /resolve/spotify (name → Spotify URI, for autonomous play)

    /// Resolves a free-text query ("drake", "one dance drake") to a playable
    /// Spotify URI via the backend (Spotify Web API search). Returns nil when
    /// the backend has no Spotify key configured or the search fails — the
    /// caller then falls back to opening the in-app search. Never throws.
    func resolveSpotifyURI(query: String) async -> String? {
        guard !query.isEmpty, let url = URL(string: "\(baseURL)/resolve/spotify") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 6
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": query]) else { return nil }
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let uri = obj["uri"] as? String, uri.hasPrefix("spotify:") else { return nil }
            return uri
        } catch {
            return nil
        }
    }

    /// Pushes a learned icon hash to the fleet-wide store (fire-and-forget).
    func storeIconHash(app: String, concept: String, hash: String) {
        guard !app.isEmpty, !concept.isEmpty, !hash.isEmpty,
              let url = URL(string: "\(baseURL)/icon/store"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "app": app, "concept": concept, "hashes": [hash],
              ]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = self.session
        Task { _ = try? await session.data(for: request) }
    }

    /// Pulls every user's learned icon hashes. Returns (app, concept, hashes)
    /// tuples; empty on any failure (sync is best-effort).
    func syncIconHashes() async -> [(app: String, concept: String, hashes: [String])] {
        guard let url = URL(string: "\(baseURL)/icon/sync") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = obj["icons"] as? [[String: Any]] else { return [] }
        return icons.compactMap { d in
            guard let app = d["app"] as? String, let concept = d["concept"] as? String,
                  let hashes = d["hashes"] as? [String] else { return nil }
            return (app, concept, hashes)
        }
    }

    /// Teaches the icon captioner a user-verified concept (fire-and-forget).
    func addIconConcept(name: String) {
        guard !name.isEmpty, let url = URL(string: "\(baseURL)/vocab/add"),
              let body = try? JSONSerialization.data(withJSONObject: ["name": name]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = self.session
        Task { _ = try? await session.data(for: request) }
    }

    /// Registers a signed-in user's email with the backend (fire-and-forget), so
    /// they appear in the users table for business/customer evidence.
    func register(email: String, name: String = "", source: String = "app") {
        guard !email.isEmpty, let url = URL(string: "\(baseURL)/register"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "email": email, "name": name, "source": source
              ]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = self.session
        Task { _ = try? await session.data(for: request) }
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

    // MARK: - POST /pick/store, /pick/lookup (fleet-wide ambiguity pick memory)

    /// Fire-and-forget: remember the user's disambiguation choice as a relative
    /// window position, so every user's next run of this step auto-resolves.
    func storePick(app: String, stepKey: String, relX: Double, relY: Double) {
        guard !app.isEmpty, !stepKey.isEmpty,
              let url = URL(string: "\(baseURL)/pick/store"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "app": app, "stepKey": stepKey, "relX": relX, "relY": relY
              ]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = self.session
        Task { _ = try? await session.data(for: request) }
    }

    /// The fleet's remembered relative pick (0–1 fractions) for a step, or nil.
    func lookupPick(app: String, stepKey: String) async -> (relX: Double, relY: Double)? {
        guard !app.isEmpty, !stepKey.isEmpty,
              let url = URL(string: "\(baseURL)/pick/lookup"),
              let body = try? JSONSerialization.data(withJSONObject: ["app": app, "stepKey": stepKey])
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4
        request.httpBody = body
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["found"] as? Bool) == true,
              let rx = (obj["relX"] as? Double) ?? (obj["relX"] as? NSNumber)?.doubleValue,
              let ry = (obj["relY"] as? Double) ?? (obj["relY"] as? NSNumber)?.doubleValue
        else { return nil }
        return (rx, ry)
    }

    // MARK: - POST /icon-reference (grow the labelled-icon dataset)

    /// Add a REAL labelled icon image to the fleet-wide image-match reference
    /// library — from the day-one seed and from every confirmed find. This is
    /// what teaches Waylo exactly what each icon looks like. Fire-and-forget.
    func uploadIconReference(label: String, imageBase64: String) {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, !imageBase64.isEmpty,
              let url = URL(string: "\(baseURL)/icon-reference"),
              let body = try? JSONSerialization.data(withJSONObject: ["label": clean, "image_b64": imageBase64])
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let session = self.session
        Task { _ = try? await session.data(for: request) }
    }

    /// Awaitable variant returning whether the upload was accepted (HTTP 200) —
    /// used by the seeder so it only marks itself done when references actually
    /// landed (e.g. not when the backend hasn't been redeployed yet).
    @discardableResult
    func uploadIconReferenceResult(label: String, imageBase64: String) async -> Bool {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2, !imageBase64.isEmpty,
              let url = URL(string: "\(baseURL)/icon-reference"),
              let body = try? JSONSerialization.data(withJSONObject: ["label": clean, "image_b64": imageBase64])
        else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = body
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        return true
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
        // Judge / max-accuracy: ask Gemini to reason about the exact element.
        if WayloConfig.maxAccuracy { body["high_accuracy"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Reasoning grounding is slower — give it room in max-accuracy mode.
        request.timeoutInterval = WayloConfig.maxAccuracy ? 35 : 20

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
        let container = (obj["container"] as? [Double])
        let hint = (obj["hint"] as? String) ?? ""
        return NovaVisionResponse(found: found, bbox: bbox, label: label,
                                  confidence: confidence, container: container, hint: hint)
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
        // Two YOLO models + SigLIP image-to-image dataset matching on the CPU
        // box can run ~15-20s; keep the client ceiling above the node proxy's
        // (25s) so the proxy's own timeout/response wins. A faster box returns
        // in ~2s and never approaches this.
        request.timeoutInterval = 30

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
    /// Bounding box (0–1000) of the CONTAINING group (toolbar/panel) — present
    /// even when the exact box is missing. Powers the region-highlight fallback.
    var container: [Double]? = nil
    /// One spoken sentence locating the target within its group ("the paperclip,
    /// right of the underlined A, just left of Send").
    var hint: String = ""
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
