import Foundation
import SwiftData

/// Adds Parle's name and the person's own name to the Dictionary once, so they
/// are spelled right from the first dictation. People can delete them like any entry.
@MainActor
enum ParleDictionarySeed {
    private static let doneKey = "ParleDictionarySeeded"

    static func runIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let words = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
        var vocabulary = ["Parle"]
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespaces)
        if !fullName.isEmpty {
            vocabulary.append(fullName)
            vocabulary.append(contentsOf: fullName.split(separator: " ").map(String.init).filter { $0.count > 2 })
        }
        _ = DictionaryService.addVocabularyWords(vocabulary.joined(separator: ", "), existing: words, context: context)
        let replacements = (try? context.fetch(FetchDescriptor<WordReplacement>())) ?? []
        _ = DictionaryService.addWordReplacement(
            original: "parlay, parley", replacement: "Parle", existing: replacements, context: context)
        try? context.save()
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
