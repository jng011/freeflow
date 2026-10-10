import Foundation
#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Apple's on-device language model (Apple Intelligence). Used for cleanup on
/// Macs that can run it — the default on Mom's Mac. No key, nothing leaves the Mac.
enum ParleAppleModel {
    static let modelName = "on-device"

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                if case .available = SystemLanguageModel.default.availability { return true }
            }
        #endif
        return false
    }

    static func respond(systemPrompt: String?, userPrompt: String) async throws -> String {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = LanguageModelSession(instructions: systemPrompt)
                return try await session.respond(to: userPrompt).content
            }
        #endif
        throw NSError(
            domain: "Parle", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence isn’t available on this Mac."])
    }
}

extension AIProvider {
    /// The cleanup providers Parle offers. Everything else stays hidden.
    static let parleProviders: [AIProvider] = [.anthropic, .openAI, .openRouter, .appleIntelligence]

    var isParleProvider: Bool { Self.parleProviders.contains(self) }

    /// Models Parle recommends first; any model ID can still be typed in.
    /// Models shown in the Engine page's picker: readable name, full ID, and a short note.
    var recommendedModels: [(id: String, name: String, note: String)] {
        switch self {
        case .anthropic:
            return [
                ("claude-haiku-4-5", "Claude Haiku 4.5", "Fastest, best for cleanup"),
                ("claude-sonnet-5-5", "Claude Sonnet 5.5", "Smarter rewrites"),
                ("claude-opus-5-5", "Claude Opus 5.5", "Most capable, slowest"),
            ]
        case .openAI:
            return [
                ("gpt-5.4-mini", "GPT-5.4 mini", "Fast and cheap"),
                ("gpt-6-luna", "GPT-6 Luna", "Latest default"),
                ("gpt-4.1-mini", "GPT-4.1 mini", "Reliable, low latency"),
            ]
        case .openRouter:
            // Order from a benchmark on real Parle cleanup requests (Oct 2026).
            return [
                ("google/gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite", "Fast, keeps your words"),
                ("openai/gpt-oss-120b", "GPT OSS 120B", "Fastest, may reword"),
                ("google/gemini-3.5-flash", "Gemini 3.5 Flash", "Slower, thinks first"),
                ("anthropic/claude-haiku-4.5", "Claude Haiku 4.5", "Careful edits"),
            ]
        case .appleIntelligence:
            return [(ParleAppleModel.modelName, "Apple on-device", "On this Mac, private, no key")]
        default:
            return []
        }
    }
}
