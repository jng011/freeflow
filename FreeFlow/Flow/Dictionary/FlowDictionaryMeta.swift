import Foundation
import OSLog

/// Extra per-entry data the SwiftData models do not have. Stored in the sidecar
/// FlowPaths.file("flow-dictionary-meta.json") keyed by `FlowDictionaryEntry.id`.
struct FlowDictionaryMetaRecord: Codable, Equatable, Sendable {
    var starred: Bool = false
    var source: FlowDictionarySource = .manual
    var observedSource: String?
    var frequencyUsed: Int = 0
    var lastUsed: Date?
    var createdAt: Date?
    /// The stored text at the moment Auto-learn added the entry. Undo only
    /// removes the entry while its stored text still equals this value.
    var learnedSnapshot: String?

    init(
        starred: Bool = false,
        source: FlowDictionarySource = .manual,
        observedSource: String? = nil,
        frequencyUsed: Int = 0,
        lastUsed: Date? = nil,
        createdAt: Date? = nil,
        learnedSnapshot: String? = nil
    ) {
        self.starred = starred
        self.source = source
        self.observedSource = observedSource
        self.frequencyUsed = frequencyUsed
        self.lastUsed = lastUsed
        self.createdAt = createdAt
        self.learnedSnapshot = learnedSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case starred, source, observedSource, frequencyUsed, lastUsed, createdAt, learnedSnapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        let rawSource = try container.decodeIfPresent(String.self, forKey: .source)
        source = rawSource.flatMap(FlowDictionarySource.init(rawValue:)) ?? .manual
        observedSource = try container.decodeIfPresent(String.self, forKey: .observedSource)
        frequencyUsed = try container.decodeIfPresent(Int.self, forKey: .frequencyUsed) ?? 0
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        learnedSnapshot = try container.decodeIfPresent(String.self, forKey: .learnedSnapshot)
    }
}

/// Owner of the meta sidecar. Mutations happen on the main actor; a copy is
/// mirrored into `FlowDictionaryMetaSnapshot` for nonisolated readers
/// (CustomVocabularyService, Auto-learn).
@MainActor
final class FlowDictionaryMeta {
    static let shared = FlowDictionaryMeta()

    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowDictionaryMeta")
    private let ioQueue = DispatchQueue(label: "com.jaydenghiyam.FreeFlow.dictionary-meta", qos: .utility)
    private(set) var records: [String: FlowDictionaryMetaRecord] = [:]
    private var isLoaded = false
    private var saveTask: Task<Void, Never>?

    private init() {}

    private var fileURL: URL { FlowPaths.file("flow-dictionary-meta.json") }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            publishSnapshot()
            return
        }
        do {
            records = try Self.decoder.decode([String: FlowDictionaryMetaRecord].self, from: data)
        } catch {
            logger.error("Could not read dictionary meta: \(error, privacy: .public)")
            records = [:]
        }
        publishSnapshot()
    }

    func record(for id: String) -> FlowDictionaryMetaRecord? {
        records[id]
    }

    func update(_ id: String, _ mutate: (inout FlowDictionaryMetaRecord) -> Void) {
        var record = records[id] ?? FlowDictionaryMetaRecord()
        mutate(&record)
        guard records[id] != record else { return }
        records[id] = record
        publishSnapshot()
    }

    func set(_ record: FlowDictionaryMetaRecord, for id: String) {
        guard records[id] != record else { return }
        records[id] = record
        publishSnapshot()
    }

    /// Moves meta to a new id when a word is renamed. An existing record at the
    /// destination keeps its usage counts but takes the moved star and source.
    func move(from oldID: String, to newID: String) {
        guard oldID != newID, let record = records.removeValue(forKey: oldID) else { return }
        if var existing = records[newID] {
            existing.starred = existing.starred || record.starred
            existing.frequencyUsed = max(existing.frequencyUsed, record.frequencyUsed)
            existing.lastUsed = [existing.lastUsed, record.lastUsed].compactMap { $0 }.max()
            records[newID] = existing
        } else {
            records[newID] = record
        }
        publishSnapshot()
    }

    func remove(_ id: String) {
        guard records.removeValue(forKey: id) != nil else { return }
        publishSnapshot()
    }

    /// Debounced write of the sidecar.
    func scheduleSave(after delay: TimeInterval = 0.3) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = records
        let url = fileURL
        let logger = logger
        // Encoding and the atomic write run on a serial queue so large
        // dictionaries never stall the main thread and writes stay ordered.
        ioQueue.async {
            do {
                let data = try Self.encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Could not write dictionary meta: \(error, privacy: .public)")
            }
        }
    }

    private func publishSnapshot() {
        FlowDictionaryMetaSnapshot.shared.records = records
    }

    nonisolated static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Thread-safe copy of the meta records for code that does not run on the main actor.
final class FlowDictionaryMetaSnapshot: @unchecked Sendable {
    static let shared = FlowDictionaryMetaSnapshot()

    private let lock = NSLock()
    private var storage: [String: FlowDictionaryMetaRecord] = [:]

    var records: [String: FlowDictionaryMetaRecord] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

// MARK: - Prompt ranking

/// Orders dictionary words for the ASR prompt and cleanup context.
enum FlowDictionaryRanking {
    static let maximumPromptWords = 200

    struct Item: Sendable {
        let word: String
        let starred: Bool
        let source: FlowDictionarySource
        let frequencyUsed: Int
        let lastUsed: Date?
    }

    /// Builds prompt items from raw model values plus meta.
    /// `vocabulary` holds stored words, `replacements` holds (rule id, correct text).
    static func items(
        vocabulary: [String],
        replacements: [(id: UUID, target: String)],
        meta: [String: FlowDictionaryMetaRecord]
    ) -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(vocabulary.count + replacements.count)
        for word in vocabulary {
            let record = meta[FlowDictionaryEntry.vocabularyID(for: word)]
            items.append(item(word: word, record: record))
        }
        for rule in replacements {
            let record = meta[FlowDictionaryEntry.replacementID(for: rule.id)]
            items.append(item(word: rule.target, record: record))
        }
        return items
    }

    static func items(from entries: [FlowDictionaryEntry]) -> [Item] {
        entries.map {
            Item(
                word: $0.correctTerm,
                starred: $0.isStarred,
                source: $0.source,
                frequencyUsed: $0.frequencyUsed,
                lastUsed: $0.lastUsed
            )
        }
    }

    private static func item(word: String, record: FlowDictionaryMetaRecord?) -> Item {
        Item(
            word: word,
            starred: record?.starred ?? false,
            source: record?.source ?? .manual,
            frequencyUsed: record?.frequencyUsed ?? 0,
            lastUsed: record?.lastUsed
        )
    }

    /// Starred first, then recency bucket, source rank, frequency and alphabetical.
    /// Auto-learned stopwords are dropped, duplicates removed, capped at 200.
    static func promptWords(from items: [Item], now: Date = Date()) -> [String] {
        let candidates = items.compactMap { item -> (Item, String)? in
            let word = item.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            if item.source == .auto, FlowDictionaryStopwords.isOnlyStopwords(word) { return nil }
            return (item, word)
        }

        let sorted = candidates.sorted { lhs, rhs in
            let left = lhs.0
            let right = rhs.0
            if left.starred != right.starred { return left.starred }
            let leftBucket = recencyBucket(left.lastUsed, now: now)
            let rightBucket = recencyBucket(right.lastUsed, now: now)
            if leftBucket != rightBucket { return leftBucket < rightBucket }
            if left.source.promptRank != right.source.promptRank {
                return left.source.promptRank < right.source.promptRank
            }
            if left.frequencyUsed != right.frequencyUsed { return left.frequencyUsed > right.frequencyUsed }
            return lhs.1.localizedCaseInsensitiveCompare(rhs.1) == .orderedAscending
        }

        var seen = Set<String>()
        var result: [String] = []
        for (_, word) in sorted {
            guard seen.insert(WordReplacementVariants.key(for: word)).inserted else { continue }
            result.append(word)
            if result.count >= maximumPromptWords { break }
        }
        return result
    }

    private static func recencyBucket(_ date: Date?, now: Date) -> Int {
        guard let date else { return 2 }
        let age = now.timeIntervalSince(date)
        if age <= 24 * 3600 { return 0 }
        if age <= 14 * 24 * 3600 { return 1 }
        return 2
    }
}

// MARK: - Text helpers

enum FlowDictionaryText {
    /// Case-insensitive whole-word containment. A match must not touch a letter,
    /// number or underscore on either side.
    static func containsWholeWord(_ term: String, in text: String) -> Bool {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, needle.count <= text.count else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        ) {
            let beforeOK = found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex
                || !isWordCharacter(text[found.upperBound])
            if beforeOK && afterOK { return true }
            guard found.lowerBound < text.endIndex else { break }
            searchRange = text.index(after: found.lowerBound)..<text.endIndex
        }
        return false
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    /// Lowercased text without punctuation, symbols or whitespace.
    static func stripped(_ text: String) -> String {
        let removed = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !removed.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars).lowercased()
    }
}

// MARK: - Stopwords

enum FlowDictionaryStopwords {
    static let fragments: Set<String> = ["'s", "'t", "'ll", "'ve", "'re", "'d", "'m", "s", "t", "ll", "ve", "re", "d", "m"]

    static let english: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "also", "am", "an", "and", "any", "are",
        "as", "at", "be", "because", "been", "before", "being", "below", "between", "both", "but", "by",
        "can", "could", "did", "do", "does", "doing", "done", "down", "during", "each", "even", "ever",
        "few", "for", "from", "further", "get", "got", "had", "has", "have", "having", "he", "her", "here",
        "hers", "herself", "him", "himself", "his", "how", "i", "if", "in", "into", "is", "it", "its",
        "itself", "just", "let", "like", "made", "make", "many", "may", "me", "might", "more", "most",
        "much", "must", "my", "myself", "no", "nor", "not", "now", "of", "off", "oh", "ok", "okay", "on",
        "once", "one", "only", "or", "other", "our", "ours", "ourselves", "out", "over", "own", "really",
        "same", "say", "said", "she", "should", "so", "some", "still", "such", "than", "that", "the",
        "their", "theirs", "them", "themselves", "then", "there", "these", "they", "thing", "things",
        "this", "those", "though", "through", "to", "too", "um", "uh", "under", "until", "up", "us",
        "very", "was", "way", "we", "well", "were", "what", "when", "where", "which", "while", "who",
        "whom", "why", "will", "with", "would", "yeah", "yes", "yet", "you", "your", "yours", "yourself",
        "yourselves", "dont", "don't", "cant", "can't", "wont", "won't", "im", "i'm", "ive", "i've",
        "it's", "thats", "that's", "theres", "there's", "go", "going", "gonna", "want", "wanna",
        "know", "think", "see", "two", "three", "new", "good", "back", "right", "time", "lot",
    ]

    /// Lowercased words with straight apostrophes and edge punctuation removed.
    static func words(in text: String) -> [String] {
        text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { token in
                token.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
            }
            .filter { !$0.isEmpty }
    }

    /// True when every word is a stopword or a possessive/contraction fragment.
    static func isOnlyStopwords(_ text: String) -> Bool {
        let tokens = words(in: text)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { english.contains($0) || fragments.contains($0) }
    }
}
