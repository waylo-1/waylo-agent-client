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

    private let fileURL: URL
    private static let maxStored = 8
    private static let maxCompletedRemembered = 12

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sahayak", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("skill_sessions.json")
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

    /// Records a completed guide into the active session.
    func recordCompleted(task: String) {
        guard var session = active, !task.isEmpty else { return }
        session.completed.append(task)
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

    /// Compact summary for the planner; empty when no session is running.
    func contextForPlan() -> String {
        guard let s = active else { return "" }
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

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let sessions = try? JSONDecoder().decode([Session].self, from: data) else { return }
        stored = sessions
        DebugLogger.log("SESSION", "loaded \(sessions.count) stored skill session(s)")
    }
}
