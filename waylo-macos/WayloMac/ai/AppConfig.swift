import Foundation

/// Centralised app configuration. The backend URL is never hardcoded in
/// source — it is resolved (in priority order) from:
///   1. The `WAYLO_BACKEND_URL` environment variable (useful for local dev / tests)
///   2. The `WayloBackendURL` key in Info.plist
///   3. A safe localhost default
enum AppConfig {
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
