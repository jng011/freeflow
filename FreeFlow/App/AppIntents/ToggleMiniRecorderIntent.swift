import AppIntents
import AppKit
import Foundation

struct ToggleMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Free Flow dictation"
    static var description = IntentDescription("Start or stop Free Flow dictation.")

    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .toggleRecorderPanel, object: nil)

        let dialog: IntentDialog = "Free Flow dictation toggled"
        return .result(dialog: dialog)
    }
}

enum IntentError: Error, LocalizedError {
    case appNotAvailable
    case serviceNotAvailable

    var errorDescription: String? {
        switch self {
        case .appNotAvailable:
            return String(localized: "Free Flow is not available")
        case .serviceNotAvailable:
            return String(localized: "Free Flow dictation is not available")
        }
    }
}
