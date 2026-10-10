import Foundation
import SwiftData
import os

@MainActor
final class WordReplacementService {
    static let shared = WordReplacementService()

    private struct RuleRecord: Equatable {
        let id: UUID
        let originalText: String
        let replacementText: String
        let dateAdded: Date
    }

    private struct PreparedRule {
        let original: String
        let replacement: String
        let regex: NSRegularExpression?
    }

    private let logger = Logger(
        subsystem: "com.jaydenghiyam.parle",
        category: "WordReplacementService"
    )
    private var cachedRecords: [RuleRecord]?
    private var cachedRules: [PreparedRule] = []

    private init() {}

    func applyReplacements(to text: String, using context: ModelContext) -> String {
        replace(in: text, using: context).text
    }

    /// Shared implementation of `applyReplacements` and `applyReplacementsCounted`.
    /// `count` is the total number of substitutions across all rules.
    fileprivate func replace(in text: String, using context: ModelContext) -> (text: String, count: Int) {
        // `isEnabled` is retained only for store and CloudKit compatibility.
        // Replacement rules are intentionally always active.
        let descriptor = FetchDescriptor<WordReplacement>()

        let replacements: [WordReplacement]
        do {
            replacements = try context.fetch(descriptor)
        } catch {
            logger.error("Could not load word replacements: \(error, privacy: .public)")
            return (text, 0)
        }

        guard !replacements.isEmpty else {
            logger.debug("Word replacement skipped: no enabled rules")
            return (text, 0)
        }

        logger.debug(
            "Starting word replacement with \(replacements.count, privacy: .public) enabled rule(s)"
        )

        let rules = preparedRules(from: replacements)

        logger.debug(
            "Prepared \(rules.count, privacy: .public) replacement variant(s)"
        )

        // Whole-utterance rule: "Btw." on its own becomes "by the way" without
        // the trailing punctuation.
        let strippedText = FlowDictionaryText.stripped(text)
        if !strippedText.isEmpty,
            let rule = rules.first(where: { FlowDictionaryText.stripped($0.original) == strippedText })
        {
            logger.debug("Applying whole-utterance word replacement")
            return (rule.replacement, 1)
        }

        var modifiedText = text
        var matchedRuleCount = 0
        var totalMatches = 0
        for rule in rules {
            let original = rule.original
            let replacementText = rule.replacement

            if let regex = rule.regex {
                let range = NSRange(modifiedText.startIndex..., in: modifiedText)
                let matchCount = regex.numberOfMatches(in: modifiedText, options: [], range: range)
                guard matchCount > 0 else { continue }

                logger.debug(
                    "Applying boundary-aware word replacement \(original, privacy: .private) -> \(replacementText, privacy: .private), matches=\(matchCount, privacy: .public)"
                )
                modifiedText = regex.stringByReplacingMatches(
                    in: modifiedText,
                    options: [],
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacementText)
                )
                matchedRuleCount += 1
                totalMatches += matchCount
            } else {
                let occurrences = Self.occurrenceCount(of: original, in: modifiedText)
                guard occurrences > 0 else { continue }
                let replacedText = modifiedText.replacingOccurrences(
                    of: original, with: replacementText, options: .caseInsensitive)
                guard replacedText != modifiedText else { continue }

                logger.debug(
                    "Applying substring word replacement \(original, privacy: .private) -> \(replacementText, privacy: .private)"
                )
                modifiedText = replacedText
                matchedRuleCount += 1
                totalMatches += occurrences
            }
        }

        logger.debug(
            "Finished word replacement: \(matchedRuleCount, privacy: .public) rule(s) matched, \(totalMatches, privacy: .public) substitution(s); output changed=\(modifiedText != text, privacy: .public)"
        )

        return (modifiedText, totalMatches)
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: .caseInsensitive, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    private func preparedRules(from replacements: [WordReplacement]) -> [PreparedRule] {
        let records = replacements
            .map {
                RuleRecord(
                    id: $0.id,
                    originalText: $0.originalText,
                    replacementText: $0.replacementText,
                    dateAdded: $0.dateAdded
                )
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        if cachedRecords == records {
            return cachedRules
        }

        let sortedRules = records
            .flatMap { record in
                WordReplacementVariants.parse(record.originalText).map {
                    (
                        original: $0,
                        replacement: record.replacementText,
                        dateAdded: record.dateAdded,
                        id: record.id.uuidString
                    )
                }
            }
            .sorted {
                if $0.original.count != $1.original.count {
                    return $0.original.count > $1.original.count
                }
                let leftKey = WordReplacementVariants.key(for: $0.original)
                let rightKey = WordReplacementVariants.key(for: $1.original)
                if leftKey != rightKey {
                    return leftKey < rightKey
                }
                if $0.dateAdded != $1.dateAdded {
                    return $0.dateAdded < $1.dateAdded
                }
                return $0.id < $1.id
            }

        // Preserve every legacy rule. New dictionary mutations prevent source
        // conflicts, but older stores may contain multiple rules for a trigger.
        let prepared = sortedRules.compactMap { rule -> PreparedRule? in
            guard usesWordBoundaries(for: rule.original) else {
                return PreparedRule(original: rule.original, replacement: rule.replacement, regex: nil)
            }

            // Unicode-aware lookarounds treat punctuation as a boundary while
            // preventing matches inside larger words.
            do {
                let escaped = NSRegularExpression.escapedPattern(for: rule.original)
                let wordChar = "[[\\p{L}\\p{M}\\p{N}]-[\\p{scx=Han}\\p{scx=Hiragana}\\p{scx=Katakana}\\p{scx=Hangul}\\p{scx=Thai}]]"
                // The trailing lookahead keeps "can" from matching inside "can't".
                let contraction = "(?!['\u{2018}\u{2019}\u{00B4}`\u{2032}]t(?![\\p{L}\\p{N}]))"
                let pattern = "(?<!\(wordChar))(?:\(escaped))(?!\(wordChar))\(contraction)"
                let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                return PreparedRule(original: rule.original, replacement: rule.replacement, regex: regex)
            } catch {
                logger.error(
                    "Could not build matcher for word replacement \(rule.original, privacy: .private): \(error, privacy: .public)"
                )
                return nil
            }
        }

        cachedRecords = records
        cachedRules = prepared
        logger.debug("Rebuilt cached word replacement plan with \(prepared.count, privacy: .public) rule(s)")
        return prepared
    }

    private func usesWordBoundaries(for text: String) -> Bool {
        // Returns false for languages without spaces (CJK, Thai), true for spaced languages
        let nonSpacedScripts: [ClosedRange<UInt32>] = [
            0x3040...0x309F,  // Hiragana
            0x30A0...0x30FF,  // Katakana
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xAC00...0xD7AF,  // Hangul Syllables
            0x0E00...0x0E7F,  // Thai
        ]

        for scalar in text.unicodeScalars {
            for range in nonSpacedScripts {
                if range.contains(scalar.value) {
                    return false
                }
            }
        }

        return true
    }
}

extension WordReplacementService {
    /// Same rules as `applyReplacements(to:using:)`, also returning the total
    /// number of substitutions (regex matches or substring occurrences).
    func applyReplacementsCounted(to text: String, using context: ModelContext) -> (text: String, count: Int) {
        replace(in: text, using: context)
    }
}
