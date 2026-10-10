import AppIntents
import Foundation

struct AppShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMiniRecorderIntent(),
            phrases: [
                "Toggle \(.applicationName) dictation",
                "Start \(.applicationName) dictation",
                "Stop \(.applicationName) dictation",
                "Toggle dictation in \(.applicationName)",
                "Start dictating in \(.applicationName)",
                "Stop dictating in \(.applicationName)",
            ],
            shortTitle: "Toggle Dictation",
            systemImageName: "mic.circle"
        )

        AppShortcut(
            intent: DismissMiniRecorderIntent(),
            phrases: [
                "Dismiss \(.applicationName) dictation",
                "Cancel \(.applicationName) dictation",
                "Cancel dictation in \(.applicationName)",
            ],
            shortTitle: "Dismiss Dictation",
            systemImageName: "xmark.circle"
        )
    }
}
