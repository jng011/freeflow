import Combine
import Foundation
import LLMkit

/// Who cleans up a dictation. Free Flow offers OpenRouter in Settings; the others stay
/// available to modes and Auto Learn.
enum AIProvider: String, CaseIterable {
    case openRouter = "OpenRouter"
    case anthropic = "Anthropic"
    case openAI = "OpenAI"
    case appleIntelligence = "Apple Intelligence"
    case custom = "Custom"

    var baseURL: String {
        switch self {
        case .openRouter: "https://openrouter.ai/api/v1/chat/completions"
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .openAI: "https://api.openai.com/v1/chat/completions"
        case .custom: UserDefaults.standard.string(forKey: "customProviderBaseURL") ?? ""
        case .appleIntelligence: ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: "google/gemini-3.5-flash-lite"
        case .anthropic: "claude-haiku-4-5"
        case .openAI: "gpt-6-luna"
        case .appleIntelligence: ParleAppleModel.modelName
        case .custom: CustomAIProviderManager.shared.defaultModelName
        }
    }

    /// Built-in model list. OpenRouter's comes from its live catalog instead.
    var availableModels: [String] {
        switch self {
        case .openRouter: []
        case .anthropic: ["claude-haiku-4-5", "claude-sonnet-5-5", "claude-opus-5-5"]
        case .openAI: ["gpt-6-luna", "gpt-6-sol", "gpt-5.6-luna", "gpt-5.5", "gpt-4.1-mini"]
        case .appleIntelligence: [ParleAppleModel.modelName]
        case .custom: CustomAIProviderManager.shared.availableModelNames
        }
    }

    var requiresAPIKey: Bool { self != .appleIntelligence }

    var supportsEnhancement: Bool { true }

    /// Any model ID can be typed in, not just the listed ones.
    var supportsCustomModelID: Bool { self == .openRouter || self == .anthropic || self == .openAI }
}

final class AIService: ObservableObject {
    @Published var selectedProvider: AIProvider {
        didSet {
            defaults.set(selectedProvider.rawValue, forKey: Self.providerKey)
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }

    @Published private var selectedModels: [AIProvider: String] = [:]
    @Published private var openRouterCatalog: [OpenRouterModel] = []
    private var isFetchingCatalog = false
    private let defaults = UserDefaults.standard
    private var observers: [NSObjectProtocol] = []

    private static let providerKey = "selectedAIProvider"
    private static func modelKey(_ provider: AIProvider) -> String { "\(provider.rawValue)SelectedModel" }

    init() {
        selectedProvider = defaults.string(forKey: Self.providerKey).flatMap(AIProvider.init(rawValue:)) ?? .openRouter
        for provider in AIProvider.allCases {
            if let model = defaults.string(forKey: Self.modelKey(provider)), !model.isEmpty {
                selectedModels[provider] = model
            }
        }
        openRouterCatalog = OpenRouterCatalogStore.shared.models(for: .enhancement) ?? []
        seedAutoLearnProvider()

        for name in [Notification.Name.aiProviderKeyChanged, .AppSettingsDidChange] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.seedAutoLearnProvider()
                })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Providers and models

    /// Providers that can clean up right now (a saved key, or on-device).
    var connectedProviders: [AIProvider] {
        AIProvider.allCases.filter { provider in
            switch provider {
            case .custom: CustomAIProviderManager.shared.hasConfiguredModels
            case .appleIntelligence: ParleAppleModel.isAvailable
            default: APIKeyManager.shared.hasAPIKey(forProvider: provider.rawValue)
            }
        }
    }

    var currentModel: String { selectedModel(for: selectedProvider) }

    var availableModels: [String] { availableModels(for: selectedProvider) }

    func availableModels(for provider: AIProvider) -> [String] {
        guard provider == .openRouter else { return provider.availableModels }
        let ids = openRouterCatalog.filter(Self.isTextModel).map(\.id)
        return ids.isEmpty ? OpenRouterCatalogStore.shared.legacyEnhancementModelIDs : ids
    }

    func selectedModel(for provider: AIProvider) -> String {
        if let model = selectedModels[provider], !model.isEmpty { return model }
        return provider.defaultModel
    }

    /// The typed-in model ID, if the selection isn't one of the built-in choices.
    func customModelID(for provider: AIProvider) -> String {
        guard provider.supportsCustomModelID else { return "" }
        if let saved = defaults.string(forKey: "\(provider.rawValue)CustomModelID"), !saved.isEmpty { return saved }
        let model = selectedModel(for: provider)
        return provider.availableModels.contains(model) ? "" : model
    }

    func selectModel(_ model: String) { selectModel(model, for: selectedProvider) }

    func selectModel(_ model: String, for provider: AIProvider) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        if provider == .custom, !CustomAIProviderManager.shared.applyConfiguration(forModel: model) { return }
        selectedModels[provider] = model
        defaults.set(model, forKey: Self.modelKey(provider))
        if provider.supportsCustomModelID, !provider.availableModels.contains(model) {
            defaults.set(model, forKey: "\(provider.rawValue)CustomModelID")
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    // MARK: Keys

    func verifyAPIKey(_ key: String, for provider: AIProvider, model: String? = nil) async -> (
        isValid: Bool, errorMessage: String?
    ) {
        switch provider {
        case .openRouter: await OpenRouterClient.verifyAPIKey(key)
        case .anthropic: await AnthropicLLMClient.verifyAPIKey(key)
        case .openAI: await OpenAILLMClient.verifyAPIKey(key)
        case .appleIntelligence: (true, nil)
        case .custom:
            if let url = URL(string: provider.baseURL) {
                await OpenAILLMClient.verifyAPIKey(baseURL: url, apiKey: key, model: model ?? selectedModel(for: .custom))
            } else {
                (false, "Invalid or missing base URL configuration")
            }
        }
    }

    // MARK: OpenRouter catalog

    func openRouterModelMetadata(for modelName: String) -> OpenRouterModel? {
        openRouterCatalog.first { $0.id == modelName }
    }

    @MainActor
    func fetchOpenRouterModelsIfNeededForMigration() async {
        guard openRouterCatalog.isEmpty, APIKeyManager.shared.hasAPIKey(forProvider: AIProvider.openRouter.rawValue)
        else { return }
        await fetchOpenRouterModels()
    }

    /// Refreshes the catalog. A failed fetch keeps the last good list.
    @MainActor
    func fetchOpenRouterModels() async {
        guard !isFetchingCatalog else { return }
        isFetchingCatalog = true
        defer { isFetchingCatalog = false }
        guard let catalog = try? await OpenRouterClient.fetchModelCatalog(), !catalog.isEmpty else { return }
        openRouterCatalog = catalog
        try? OpenRouterCatalogStore.shared.save(catalog, for: .enhancement)
        OpenRouterCatalogStore.shared.saveLegacyEnhancementModelIDs(catalog.filter(Self.isTextModel).map(\.id))
        if let selected = selectedModels[.openRouter], !availableModels(for: .openRouter).contains(selected) {
            selectModel(AIProvider.openRouter.defaultModel, for: .openRouter)
        }
    }

    private static func isTextModel(_ model: OpenRouterModel) -> Bool {
        guard let architecture = model.architecture else { return true }
        return architecture.inputModalities.contains("text") && architecture.outputModalities.contains("text")
    }

    // MARK: Auto Learn

    func reviewAutoLearnCandidates(
        payload: String, systemPrompt: String, provider: AIProvider, modelName: String?
    ) async throws -> String {
        guard AutoLearnProviderPolicy.isSupported(provider) else { throw EnhancementError.notConfigured }
        return try await performChatCompletion(
            provider: provider, modelName: modelName, messages: [.user(payload)], systemPrompt: systemPrompt,
            localUserPrompt: payload, timeout: EnhancementRequestSettings.timeout
        ).text
    }

    /// Gives Auto Learn a provider the first time one is connected.
    private func seedAutoLearnProvider() {
        if let current = AutoLearnSettings.selectedProvider, AutoLearnProviderPolicy.isSupported(current) { return }
        let usable = connectedProviders.filter(AutoLearnProviderPolicy.isSupported)
        guard let provider = usable.contains(selectedProvider) ? selectedProvider : usable.first else { return }
        AutoLearnSettings.initializeSelectionIfNeeded(provider: provider, model: selectedModel(for: provider))
    }
}
