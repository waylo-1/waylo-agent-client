import Foundation

/// The signed-in user's identity for usage tracking + the free-tier limit.
/// The email is captured on the Vercel sign-in page (before download) and/or on
/// first launch; we persist it locally and send it with each /plan so the backend
/// can count tasks per user (business evidence + the 5-free-tasks paywall later).
enum UserAccount {
    private static let emailKey = "waylo.userEmail"
    private static let nameKey = "waylo.userName"

    /// The stored email, or "" if the user hasn't signed in yet.
    static var email: String {
        UserDefaults.standard.string(forKey: emailKey) ?? ""
    }

    static var name: String {
        UserDefaults.standard.string(forKey: nameKey) ?? ""
    }

    static var isSignedIn: Bool { !email.isEmpty }

    /// Save the email locally and register it with the backend (fire-and-forget),
    /// so it lands in the users table even if this is the first the server sees it.
    static func signIn(email: String, name: String = "", source: String = "app") {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard e.contains("@"), e.contains(".") else { return }
        UserDefaults.standard.set(e, forKey: emailKey)
        if !name.isEmpty { UserDefaults.standard.set(name, forKey: nameKey) }
        WayloAPIClient.shared.register(email: e, name: name, source: source)
    }

    static func signOut() {
        UserDefaults.standard.removeObject(forKey: emailKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }
}
