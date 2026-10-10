import Foundation

/// Flow's cleanup preferences (level, per-app style, custom rules) turned into extra
/// instructions for the default cleanup prompt, plus the deterministic final-period rule.
enum FlowCleanupPolicy {
    private static let levels: Set<String> = ["none", "light", "medium", "high"]
    private static let maxTerms = 40

    /// none|light|medium|high
    static var level: String {
        let stored = UserDefaults.standard.string(forKey: FlowKeys.autoCleanupLevel) ?? "light"
        return levels.contains(stored) ? stored : "light"
    }

    /// False when the person picked "None": no cleanup and no live cleanup.
    static var isCleanupEnabled: Bool {
        level != "none"
    }

    /// Level + style + custom rules + language + dictionary lines, appended to the default
    /// cleanup prompt only. Empty when there is nothing to add.
    @MainActor
    static func systemAddendum(bundleID: String?, appName: String?, url: String?) -> String {
        var lines: [String] = []

        let lightLine =
            "Remove filler words (um, uh, you know, filler 'like'), false starts and accidental repetitions, and fix grammar, punctuation and capitalization. Otherwise keep the speaker's exact wording."
        switch level {
        case "medium":
            lines.append(lightLine)
            lines.append(
                "Also tighten the wording for clarity and remove redundancy, without dropping any facts, names, numbers or requests."
            )
        case "high":
            lines.append(lightLine)
            lines.append(
                "Rewrite for brevity and polish while keeping every fact, name, number and request. Prefer short, clear sentences."
            )
        case "none":
            break
        default:
            lines.append(lightLine)
        }

        let category = FlowAppCategory.classify(bundleID: bundleID, appName: appName, url: url)
        if !FlowAppCategory.isTerminal(bundleID: bundleID), let styleCategory = category.styleCategory {
            lines.append("If the text is in English: " + styleLine(for: FlowDefaults.stylePreset(for: styleCategory)))
        }
        if category == .email {
            lines.append(
                "If the dictation begins with a greeting, format it as an email: greeting line, blank line, body paragraphs, blank line, sign-off on its own line."
            )
        }

        lines.append("Never translate. Output in the language spoken, keeping mixed-language words as spoken.")

        let store = FlowDictionaryStore.shared
        let terms = Array(store.vocabularyPromptWords.prefix(maxTerms))
        if !terms.isEmpty {
            lines.append("Spell these terms exactly as written: \(terms.joined(separator: ", ")).")
        }

        let protectedPhrases = replacementOriginals(from: store.entries)
        if !protectedPhrases.isEmpty {
            lines.append("Never rephrase these phrases, keep them verbatim: \(protectedPhrases.joined(separator: ", ")).")
        }

        let customRules = (UserDefaults.standard.string(forKey: FlowKeys.cleanupCustomRules) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !customRules.isEmpty {
            lines.append("Additional rules from the user: \(customRules)")
        }

        guard !lines.isEmpty else { return "" }
        return "# Free Flow preferences\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func styleLine(for preset: FlowStylePreset) -> String {
        switch preset {
        case .formal:
            return
                "Use standard capitalization and complete punctuation, including a closing period. Do not add exclamation marks the speaker did not imply."
        case .casual:
            return
                "Capitalize normally but keep punctuation light: omit optional commas and omit the final period unless the message has several sentences. Keep question marks."
        case .veryCasual:
            return
                "Write everything in lowercase, including 'i' and sentence starts. Use minimal punctuation and no final period. Keep question marks."
        case .excited:
            return
                "Use standard capitalization and punctuation, and end greetings or upbeat statements with an exclamation mark (at most two per message). Never add words."
        }
    }

    private static func replacementOriginals(from entries: [FlowDictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries where entry.replacement != nil {
            for variant in entry.phrase.split(separator: ",") {
                let phrase = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty, seen.insert(phrase.lowercased()).inserted else { continue }
                result.append(phrase)
                if result.count >= maxTerms { return result }
            }
        }
        return result
    }

    // MARK: - Final period

    /// Deterministic final-period rule for personal and work apps, applied after cleanup.
    static func applyFinalPeriodRule(
        to text: String,
        bundleID: String?,
        appName: String?,
        url: String?,
        replacingSelection: Bool,
        caretBefore: String?
    ) -> String {
        guard !replacingSelection else { return text }
        if let caretBefore, caretBefore.contains(where: { ".!?".contains($0) }) {
            return text
        }
        let category = FlowAppCategory.classify(bundleID: bundleID, appName: appName, url: url)
        guard let styleCategory = category.styleCategory,
            styleCategory == .personal || styleCategory == .work
        else { return text }

        var trimmed = text
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("..") else { return text }

        switch FlowDefaults.stylePreset(for: styleCategory) {
        case .casual:
            guard sentenceCount(trimmed) <= 10 else { return text }
            trimmed.removeLast()
            return trimmed
        case .veryCasual:
            trimmed.removeLast()
            return trimmed
        case .formal, .excited:
            return text
        }
    }

    private static func sentenceCount(_ text: String) -> Int {
        var count = 0
        var previousWasTerminator = false
        for character in text {
            let isTerminator = ".!?".contains(character)
            if isTerminator && !previousWasTerminator { count += 1 }
            previousWasTerminator = isTerminator
        }
        return max(count, 1)
    }
}
