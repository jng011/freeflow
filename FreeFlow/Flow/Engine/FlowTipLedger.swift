import Foundation

/// Rate limits for one-off tips and nudges: each tip has a lifetime cap, a
/// minimum gap between showings, and an optional permanent "don't show again". Stored in
/// UserDefaults under `FlowTipLedger.<id>.*`.
///
///     guard FlowTipLedger.isEligible(.airPods) else { return }
///     FlowTipLedger.markShown(.airPods)
///     ... toast.action = { FlowTipLedger.markDismissed(.airPods) }
enum FlowTipLedger {
    struct Tip: Hashable, Sendable {
        let id: String
        /// nil = no lifetime cap.
        let maxShows: Int?
        /// Minimum seconds between two showings.
        let minInterval: TimeInterval
    }

    private static let defaults = UserDefaults.standard

    /// The "Suggestions" setting (Settings > Notifications). Tips respect it; warnings don't.
    static var suggestionsEnabled: Bool {
        defaults.object(forKey: FlowKeys.notifySuggestions) as? Bool ?? true
    }

    static func isEligible(_ tip: Tip, respectingSuggestions: Bool = true, now: Date = Date()) -> Bool {
        if respectingSuggestions && !suggestionsEnabled { return false }
        if defaults.bool(forKey: key(tip, "dismissed")) { return false }
        if let maxShows = tip.maxShows, defaults.integer(forKey: key(tip, "count")) >= maxShows { return false }
        let last = defaults.double(forKey: key(tip, "last"))
        if last > 0, now.timeIntervalSince1970 - last < tip.minInterval { return false }
        return true
    }

    static func markShown(_ tip: Tip, now: Date = Date()) {
        defaults.set(defaults.integer(forKey: key(tip, "count")) + 1, forKey: key(tip, "count"))
        defaults.set(now.timeIntervalSince1970, forKey: key(tip, "last"))
    }

    /// Permanent: the tip never shows again.
    static func markDismissed(_ tip: Tip) {
        defaults.set(true, forKey: key(tip, "dismissed"))
    }

    static func shownCount(_ tip: Tip) -> Int {
        defaults.integer(forKey: key(tip, "count"))
    }

    private static func key(_ tip: Tip, _ field: String) -> String {
        "FlowTipLedger.\(tip.id).\(field)"
    }
}

extension FlowTipLedger.Tip {
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400

    /// Dictation started on AirPods (or another Bluetooth mic).
    static let airPods = FlowTipLedger.Tip(id: "airPodsTip", maxShows: nil, minInterval: hour)

    /// "It worked" confirmations for smart formatting, the first few times each kicks in.
    static let confirmBacktrack = FlowTipLedger.Tip(id: "confirmBacktrack", maxShows: 3, minInterval: 0)
    static let confirmListed = FlowTipLedger.Tip(id: "confirmListed", maxShows: 3, minInterval: 0)
    static let confirmEmail = FlowTipLedger.Tip(id: "confirmEmail", maxShows: 3, minInterval: 0)
}
