import AppKit
import Foundation

/// The opt-in "ask Siri" voice command: a dictation that starts with "ask Siri" opens
/// Spotlight (Cmd+Space), types the rest there, and presses Return, so Spotlight's
/// Siri/AI answers it instead of the text landing in the current app.
enum FlowAskSiriCommand {
    static let enabledKey = "FlowAskSiriCommand"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// "Ask Siri, what's the weather?" / "Hey, ask Siri what's the weather" -> "What's the weather?"
    private static let regex = try? NSRegularExpression(
        // Whisper sometimes hears "ask Siri" as "asked Siri" (seen on the voice-clone test).
        pattern: #"^\s*(?:(?:hey|okay|ok|um|uh)[\s,.!]*)?ask(?:ed|s)?\s+siri\b[\s,.:;!?-]*"#,
        options: [.caseInsensitive]
    )

    /// The question with the command removed, or nil when the dictation doesn't start with it.
    static func question(in text: String) -> String? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
            let matchRange = Range(match.range, in: text)
        else { return nil }
        var rest = String(text[matchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        if let first = rest.first, first.isLowercase {
            rest = first.uppercased() + rest.dropFirst()
        }
        return rest
    }

    /// Cmd+Space, wait for Spotlight, paste, Return.
    @MainActor
    static func send(_ question: String) async -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let space: CGKeyCode = 49
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: space, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: space, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        FlowBarController.shared.showToast(FlowBarToast(style: .mini, title: "Asking Siri", icon: .siri, duration: 2.5))
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // Spotlight's field takes a moment to appear and take focus.
        try? await Task.sleep(nanoseconds: 350_000_000)
        let outcome = await CursorPaster.startPasteAtCursor(question, keepOnClipboard: false).value
        guard outcome.result.didPostPasteCommand else { return false }
        try? await Task.sleep(nanoseconds: 200_000_000)
        CursorPaster.performSendKey(.enter)
        return true
    }
}
