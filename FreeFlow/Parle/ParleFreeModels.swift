import AppKit
import SwiftUI

enum ParleFreeModels {
    /// Free OpenRouter models with their catalog names ("Google: Gemma 3" -> "Gemma 3").
    static func openRouter() async -> [(id: String, name: String)] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models"),
            let (data, _) = try? await URLSession.shared.data(from: url)
        else { return [] }
        struct Catalog: Decodable {
            struct Model: Decodable { let id: String; let name: String? }
            let data: [Model]
        }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.data
            .filter { $0.id.hasSuffix(":free") && !$0.id.contains("safety") && !$0.id.contains("code") }
            .prefix(8)
            .map { ($0.id, cleanName($0.name) ?? readableName(for: $0.id)) }
    }

    /// Readable name for any model ID: "google/gemini-3.5-flash" -> "Gemini 3.5 Flash".
    static func readableName(for id: String) -> String {
        let base = id.split(separator: "/").last.map(String.init) ?? id
        let core = base.split(separator: ":").first.map(String.init) ?? base
        let words = core.split(separator: "-").map { part -> String in
            let p = String(part)
            if p.count <= 3 && p.allSatisfy(\.isLetter) { return p.uppercased() }
            return p.prefix(1).uppercased() + p.dropFirst()
        }
        return words.joined(separator: " ")
    }

    private static func cleanName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let withoutVendor = name.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? name
        return withoutVendor.replacingOccurrences(of: " (free)", with: "")
    }
}
