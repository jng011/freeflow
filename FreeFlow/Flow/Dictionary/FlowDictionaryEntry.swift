import Foundation

/// Where a dictionary entry came from. Stored in the meta sidecar, never in SwiftData.
enum FlowDictionarySource: String, Codable, Sendable {
    case manual, auto, seed, imported, mcp

    /// Lower ranks are preferred when the vocabulary prompt has to be trimmed.
    var promptRank: Int {
        switch self {
        case .manual, .mcp: 0
        case .auto: 1
        case .imported: 4
        case .seed: 6
        }
    }

    /// The "Personal" tab shows what the person added themselves.
    var isPersonal: Bool {
        switch self {
        case .manual, .mcp, .imported: true
        case .auto, .seed: false
        }
    }
}

/// One row of the Dictionary page: either a vocabulary word (`replacement == nil`)
/// or a replacement rule ("btw" → "by the way").
struct FlowDictionaryEntry: Identifiable, Hashable, Sendable {
    let id: String                 // "v:<lowercased word>" or "r:<WordReplacement.id>"
    var phrase: String             // vocabulary word, or the replacement's originalText (may contain comma-separated variants)
    var replacement: String?       // nil = vocabulary word
    var isStarred: Bool
    var source: FlowDictionarySource
    var observedSource: String?
    var frequencyUsed: Int
    var lastUsed: Date?
    var createdAt: Date

    var isAutoLearned: Bool { source == .auto }
    var isReplacement: Bool { replacement != nil }

    /// Variants of the phrase as the replacement engine sees them.
    var phraseVariants: [String] {
        isReplacement ? WordReplacementVariants.parse(phrase) : [phrase]
    }

    /// The word Flow should spell correctly: the vocabulary word or the replacement target.
    var correctTerm: String { replacement ?? phrase }

    static func vocabularyID(for word: String) -> String {
        "v:" + word.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    static func replacementID(for id: UUID) -> String {
        "r:" + id.uuidString
    }
}

enum FlowDictionaryError: LocalizedError, Equatable {
    case empty
    case tooLong
    case replacementTooLong
    case duplicate
    case notReady
    case failed(String)

    static let phraseLimit = 60
    static let replacementLimit = 4000

    var errorDescription: String? {
        switch self {
        case .empty: "Type a word first"
        case .tooLong: "Keep it under 60 characters"
        case .replacementTooLong: "Keep it under 4,000 characters"
        case .duplicate: "This word is already in your dictionary"
        case .notReady: "The dictionary is still loading. Try again in a moment."
        case .failed(let message): message
        }
    }
}

/// Sort options of the Dictionary page, persisted in `FlowKeys.dictionarySort`.
enum FlowDictionarySort: String, CaseIterable, Identifiable, Sendable {
    case starred, newest, oldest, alpha

    var id: String { rawValue }

    var title: String {
        switch self {
        case .starred: "Starred first"
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        case .alpha: "Alphabetical (A-Z)"
        }
    }
}
