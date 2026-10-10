import Foundation
import LLMkit

/// The OpenRouter model list for AI cleanup, cached in UserDefaults so the picker
/// has names before the first network fetch.
final class OpenRouterCatalogStore: @unchecked Sendable {
    enum Kind: String {
        case enhancement = "openRouterModelCatalog"
    }

    static let shared = OpenRouterCatalogStore()

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var cached: [OpenRouterModel]?

    func models(for kind: Kind) -> [OpenRouterModel]? {
        lock.withLock {
            if cached == nil, let data = defaults.data(forKey: kind.rawValue) {
                cached = try? JSONDecoder().decode([OpenRouterModel].self, from: data)
            }
            return cached
        }
    }

    func save(_ models: [OpenRouterModel], for kind: Kind) throws {
        defaults.set(try JSONEncoder().encode(models), forKey: kind.rawValue)
        lock.withLock { cached = models }
    }

    /// Model IDs saved by builds that stored only the IDs.
    var legacyEnhancementModelIDs: [String] {
        defaults.stringArray(forKey: "openRouterModels") ?? []
    }

    func saveLegacyEnhancementModelIDs(_ ids: [String]) {
        defaults.set(ids, forKey: "openRouterModels")
    }
}
