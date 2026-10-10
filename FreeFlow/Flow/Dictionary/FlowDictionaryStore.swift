import AppKit
import CoreData
import Foundation
import OSLog
import SwiftData

/// The Dictionary page's view of the existing SwiftData models (VocabularyWord and
/// WordReplacement) merged with the meta sidecar (star, source, usage).
@MainActor
final class FlowDictionaryStore: ObservableObject {
    static let shared = FlowDictionaryStore()

    @Published private(set) var entries: [FlowDictionaryEntry] = []

    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowDictionaryStore")
    private let meta = FlowDictionaryMeta.shared
    private let exportQueue = DispatchQueue(label: "com.jaydenghiyam.FreeFlow.dictionary-export", qos: .utility)
    private var modelContext: ModelContext?
    private var observers: [NSObjectProtocol] = []
    private var reloadTask: Task<Void, Never>?
    private var isMutating = false

    /// Auto-learned entries are only marked when they were created this recently.
    private let autoLearnWindow: TimeInterval = 300

    private init() {}

    // MARK: - Setup

    func configure(modelContext: ModelContext) {
        guard self.modelContext == nil else { return }
        self.modelContext = modelContext
        meta.loadIfNeeded()
        observeChanges()
        reload()
    }

    private func observeChanges() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.wordReplacementsDidChange, .autoLearnQueueDidChange]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    FlowDictionaryStore.shared.scheduleReload()
                }
            })
        }

        // Any context saving dictionary models (Auto-learn's model actor, old views, import).
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { note in
            guard FlowDictionaryStore.touchesDictionary(note) else { return }
            MainActor.assumeIsolated {
                FlowDictionaryStore.shared.scheduleReload()
            }
        })

        // CloudKit sync of dictionary.store.
        observers.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                FlowDictionaryStore.shared.scheduleReload()
            }
        })
    }

    nonisolated private static func touchesDictionary(_ note: Notification) -> Bool {
        guard let userInfo = note.userInfo, !userInfo.isEmpty else { return true }
        var sawIdentifiers = false
        for value in userInfo.values {
            guard let identifiers = value as? [PersistentIdentifier] else { continue }
            sawIdentifiers = true
            if identifiers.contains(where: {
                $0.entityName == "VocabularyWord" || $0.entityName == "WordReplacement"
            }) {
                return true
            }
        }
        return !sawIdentifiers
    }

    private func scheduleReload() {
        guard modelContext != nil, !isMutating else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    // MARK: - Loading

    func reload() {
        guard let context = modelContext else { return }
        reloadTask?.cancel()
        reloadTask = nil

        let words: [VocabularyWord]
        let rules: [WordReplacement]
        do {
            words = try context.fetch(FetchDescriptor<VocabularyWord>())
            rules = try context.fetch(FetchDescriptor<WordReplacement>())
        } catch {
            logger.error("Could not load dictionary: \(error, privacy: .public)")
            return
        }

        var result: [FlowDictionaryEntry] = []
        result.reserveCapacity(words.count + rules.count)
        var seen = Set<String>()

        for word in words.sorted(by: { $0.dateAdded < $1.dateAdded }) {
            let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let id = FlowDictionaryEntry.vocabularyID(for: text)
            guard seen.insert(id).inserted else { continue }
            result.append(makeEntry(id: id, phrase: text, replacement: nil, dateAdded: word.dateAdded))
        }

        for rule in rules {
            let id = FlowDictionaryEntry.replacementID(for: rule.id)
            guard seen.insert(id).inserted else { continue }
            let target = rule.replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rule.originalText.isEmpty || !target.isEmpty else { continue }
            result.append(makeEntry(id: id, phrase: rule.originalText, replacement: target, dateAdded: rule.dateAdded))
        }

        result.sort { $0.createdAt > $1.createdAt }
        if result != entries {
            entries = result
        }
        FlowDictionaryKnownTerms.shared.update(from: result)
        writeExportSnapshot(result)
    }

    private func makeEntry(id: String, phrase: String, replacement: String?, dateAdded: Date) -> FlowDictionaryEntry {
        let record = meta.record(for: id)
        return FlowDictionaryEntry(
            id: id,
            phrase: phrase,
            replacement: replacement,
            isStarred: record?.starred ?? false,
            source: record?.source ?? .manual,
            observedSource: record?.observedSource,
            frequencyUsed: record?.frequencyUsed ?? 0,
            lastUsed: record?.lastUsed,
            createdAt: dateAdded
        )
    }

    private struct ExportFile: Encodable {
        struct Item: Encodable {
            let phrase: String
            let replacement: String?
            let starred: Bool
            let source: String
            let frequencyUsed: Int
            let createdAt: Date

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(phrase, forKey: .phrase)
                // Keep `replacement` present as null for vocabulary words.
                try container.encode(replacement, forKey: .replacement)
                try container.encode(starred, forKey: .starred)
                try container.encode(source, forKey: .source)
                try container.encode(frequencyUsed, forKey: .frequencyUsed)
                try container.encode(createdAt, forKey: .createdAt)
            }

            private enum CodingKeys: String, CodingKey {
                case phrase, replacement, starred, source, frequencyUsed, createdAt
            }
        }

        let updatedAt: Date
        let entries: [Item]
    }

    /// Snapshot for the MCP server: FlowPaths.file("flow-dictionary-export.json").
    private func writeExportSnapshot(_ entries: [FlowDictionaryEntry]) {
        let file = ExportFile(
            updatedAt: Date(),
            entries: entries.map {
                ExportFile.Item(
                    phrase: $0.phrase,
                    replacement: $0.replacement,
                    starred: $0.isStarred,
                    source: $0.source.rawValue,
                    frequencyUsed: $0.frequencyUsed,
                    createdAt: $0.createdAt
                )
            }
        )
        let url = FlowPaths.file("flow-dictionary-export.json")
        let logger = logger
        exportQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(file)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Could not write dictionary export: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Validation

    private struct Validated {
        let phrase: String
        let replacement: String?
    }

    private func validate(phrase: String, replacement: String?, excluding entry: FlowDictionaryEntry?) throws -> Validated {
        guard let context = modelContext else { throw FlowDictionaryError.notReady }

        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        let trimmedReplacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        let isRule = trimmedReplacement != nil

        guard !trimmedPhrase.isEmpty else { throw FlowDictionaryError.empty }
        if let trimmedReplacement, trimmedReplacement.isEmpty { throw FlowDictionaryError.empty }

        let variants = isRule ? WordReplacementVariants.parse(trimmedPhrase) : [trimmedPhrase]
        guard !variants.isEmpty else { throw FlowDictionaryError.empty }
        if isRule {
            guard variants.allSatisfy({ $0.count <= FlowDictionaryError.phraseLimit }) else {
                throw FlowDictionaryError.tooLong
            }
        } else if trimmedPhrase.count > FlowDictionaryError.phraseLimit {
            throw FlowDictionaryError.tooLong
        }
        if let trimmedReplacement, trimmedReplacement.count > FlowDictionaryError.replacementLimit {
            throw FlowDictionaryError.replacementTooLong
        }
        if let trimmedReplacement,
            variants.count == 1,
            WordReplacementVariants.key(for: variants[0]) == WordReplacementVariants.key(for: trimmedReplacement),
            variants[0] == trimmedReplacement
        {
            throw FlowDictionaryError.failed("The misspelling and the correct spelling are the same")
        }

        let words = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
        let rules = (try? context.fetch(FetchDescriptor<WordReplacement>())) ?? []

        let excludedVocabularyID = (entry?.isReplacement == false) ? entry?.id : nil
        let excludedRuleID = (entry?.isReplacement == true) ? entry?.id : nil

        let vocabularyKeys = Set(
            words
                .filter { FlowDictionaryEntry.vocabularyID(for: $0.word) != excludedVocabularyID }
                .map { WordReplacementVariants.key(for: $0.word) }
        )
        let ruleVariantKeys = Set(
            rules
                .filter { FlowDictionaryEntry.replacementID(for: $0.id) != excludedRuleID }
                .flatMap { WordReplacementVariants.parse($0.originalText) }
                .map { WordReplacementVariants.key(for: $0) }
        )

        for variant in variants {
            let key = WordReplacementVariants.key(for: variant)
            if vocabularyKeys.contains(key) || ruleVariantKeys.contains(key) {
                throw FlowDictionaryError.duplicate
            }
        }

        return Validated(phrase: isRule ? WordReplacementVariants.serialize(variants) : trimmedPhrase,
                         replacement: trimmedReplacement)
    }

    // MARK: - Mutations

    @discardableResult
    func add(
        phrase: String,
        replacement: String?,
        source: FlowDictionarySource = .manual,
        starred: Bool = false
    ) throws -> FlowDictionaryEntry {
        let valid = try validate(phrase: phrase, replacement: replacement, excluding: nil)
        guard let context = modelContext else { throw FlowDictionaryError.notReady }

        isMutating = true
        defer { isMutating = false }

        let id: String
        if let target = valid.replacement {
            let rules = (try? context.fetch(FetchDescriptor<WordReplacement>())) ?? []
            if let message = DictionaryService.addWordReplacement(
                original: valid.phrase,
                replacement: target,
                existing: rules,
                context: context
            ) {
                throw FlowDictionaryError.failed(message)
            }
            let refreshed = (try? context.fetch(FetchDescriptor<WordReplacement>())) ?? []
            let destinationKey = WordReplacementVariants.destinationKey(for: target)
            let firstVariant = WordReplacementVariants.parse(valid.phrase).first ?? valid.phrase
            guard let rule = refreshed.first(where: {
                WordReplacementVariants.destinationKey(for: $0.replacementText) == destinationKey
                    && WordReplacementVariants.contains(firstVariant, in: WordReplacementVariants.parse($0.originalText))
            }) else {
                throw FlowDictionaryError.failed("Could not add the replacement")
            }
            id = FlowDictionaryEntry.replacementID(for: rule.id)
        } else {
            if valid.phrase.contains(",") {
                // The service splits on commas; a single entry keeps its text as typed.
                let word = VocabularyWord(word: valid.phrase)
                context.insert(word)
            } else {
                let words = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
                if let message = DictionaryService.addVocabularyWords(valid.phrase, existing: words, context: context) {
                    throw FlowDictionaryError.failed(message)
                }
            }
            id = FlowDictionaryEntry.vocabularyID(for: valid.phrase)
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw FlowDictionaryError.failed("Could not save: \(error.localizedDescription)")
        }

        if meta.record(for: id) == nil {
            meta.set(FlowDictionaryMetaRecord(starred: starred, source: source, createdAt: Date()), for: id)
        } else if starred {
            meta.update(id) { $0.starred = true }
        }
        meta.scheduleSave()

        NotificationCenter.default.post(name: .wordReplacementsDidChange, object: nil)
        reload()

        if let entry = entries.first(where: { $0.id == id }) {
            return entry
        }
        return FlowDictionaryEntry(
            id: id,
            phrase: valid.phrase,
            replacement: valid.replacement,
            isStarred: starred,
            source: source,
            observedSource: nil,
            frequencyUsed: 0,
            lastUsed: nil,
            createdAt: Date()
        )
    }

    func update(_ entry: FlowDictionaryEntry, phrase: String, replacement: String?) throws {
        let valid = try validate(phrase: phrase, replacement: replacement, excluding: entry)
        guard let context = modelContext else { throw FlowDictionaryError.notReady }

        // Switching between a word and a replacement rule: recreate with the same meta.
        if entry.isReplacement != (valid.replacement != nil) {
            let previous = meta.record(for: entry.id)
            delete(entry)
            let added = try add(
                phrase: valid.phrase,
                replacement: valid.replacement,
                source: entry.source,
                starred: entry.isStarred
            )
            if var record = previous {
                record.learnedSnapshot = nil
                meta.set(record, for: added.id)
                meta.scheduleSave()
                reload()
            }
            return
        }

        isMutating = true
        defer { isMutating = false }

        if let target = valid.replacement {
            guard let rule = replacementModel(for: entry, in: context) else {
                throw FlowDictionaryError.failed("This entry no longer exists")
            }
            if let message = DictionaryService.updateWordReplacement(
                rule,
                original: valid.phrase,
                replacementText: target,
                context: context
            ) {
                throw FlowDictionaryError.failed(message)
            }
        } else {
            let matches = vocabularyModels(for: entry, in: context)
            guard let first = matches.first else {
                throw FlowDictionaryError.failed("This entry no longer exists")
            }
            first.word = valid.phrase
            for duplicate in matches.dropFirst() {
                context.delete(duplicate)
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                throw FlowDictionaryError.failed("Could not save: \(error.localizedDescription)")
            }
            let newID = FlowDictionaryEntry.vocabularyID(for: valid.phrase)
            meta.move(from: entry.id, to: newID)
        }

        let currentID = entry.isReplacement ? entry.id : FlowDictionaryEntry.vocabularyID(for: valid.phrase)
        if meta.record(for: currentID) != nil {
            meta.update(currentID) { $0.learnedSnapshot = nil }
        }
        meta.scheduleSave()
        NotificationCenter.default.post(name: .wordReplacementsDidChange, object: nil)
        reload()
    }

    func delete(_ entry: FlowDictionaryEntry) {
        guard let context = modelContext else { return }
        isMutating = true
        defer { isMutating = false }

        if entry.isReplacement {
            if let rule = replacementModel(for: entry, in: context),
                let message = DictionaryService.removeWordReplacement(rule, context: context)
            {
                logger.error("Delete failed: \(message, privacy: .public)")
                return
            }
        } else {
            for word in vocabularyModels(for: entry, in: context) {
                context.delete(word)
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                logger.error("Delete failed: \(error, privacy: .public)")
                return
            }
        }

        meta.remove(entry.id)
        meta.scheduleSave()
        NotificationCenter.default.post(name: .wordReplacementsDidChange, object: nil)
        reload()
    }

    func setStarred(_ entry: FlowDictionaryEntry, _ starred: Bool) {
        meta.update(entry.id) { $0.starred = starred }
        meta.scheduleSave()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].isStarred = starred
        }
        writeExportSnapshot(entries)
    }

    // MARK: - Usage

    /// Called by the engine after each delivery. Matching runs off the main
    /// thread; the meta write is debounced by one second.
    func noteUsage(in text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !entries.isEmpty else { return }
        let terms = entries.map { (id: $0.id, term: $0.correctTerm) }

        Task.detached(priority: .utility) {
            let matched = terms.compactMap { item -> String? in
                FlowDictionaryText.containsWholeWord(item.term, in: trimmed) ? item.id : nil
            }
            guard !matched.isEmpty else { return }
            await FlowDictionaryStore.shared.recordUsage(ids: matched, at: Date())
        }
    }

    private func recordUsage(ids: [String], at date: Date) {
        let known = Set(entries.map(\.id))
        for id in ids where known.contains(id) {
            meta.update(id) {
                $0.frequencyUsed += 1
                $0.lastUsed = date
            }
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].frequencyUsed += 1
                entries[index].lastUsed = date
            }
        }
        meta.scheduleSave(after: 1.0)
    }

    // MARK: - MCP

    func addFromExternal(phrase: String, replacement: String?) -> Result<String, Error> {
        let target = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try add(phrase: phrase, replacement: (target?.isEmpty ?? true) ? nil : target, source: .mcp)
            return .success("Added")
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Auto-learn

    /// Marks words that Auto-learn just inserted. `observed` maps the stored
    /// word to the text Flow heard (the misspelling).
    func markAutoLearned(words: [String], observed: [String: String]) {
        guard modelContext != nil, !words.isEmpty else { return }
        reload()
        let now = Date()
        var changed = false

        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let heard = observed[word] ?? observed[trimmed]

            let vocabularyID = FlowDictionaryEntry.vocabularyID(for: trimmed)
            if let entry = entries.first(where: { $0.id == vocabularyID }),
                now.timeIntervalSince(entry.createdAt) <= autoLearnWindow
            {
                meta.update(entry.id) {
                    $0.source = .auto
                    $0.observedSource = heard
                    $0.learnedSnapshot = entry.phrase
                    if $0.createdAt == nil { $0.createdAt = now }
                }
                changed = true
            }

            let destinationKey = WordReplacementVariants.destinationKey(for: trimmed)
            for entry in entries where entry.isReplacement {
                guard let target = entry.replacement,
                    WordReplacementVariants.destinationKey(for: target) == destinationKey
                else { continue }
                if let heard, !WordReplacementVariants.contains(heard, in: entry.phraseVariants) { continue }
                let isNew = now.timeIntervalSince(entry.createdAt) <= autoLearnWindow
                meta.update(entry.id) {
                    if isNew { $0.source = .auto }
                    $0.observedSource = heard
                    $0.learnedSnapshot = entry.phrase
                    if $0.createdAt == nil { $0.createdAt = now }
                }
                changed = true
            }
        }

        guard changed else { return }
        meta.scheduleSave()
        reload()
    }

    /// Reverts `markAutoLearned` entries, but only those whose stored text
    /// still equals the snapshot taken when they were learned.
    func undoAutoLearned(words: [String]) {
        guard let context = modelContext, !words.isEmpty else { return }
        reload()
        isMutating = true
        var changed = false

        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let vocabularyID = FlowDictionaryEntry.vocabularyID(for: trimmed)
            if let entry = entries.first(where: { $0.id == vocabularyID }),
                let record = meta.record(for: entry.id),
                let snapshot = record.learnedSnapshot,
                snapshot == entry.phrase
            {
                for model in vocabularyModels(for: entry, in: context) {
                    context.delete(model)
                }
                meta.remove(entry.id)
                changed = true
            }

            let destinationKey = WordReplacementVariants.destinationKey(for: trimmed)
            for entry in entries where entry.isReplacement {
                guard let target = entry.replacement,
                    WordReplacementVariants.destinationKey(for: target) == destinationKey,
                    let record = meta.record(for: entry.id),
                    let snapshot = record.learnedSnapshot,
                    snapshot == entry.phrase,
                    let rule = replacementModel(for: entry, in: context)
                else { continue }

                var variants = WordReplacementVariants.parse(rule.originalText)
                if let heard = record.observedSource {
                    let heardKey = WordReplacementVariants.key(for: heard)
                    variants.removeAll { WordReplacementVariants.key(for: $0) == heardKey }
                } else if record.source == .auto {
                    variants.removeAll()
                } else {
                    continue
                }

                if variants.isEmpty {
                    context.delete(rule)
                    meta.remove(entry.id)
                } else {
                    rule.originalText = WordReplacementVariants.serialize(variants)
                    meta.update(entry.id) {
                        $0.learnedSnapshot = nil
                        $0.observedSource = nil
                    }
                }
                changed = true
            }
        }

        if changed {
            do {
                try context.save()
            } catch {
                context.rollback()
                logger.error("Auto-learn undo failed: \(error, privacy: .public)")
            }
            meta.scheduleSave()
        }
        isMutating = false
        guard changed else { return }
        NotificationCenter.default.post(name: .wordReplacementsDidChange, object: nil)
        reload()
    }

    // MARK: - Prompt words

    /// Ordered list for ASR and cleanup prompts (max 200): starred first, then
    /// recency, source, frequency and alphabetical. Includes replacement targets.
    var vocabularyPromptWords: [String] {
        FlowDictionaryRanking.promptWords(from: FlowDictionaryRanking.items(from: entries))
    }

    // MARK: - Model lookup

    private func vocabularyModels(for entry: FlowDictionaryEntry, in context: ModelContext) -> [VocabularyWord] {
        let words = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
        return words
            .filter { FlowDictionaryEntry.vocabularyID(for: $0.word) == entry.id }
            .sorted { $0.dateAdded < $1.dateAdded }
    }

    private func replacementModel(for entry: FlowDictionaryEntry, in context: ModelContext) -> WordReplacement? {
        let rules = (try? context.fetch(FetchDescriptor<WordReplacement>())) ?? []
        return rules.first { FlowDictionaryEntry.replacementID(for: $0.id) == entry.id }
    }
}

/// Thread-safe set of terms already in the dictionary, refreshed on every
/// reload. Auto-learn reads it to skip candidates the dictionary already covers.
final class FlowDictionaryKnownTerms: @unchecked Sendable {
    static let shared = FlowDictionaryKnownTerms()

    private let lock = NSLock()
    private var vocabularyKeys = Set<String>()
    private var replacementSourceKeys = Set<String>()

    func update(from entries: [FlowDictionaryEntry]) {
        var vocabulary = Set<String>()
        var sources = Set<String>()
        for entry in entries {
            if entry.isReplacement {
                for variant in entry.phraseVariants {
                    sources.insert(WordReplacementVariants.key(for: variant))
                }
            } else {
                vocabulary.insert(WordReplacementVariants.key(for: entry.phrase))
            }
        }
        lock.lock()
        vocabularyKeys = vocabulary
        replacementSourceKeys = sources
        lock.unlock()
    }

    func isVocabularyWord(_ text: String) -> Bool {
        let key = WordReplacementVariants.key(for: text)
        lock.lock()
        defer { lock.unlock() }
        return vocabularyKeys.contains(key)
    }

    func isReplacementSource(_ text: String) -> Bool {
        let key = WordReplacementVariants.key(for: text)
        lock.lock()
        defer { lock.unlock() }
        return replacementSourceKeys.contains(key)
    }
}
