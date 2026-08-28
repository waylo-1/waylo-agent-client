import Foundation

/// Centralised app configuration. The backend URL is never hardcoded in
/// source — it is resolved (in priority order) from:
///   1. The `WAYLO_BACKEND_URL` environment variable (useful for local dev / tests)
///   2. The `WayloBackendURL` key in Info.plist
///   3. A safe localhost default
enum AppConfig {
    /// HACKATHON (All Things Agentic): the GenKit + Gemini 3.5 backend on Google
    /// Cloud Run. The plan "brain" (`/plan`) is routed here so planning runs
    /// through GenKit + Gemini; detection (YOLO), the vision fallback, and the
    /// Postgres/Aurora caches stay on `backendBaseURL` (the primary backend).
    static let genkitBaseURL = "https://waylo-agent-506434766076.asia-south1.run.app"

    static var backendBaseURL: String {
        if let env = ProcessInfo.processInfo.environment["WAYLO_BACKEND_URL"],
           !env.isEmpty {
            return env.trimmingTrailingSlash()
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "WayloBackendURL") as? String,
           !plist.isEmpty,
           !plist.contains("YOUR_RAILWAY") {
            return plist.trimmingTrailingSlash()
        }
        // Fallback for local development.
        return "http://localhost:3000"
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
