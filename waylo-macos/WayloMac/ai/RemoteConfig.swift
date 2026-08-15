import Foundation

/// Backend-driven remote config — the app fetches `/config` at launch so we can
/// tune behaviour (Judge Mode, the confidence floor, a broadcast message, an
/// update prompt) WITHOUT shipping a new build. Values are cached to UserDefaults
/// so they survive offline and are available immediately on the next launch.
///
/// To change anything: edit `backend_initial/app-config.json`, `git pull` on the
/// server — it's re-read per request, so it takes effect on the next fetch.
@MainActor
final class RemoteConfig: ObservableObject {
    static let shared = RemoteConfig()
    private let key = "waylo.remoteConfig"

    @Published private(set) var values: [String: Any]

    private init() {
        values = UserDefaults.standard.dictionary(forKey: key) ?? [:]
    }

    /// Fetch the latest config from the backend (called once at launch).
    func refresh() {
        Task {
            guard let obj = await WayloAPIClient.shared.fetchConfig() else { return }
            self.values = obj
            UserDefaults.standard.set(obj, forKey: self.key)
            DebugLogger.log("CONFIG", "remote config loaded — maxAccuracy=\(obj["maxAccuracy"] ?? "?") msg=\((obj["message"] as? String)?.isEmpty == false ? "yes" : "none")")
        }
    }

    // Typed accessors (nil/empty when the backend hasn't set them).
    var maxAccuracy: Bool? { values["maxAccuracy"] as? Bool }
    var novaMinConfidence: Double? { values["novaMinConfidence"] as? Double }
    var message: String { (values["message"] as? String) ?? "" }
    var messageLevel: String { (values["messageLevel"] as? String) ?? "info" }
    var latestVersion: String { (values["latestVersion"] as? String) ?? "" }
    var updateURL: String { (values["updateURL"] as? String) ?? "" }
}
