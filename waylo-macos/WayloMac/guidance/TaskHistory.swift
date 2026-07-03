import Foundation

/// Recent completed guides shown in the panel, each with a ✓ / ✗ control.
///   ✓ → cache this plan as correct (so the task is right next time).
///   ✗ → forget it (the wrong path is removed so it isn't reused).
@MainActor
final class TaskHistory: ObservableObject {
    static let shared = TaskHistory()

    enum Feedback { case none, correct, wrong }

    struct Entry: Identifiable {
        let id = UUID()
        let task: String
        let steps: [Step]
        let date: Date
        var feedback: Feedback = .none
    }

    @Published private(set) var entries: [Entry] = []
    private let maxEntries = 8

    private init() {}

    /// Records a finished guide at the top of the list.
    func record(task: String, steps: [Step]) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !steps.isEmpty else { return }
        entries.insert(Entry(task: trimmed, steps: steps, date: Date()), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
    }

    /// 👍 — remember this plan as the correct one for the task.
    func markCorrect(_ entry: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].feedback = .correct
        WayloAPIClient.shared.learnPlan(task: entry.task, steps: entry.steps)
        DebugLogger.log("HISTORY", "marked CORRECT → learning plan for '\(entry.task)'")
    }

    /// 👎 — forget this plan so the wrong path isn't reused next time.
    func markWrong(_ entry: Entry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i].feedback = .wrong
        WayloAPIClient.shared.forgetPlan(task: entry.task)
        DebugLogger.log("HISTORY", "marked WRONG → forgetting plan for '\(entry.task)'")
    }
}
