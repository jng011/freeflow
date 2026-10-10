import Foundation
import SwiftData

/// One-time starter entries for the Dictionary page. Each entry is skipped when
/// it already exists, and people can delete them like any other entry.
@MainActor
enum FlowDictionarySeed {
    private static let doneKey = "FlowDictionarySeededV1"

    static func runIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        let store = FlowDictionaryStore.shared
        // No-op when launch already configured the store with this context.
        store.configure(modelContext: context)

        _ = try? store.add(phrase: "btw", replacement: "by the way", source: .seed)
        _ = try? store.add(phrase: "Free Flow", replacement: nil, source: .seed)
        _ = try? store.add(phrase: "Free Flow", replacement: nil, source: .seed)

        for name in nameEntries() {
            _ = try? store.add(phrase: name, replacement: nil, source: .seed)
        }

        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Full name and first name from the macOS account, skipping tokens that
    /// look like handles (digits or capitals inside the word).
    private static func nameEntries() -> [String] {
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = fullName
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let validTokens = tokens.filter(isPlainName)
        guard let firstName = validTokens.first else { return [] }

        var names: [String] = []
        if tokens.count > 1, validTokens.count == tokens.count {
            names.append(tokens.joined(separator: " "))
        }
        if tokens.first == firstName {
            names.append(firstName)
        }
        return names
    }

    private static func isPlainName(_ token: String) -> Bool {
        guard token.count >= 2,
            token.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "\u{2019}" })
        else { return false }
        return !token.dropFirst().contains(where: { $0.isUppercase })
    }
}
