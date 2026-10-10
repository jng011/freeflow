import Foundation

/// Backtrack: a spoken "scratch that" or "never mind" throws away what was said right
/// before it, and dictation carries on from there.
///
/// Works like a classic "scratch that" voice command: the command has to stand on its own, set off by
/// Whisper's punctuation (which follows the speaker's pauses), so "never mind the cost"
/// or "forget that file" stay as content. It removes the sentence in progress, or the
/// previous sentence when the command starts a new one. Softer corrections ("actually",
/// "I mean", "six, no, seven") need judgment and are left to AI cleanup, which runs first;
/// this pass guarantees an explicit command never ends up pasted.
enum FlowBacktrack {
    /// Explicit cancel commands, longest first so "never mind that" wins over "never mind".
    private static let commands = [
        "scratch all of that", "forget all of that", "scratch all that", "forget all that",
        "never mind that", "scratch that", "scrap that", "strike that", "forget that", "cancel that",
        "never mind", "nevermind",
    ]

    /// Words that may surround a command inside its own phrase ("oh wait, never mind").
    private static let fillers: Set<String> = [
        "oh", "uh", "um", "umm", "ah", "hmm", "wait", "no", "nope", "sorry", "okay", "ok", "so", "actually",
    ]

    /// Characters that end a phrase when followed by a space or the end of the text.
    private static let phraseEnders: Set<Character> = [".", ",", "!", "?", ";", ":", "…", "\n"]
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "\n"]

    private struct Phrase {
        /// Words and inner punctuation, without the closing delimiter.
        var body: String
        /// Closing punctuation and the whitespace after it (may be empty at the end).
        var tail: String

        var endsSentence: Bool { tail.contains { FlowBacktrack.sentenceEnders.contains($0) } }
    }

    /// True when the text holds a stand-alone cancel command.
    static func containsCommand(_ text: String) -> Bool {
        phrases(of: separatingRepeatedCommands(in: text)).contains { isCommand($0.body) }
    }

    /// "…is blah never mind never mind hello…" with no punctuation: saying it twice is a
    /// clear enough signal, so set the pair off as its own phrase.
    private static let repeatedCommand: NSRegularExpression? = {
        let one = "(?:scratch that|scrap that|strike that|forget that|cancel that|never ?mind)"
        return try? NSRegularExpression(
            pattern: "[\\s,]*\\b(\(one)(?:[\\s,.!]+\(one))+)\\b[,.!]?\\s*",
            options: [.caseInsensitive]
        )
    }()

    private static func separatingRepeatedCommands(in text: String) -> String {
        guard let repeatedCommand else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return repeatedCommand.stringByReplacingMatches(in: text, range: range, withTemplate: ", $1, ")
    }

    /// The text with every stand-alone cancel command applied. A command with nothing
    /// before it is ordinary speech ("Never mind." as a reply) and is kept.
    static func apply(to text: String) -> String {
        let input = phrases(of: separatingRepeatedCommands(in: text))
        guard input.contains(where: { isCommand($0.body) }) else { return text }

        var output: [Phrase] = []
        var previousWasCommand = false
        var didBacktrack = false

        for (position, phrase) in input.enumerated() {
            if isCommand(phrase.body) {
                // "never mind, never mind" is one command said twice, not two.
                if previousWasCommand { continue }
                previousWasCommand = true
                // Only filler before it ("Oh wait, never mind.") still counts as a command when
                // more follows ("... Let's do Friday."); said on its own it's a reply, kept as words.
                let hasContent = output.contains { !isBlank($0.body) && !isFillerOnly($0.body) }
                let fillerThenMore = output.contains { !isBlank($0.body) }
                    && input[(position + 1)...].contains { !isBlank($0.body) && !isCommand($0.body) }
                guard hasContent || fillerThenMore else {
                    // Nothing to take back: it was meant as words.
                    output.append(phrase)
                    previousWasCommand = false
                    continue
                }
                // "Wait, scratch that": a lead-in that is only filler belongs to the command.
                while let last = output.last, !last.endsSentence, isFillerOnly(last.body) {
                    output.removeLast()
                }
                removeLastSentence(from: &output)
                didBacktrack = true
                continue
            }
            previousWasCommand = false
            if isBlank(phrase.body) { continue }
            output.append(phrase)
        }

        guard didBacktrack else { return text }
        return assemble(output)
    }

    /// Live cleanup splits a dictation: the start is cleaned while the person talks, the rest
    /// on release. When the rest opens with a cancel command ("Wait, scrap that. ..."), the
    /// thing it takes back sits in the already-cleaned start, out of the AI's reach. This moves
    /// the start's last sentence back in front of the rest, so the final cleanup sees the
    /// command with what it refers to and decides how much to drop ("It costs $12.99, and the
    /// server is $199. Wait, scrap that." keeps the price). Nil when the rest doesn't open
    /// with a command.
    static func applyAcrossBoundary(cleanedStart: String, rawRest: String) -> (start: String, rest: String)? {
        let rest = phrases(of: separatingRepeatedCommands(in: rawRest))
        var index = 0
        while index < rest.count, !rest[index].endsSentence, isFillerOnly(rest[index].body) { index += 1 }
        guard index < rest.count, isCommand(rest[index].body) else { return nil }

        var start = phrases(of: cleanedStart)
        guard start.contains(where: { !isBlank($0.body) }) else { return nil }
        let kept = start.count
        removeLastSentence(from: &start)
        let moved = Array(phrases(of: cleanedStart)[start.count..<kept])
        let movedText = moved.map { $0.body.trimmingCharacters(in: .whitespaces) + $0.tail }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let startText = start.isEmpty ? "" : assemble(start)
        return (startText, movedText + " " + rawRest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Steps

    /// Drops the sentence in progress, or the whole previous sentence when the command
    /// started a fresh one ("I'll be there at 5. Scratch that. At 6.").
    private static func removeLastSentence(from output: inout [Phrase]) {
        if let last = output.last, last.endsSentence {
            output.removeLast()
        }
        while let last = output.last, !last.endsSentence {
            output.removeLast()
        }
    }

    private static func assemble(_ phrases: [Phrase]) -> String {
        var result = ""
        for phrase in phrases {
            var body = phrase.body.trimmingCharacters(in: .whitespaces)
            let startsSentence = result.isEmpty
                || result.trimmingCharacters(in: .whitespaces).last.map { sentenceEnders.contains($0) } == true
            if startsSentence { body = capitalizingFirstLetter(body) }
            if !result.isEmpty, !result.hasSuffix(" "), !result.hasSuffix("\n") { result += " " }
            result += body + phrase.tail
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // A cut can leave "…at home," at the very end.
        while let last = result.last, ",;:".contains(last) {
            result.removeLast()
            if !result.isEmpty { result += "." }
        }
        return result
    }

    // MARK: - Parsing

    private static func phrases(of text: String) -> [Phrase] {
        var result: [Phrase] = []
        var body = ""
        var tail = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if phraseEnders.contains(character), endsPhrase(at: index, in: characters) {
                tail = String(character)
                index += 1
                // Gather a run of punctuation ("?!", "...") and the whitespace after it.
                while index < characters.count,
                    phraseEnders.contains(characters[index]) || characters[index].isWhitespace
                {
                    tail.append(characters[index])
                    index += 1
                }
                result.append(Phrase(body: body, tail: tail))
                body = ""
                tail = ""
                continue
            }
            body.append(character)
            index += 1
        }
        if !body.isEmpty { result.append(Phrase(body: body, tail: "")) }
        return result
    }

    /// "3.5", "1,000", "10:30" and "example.com" don't end a phrase: a delimiter only
    /// counts before whitespace, more punctuation, or the end of the text.
    private static func endsPhrase(at index: Int, in characters: [Character]) -> Bool {
        if characters[index] == "\n" { return true }
        let next = index + 1
        guard next < characters.count else { return true }
        let following = characters[next]
        return following.isWhitespace || phraseEnders.contains(following) || "\"'”’)".contains(following)
    }

    private static func words(of body: String) -> [String] {
        body.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    /// The phrase is only cancel commands, optionally with fillers ("oh wait, never mind").
    private static func isCommand(_ body: String) -> Bool {
        var remaining = words(of: body).filter { !fillers.contains($0) }.joined(separator: " ")
        guard !remaining.isEmpty else { return false }
        var matched = false
        while !remaining.isEmpty {
            guard let command = commands.first(where: { remaining == $0 || remaining.hasPrefix($0 + " ") }) else {
                return false
            }
            matched = true
            remaining = String(remaining.dropFirst(command.count)).trimmingCharacters(in: .whitespaces)
        }
        return matched
    }

    private static func isFillerOnly(_ body: String) -> Bool {
        let bodyWords = words(of: body)
        return !bodyWords.isEmpty && bodyWords.allSatisfy { fillers.contains($0) }
    }

    private static func isBlank(_ body: String) -> Bool {
        words(of: body).isEmpty
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        return text.replacingCharacters(in: index...index, with: String(text[index]).uppercased())
    }
}
