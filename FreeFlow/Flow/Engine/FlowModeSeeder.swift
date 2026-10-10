import CoreGraphics
import Foundation

/// The engine refuses to record without a mode. Parle's old onboarding created one;
/// Flow's onboarding does not, so a fresh install gets the same default Dictation mode here.
enum FlowModeSeeder {
    static func ensureDefaultMode() {
        guard ModeManager.shared.configurations.isEmpty else { return }
        StarterModeFactory.install(
            kinds: [.clean],
            provider: .openRouter,
            modelName: "google/gemini-3.5-flash-lite",
            transcriptionModelName: "apple-speech",
            isRealtimeTranscriptionEnabled: true,
            selectedLanguage: "en"
        )
    }

    /// Gemini 3.5 Flash was the old OpenRouter default and takes 1.5 to 3.5 s per cleanup.
    /// Move it to Flash-Lite once (about twice as fast); a later pick in Settings sticks.
    static func migrateSlowCleanupModel() {
        let key = "FlowCleanupModelMovedToFlashLite"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        let slow = "google/gemini-3.5-flash"
        let fast = "google/gemini-3.5-flash-lite"
        for key in ["OpenRouterSelectedModel", "OpenRouterCustomModelID"] where defaults.string(forKey: key) == slow {
            defaults.set(fast, forKey: key)
        }
        for var config in ModeManager.shared.configurations where config.selectedAIModel == slow {
            config.selectedAIModel = fast
            ModeManager.shared.updateConfiguration(config)
        }
    }
}


/// Context awareness reads names on screen with on-device OCR, which needs Screen Recording.
/// macOS only shows its permission prompt when asked, so ask once while the setting is on.
enum FlowScreenContextPermission {
    private static let askedKey = "FlowScreenRecordingAsked"

    static func requestIfNeeded() {
        guard UserDefaults.standard.bool(forKey: FlowKeys.contextAwareness),
            !CGPreflightScreenCaptureAccess(),
            !UserDefaults.standard.bool(forKey: askedKey)
        else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        CGRequestScreenCaptureAccess()
    }
}
