import Foundation

/// Client for the **Waylo Agent** on Google Cloud Run (All Things Agentic
/// Hackathon — the Collaborative Partner brain). This is intentionally SEPARATE
/// from `WayloAPIClient` (the shipping backend on AWS): the hackathon demo drives
/// the app from this cloud agent without touching any production path.
///
/// The agent decides ONE step at a time from the live screen + conversation, and
/// can ask a clarifying question (`status == "clarify"`). Persistent per-user
/// memory (Firestore) is handled server-side and keyed by `userId`.
final class WayloAgentClient {
    static let shared = WayloAgentClient()

    /// The deployed Cloud Run service (Gemini 3.5 + Genkit + Firestore).
    static let baseURL = "https://waylo-agent-506434766076.asia-south1.run.app"

    private let session = URLSession.shared
    private init() {}

    struct HistoryItem: Codable { let instruction: String; let outcome: String? }
    struct Answer: Codable { let question: String; let answer: String }

    struct Action: Codable {
        let instruction: String
        let findDescription: String?
        let elementType: String?
        let screenRegion: String?
        let visualDescription: String?
        let alternateLabels: [String]?
        let fallbackHint: String?
    }

    struct Question: Codable {
        let prompt: String
        let options: [String]
    }

    /// One agent decision. `status` is continue | done | recover | clarify.
    struct Decision: Codable {
        let status: String
        let reasoning: String?
        let action: Action?
        let question: Question?
        let memoryUsed: Int?

        var isDone: Bool { status == "done" }
        var isClarify: Bool { status == "clarify" }
    }

    /// Ask the agent for the next decision given the current screen + context.
    func nextStep(goal: String,
                  appName: String? = nil,
                  screen: String? = nil,
                  userId: String? = nil,
                  history: [HistoryItem] = [],
                  answers: [Answer] = []) async throws -> Decision {
        guard let url = URL(string: "\(Self.baseURL)/agent/next") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        var body: [String: Any] = ["goal": goal]
        if let appName, !appName.isEmpty { body["appName"] = appName }
        if let screen, !screen.isEmpty { body["screen"] = screen }
        if let userId, !userId.isEmpty { body["userId"] = userId }
        if !history.isEmpty {
            body["history"] = history.map { ["instruction": $0.instruction, "outcome": $0.outcome ?? ""] }
        }
        if !answers.isEmpty {
            body["answers"] = answers.map { ["question": $0.question, "answer": $0.answer] }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Decision.self, from: data)
    }
}
