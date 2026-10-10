import Foundation

/// Counts the settings that need the person's attention: a broken or missing
/// dictation shortcut (General) and the server being offline (the server).
enum FlowSettingsAttention {
    /// The app's shortcut manager. The Settings modal registers it when it appears;
    /// shell may also set it at launch so the sidebar badge works before Settings opens.
    @MainActor static weak var shortcutManager: RecordingShortcutManager?

    @MainActor static var count: Int {
        (generalNeedsAttention ? 1 : 0) + (pcNeedsAttention ? 1 : 0)
    }

    @MainActor static var generalNeedsAttention: Bool {
        if let manager = shortcutManager {
            return !manager.isShortcutConfigured
        }
        return ShortcutStore.shortcut(for: .primaryRecording) == nil
    }

    @MainActor static var pcNeedsAttention: Bool {
        let engine = ParleEngine.shared
        return engine.isUsingPC && engine.pcStatus == .offline
    }
}
