import Foundation

/// Settings facade for Flow sounds. The on/off state maps onto the existing
/// start/stop sound selections so older settings and custom sounds keep working.
@MainActor
enum FlowSoundSettings {
    /// True when either the start or the stop selection is not `.none`.
    /// Setting true turns `.none` selections back to built-in (custom ones are kept);
    /// setting false silences both. Posts CustomSoundsChanged.
    static var isEnabled: Bool {
        get { CustomSoundManager.shared.hasAnyRecordingSoundEnabled }
        set { CustomSoundManager.shared.setRecordingSoundsEnabled(newValue) }
    }

    /// The selected sound pack (FlowKeys.soundPack).
    static var pack: FlowSoundPack {
        get {
            UserDefaults.standard.string(forKey: FlowKeys.soundPack).flatMap(FlowSoundPack.init(rawValue:))
                ?? .default
        }
        set {
            guard newValue != pack else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: FlowKeys.soundPack)
            NotificationCenter.default.post(name: .flowSoundPackChanged, object: nil)
        }
    }

    /// True while something (the onboarding mic test) has asked for silence.
    static var isSuspended: Bool { suspendCount > 0 }

    private static var suspendCount = 0

    /// Mutes every sound while `body` runs, and for 100 ms after it ends.
    static func withSoundsSuspended(_ body: () async -> Void) async {
        suspendCount += 1
        await body()
        try? await Task.sleep(nanoseconds: 100_000_000)
        suspendCount = max(0, suspendCount - 1)
    }
}
