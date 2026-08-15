import Foundation

/// A continuous LEARNING SESSION: the user is learning one app/skill, and every
/// task until they end the session accrues to it. The session's compact text
/// summary rides along with each /plan request, so follow-ups work the way a
/// human teacher hears them — "now make it bold" means the chart title from
/// two tasks ago, in the app that's already open.
///
/// Deliberately tiny: a session is a skill name + the list of completed task
/// phrasings (~80–150 prompt tokens), never a transcript. Persisted to disk so
/// "Continue learning Google Sheets (3 lessons done)" survives relaunches.
@MainActor
final class SkillSession: ObservableObject {
    static let shared = SkillSession()

    struct Session: Codable, Identifiable {
        var id: String { skill.lowercased() }
        var skill: String
        var completed: [String]
        var startedAt: Date
        var updatedAt: Date
        /// Curriculum lesson index the user is on (nil = free-form session).
        var lessonIndex: Int?
    }

    /// The session currently in progress (tasks accrue to it), if any.
    @Published private(set) var active: Session?
    /// Past sessions, most recently used first — the "continue learning" list.
    @Published private(set) var stored: [Session] = []

    /// A short, ALWAYS-ON trail of the last few completed tasks (with timestamps),
    /// independent of any named "Learn the app" session. This is what makes a
    /// voice follow-up like "now send this photo on WhatsApp" remember that you
    /// just took a photo in Photo Booth — even when no learning session is active.
    struct RecentTask: Codable { var task: String; var at: Date }
    private var recentTasks: [RecentTask] = []
    private static let maxRecent = 5
    /// Only tasks finished within this window count as "just now" context, so an
    /// unrelated task an hour later isn't polluted by stale history.
    private static let recentWindow: TimeInterval = 15 * 60

    private let fileURL: URL
    private let recentURL: URL
    private static let maxStored = 8
    private static let maxCompletedRemembered = 12

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sahayak", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("skill_sessions.json")
        recentURL = dir.appendingPathComponent("recent_tasks.json")
        load()
    }

    // MARK: - Lifecycle

    /// Starts (or resumes) a session for a skill. Resuming keeps its history.
    func start(skill: String) {
        let clean = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let existing = stored.first(where: { $0.id == clean.lowercased() }) {
            active = existing
            DebugLogger.log("SESSION", "resumed '\(existing.skill)' (\(existing.completed.count) done)")
        } else {
            active = Session(skill: clean, completed: [], startedAt: Date(), updatedAt: Date(), lessonIndex: nil)
            DebugLogger.log("SESSION", "started learning '\(clean)'")
        }
    }

    /// Ends the session, keeping it in the stored list for later resuming.
    func end() {
        guard var session = active else { return }
        session.updatedAt = Date()
        upsertStored(session)
        active = nil
        DebugLogger.log("SESSION", "ended '\(session.skill)' (\(session.completed.count) done)")
    }

    /// Records a completed guide. Always appends to the ambient recent-tasks
    /// trail (so follow-ups have memory), and also to the named session if one
    /// is active.
    func recordCompleted(task: String) {
        let clean = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        // Ambient trail — always on, no session required.
        recentTasks.append(RecentTask(task: clean, at: Date()))
        if recentTasks.count > Self.maxRecent {
            recentTasks.removeFirst(recentTasks.count - Self.maxRecent)
        }
        persistRecent()
        DebugLogger.log("SESSION", "recent +task '\(clean)' (\(recentTasks.count) in trail)")

        // Named learning session, if the user started one.
        guard var session = active else { return }
        session.completed.append(clean)
        if session.completed.count > Self.maxCompletedRemembered {
            session.completed.removeFirst(session.completed.count - Self.maxCompletedRemembered)
        }
        session.updatedAt = Date()
        active = session
        upsertStored(session)
        DebugLogger.log("SESSION", "'\(session.skill)' +task (\(session.completed.count) done)")
    }

    /// Advances the curriculum pointer (when lessons are driven from a curriculum).
    func setLessonIndex(_ index: Int) {
        guard var session = active else { return }
        session.lessonIndex = index
        active = session
        upsertStored(session)
    }

    // MARK: - The context that rides with /plan

    /// Compact summary for the planner. Prefers the named learning session; else
    /// falls back to the ambient recent-tasks trail so voice follow-ups always
    /// have memory of what was just done ("this photo" = the Photo Booth photo).
    func contextForPlan() -> String {
        if let s = active {
            var lines = ["Skill being learned: \(s.skill)"]
            if s.completed.isEmpty {
                lines.append("Nothing completed yet — this is the first task of the session.")
            } else {
                let recent = s.completed.suffix(6)
                lines.append("Recently completed, in order:")
                for (i, t) in recent.enumerated() { lines.append("\(i + 1). \(t)") }
            }
            return lines.joined(separator: "\n")
        }

        // No named session → ambient trail (only tasks finished "just now").
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        let fresh = recentTasks.filter { $0.at >= cutoff }
        guard !fresh.isEmpty else { return "" }
        var lines = ["The user just completed these tasks, most recent last (a follow-up like \"this photo\" / \"it\" refers to the result of the most recent one):"]
        for (i, t) in fresh.enumerated() { lines.append("\(i + 1). \(t.task)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func upsertStored(_ session: Session) {
        stored.removeAll { $0.id == session.id }
        stored.insert(session, at: 0)
        if stored.count > Self.maxStored { stored.removeLast(stored.count - Self.maxStored) }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL)
        }
    }

    private func persistRecent() {
        if let data = try? JSONEncoder().encode(recentTasks) {
            try? data.write(to: recentURL)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let sessions = try? JSONDecoder().decode([Session].self, from: data) {
            stored = sessions
            DebugLogger.log("SESSION", "loaded \(sessions.count) stored skill session(s)")
        }
        if let data = try? Data(contentsOf: recentURL),
           let recents = try? JSONDecoder().decode([RecentTask].self, from: data) {
            recentTasks = recents
        }
    }
}
