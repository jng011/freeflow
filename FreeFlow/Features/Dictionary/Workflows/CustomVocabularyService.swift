import Foundation
import SwiftData

class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    /// Dictionary words for the ASR prompt and cleanup context, in Flow's
    /// priority order (starred, recently used, manual before auto/imported/seed,
    /// frequency, alphabetical), including the correct side of replacement rules.
    func getCustomVocabulary(from context: ModelContext) -> String {
        guard let customWords = getCustomVocabularyWords(from: context), !customWords.isEmpty else {
            return ""
        }

        let wordsText = customWords.joined(separator: ", ")
        return "Important Vocabulary: \(wordsText)"
    }

    private func getCustomVocabularyWords(from context: ModelContext) -> [String]? {
        do {
            let vocabulary = try context.fetch(FetchDescriptor<VocabularyWord>()).map { $0.word }
            let replacements = try context.fetch(FetchDescriptor<WordReplacement>()).map {
                (id: $0.id, target: $0.replacementText)
            }
            let items = FlowDictionaryRanking.items(
                vocabulary: vocabulary,
                replacements: replacements,
                meta: FlowDictionaryMetaSnapshot.shared.records
            )
            let words = FlowDictionaryRanking.promptWords(from: items)
            return words.isEmpty ? nil : words
        } catch {
            return nil
        }
    }
}
