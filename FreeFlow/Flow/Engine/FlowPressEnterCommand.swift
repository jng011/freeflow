import Foundation

/// The opt-in "press enter" voice command: ending a dictation with "press enter" pastes
/// the rest and then presses Return.
enum FlowPressEnterCommand {
    struct Outcome {
        /// Text to paste with the command removed. May be empty.
        let text: String
        let sendEnter: Bool

        /// Only punctuation (or nothing) is left, so nothing should be pasted.
        var hasNothingToPaste: Bool {
            text.trimmingCharacters(in: Self.punctuationAndSpace).isEmpty
        }

        private static let punctuationAndSpace = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    }

    private static let pattern = #"([.!?;])?\s*\bpress enter\s*([.!?,;:-]*)\s*$"#
    private static let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: FlowKeys.pressEnterCommand)
    }

    /// Checks the final (and raw) text for the trailing command. Returns nil when the
    /// command was not spoken or is turned off. The first time it is heard while off,
    /// offers to turn it on instead.
    @MainActor
    static func evaluate(finalText: String, asrText: String) -> Outcome? {
        let stripped = strip(finalText)
        let spoken = stripped != nil || matches(asrText)
        guard spoken else { return nil }

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: FlowKeys.pressEnterCommand) {
            return Outcome(text: stripped ?? finalText, sendEnter: true)
        }

        if !defaults.bool(forKey: FlowKeys.pressEnterPromptShown) {
            defaults.set(true, forKey: FlowKeys.pressEnterPromptShown)
            var toast = FlowBarToast(style: .condensed, title: "Say 'press enter' to send. Turn it on?")
            toast.actionTitle = "Turn on"
            toast.action = {
                UserDefaults.standard.set(true, forKey: FlowKeys.pressEnterCommand)
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            }
            toast.duration = 6
            FlowBarController.shared.showToast(toast)
        }
        return nil
    }

    static func matches(_ text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Removes the trailing "press enter", keeping a sentence terminator that came before it.
    static func strip(_ text: String) -> String? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
            let matchRange = Range(match.range, in: text)
        else { return nil }

        var result = String(text[..<matchRange.lowerBound])
        if match.range(at: 1).location != NSNotFound, let terminatorRange = Range(match.range(at: 1), in: text) {
            result += text[terminatorRange]
        }
        // "Hello, press enter" leaves "Hello," behind: drop the dangling separator.
        while let last = result.last, last.isWhitespace || ",:-".contains(last) {
            result.removeLast()
        }
        return result
    }
}
