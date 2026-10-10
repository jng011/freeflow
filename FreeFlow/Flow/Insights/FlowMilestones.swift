import Foundation

/// Local word and day-streak milestones, celebrated with a Flow Bar toast.
@MainActor
enum FlowMilestones {
    static let wordKeys: [Int] = [314, 777, 1337, 2000, 5555, 7777, 10000, 12345, 20000, 50000, 99000, 100000,
                                  123456, 500000, 1000000, 1500000]
    static let streakKeys: [Int] = [7, 14, 30, 60, 100, 365]
    static let seenDefaultsKey = "FlowMilestonesSeen"

    private static var lastFiredAt: Date?
    private static var pendingTask: Task<Void, Never>?

    enum Milestone: Equatable {
        case words(Int)
        case streak(Int)

        var wordValue: Int? { if case .words(let n) = self { return n }; return nil }
        var streakValue: Int? { if case .streak(let n) = self { return n }; return nil }

        var key: String {
            switch self {
            case .words(let n): return "words:\(n)"
            case .streak(let n): return "streak:\(n)"
            }
        }
    }

    private static var seen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: seenDefaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: seenDefaultsKey) }
    }

    private static var notificationsEnabled: Bool {
        (UserDefaults.standard.object(forKey: FlowKeys.notifyMilestones) as? Bool) ?? true
    }

    static func crossed(in summary: FlowStatsSummary) -> [Milestone] {
        wordKeys.filter { $0 <= summary.totalWords }.map(Milestone.words)
            + streakKeys.filter { $0 <= summary.dayStreak }.map(Milestone.streak)
    }

    /// Marks every milestone already passed as seen without celebrating (used after the backfill).
    static func markPassedAsSeen(_ summary: FlowStatsSummary) {
        var current = seen
        crossed(in: summary).forEach { current.insert($0.key) }
        seen = current
    }

    /// Called after each recorded dictation once the summary has been recomputed.
    static func check(_ summary: FlowStatsSummary) {
        guard !summary.isLoading else { return }
        let current = seen
        let fresh = crossed(in: summary).filter { !current.contains($0.key) }
        guard !fresh.isEmpty else { return }

        guard notificationsEnabled else {
            markPassedAsSeen(summary)
            return
        }
        // At most one celebration per 60 s; anything newer waits for a later dictation.
        if pendingTask != nil { return }
        if let lastFiredAt, Date().timeIntervalSince(lastFiredAt) < 60 { return }

        // Celebrate the biggest new word milestone first, otherwise the biggest streak.
        let words = fresh.compactMap(\.wordValue).max()
        let streak = fresh.compactMap(\.streakValue).max()
        let milestone: Milestone
        let toMark: [Milestone]
        if let words {
            milestone = .words(words)
            toMark = fresh.filter { $0.wordValue != nil }
        } else if let streak {
            milestone = .streak(streak)
            toMark = fresh.filter { $0.streakValue != nil }
        } else {
            return
        }
        var updated = current
        toMark.forEach { updated.insert($0.key) }
        seen = updated
        lastFiredAt = Date()

        pendingTask = Task { @MainActor in
            defer { pendingTask = nil }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            // Wait while a dictation is in progress (up to about 25 minutes).
            var waited = 0
            while FlowDictationState.shared.phase != .idle && waited < 1500 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                waited += 1
            }
            guard !Task.isCancelled, notificationsEnabled else { return }
            lastFiredAt = Date()
            celebrate(milestone)
        }
    }

    private static func celebrate(_ milestone: Milestone) {
        let title: String
        let body: String
        switch milestone {
        case .words(let n):
            title = "You've dictated \(format(n)) words"
            body = wordLines[abs(n) % wordLines.count]
        case .streak(let n):
            title = "\(format(n)) day streak"
            body = "You've used Free Flow \(n) days in a row. Keep it going."
        }
        FlowBarController.shared.showToast(FlowBarToast(
            style: .standard,
            badge: "Milestone",
            title: title,
            body: body,
            actionTitle: "See stats",
            action: { FlowNavigator.shared.open(.insights) },
            duration: 8
        ))
        SoundManager.shared.playAchievementSound()
    }

    private static let wordLines = [
        "That is a lot of typing you skipped.",
        "Your keyboard is getting a well earned rest.",
        "Your voice is doing the heavy lifting.",
        "Every word spoken is a word not typed.",
    ]

    private static func format(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}
