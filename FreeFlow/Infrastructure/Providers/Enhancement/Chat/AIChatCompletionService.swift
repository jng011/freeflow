import Foundation
import LLMkit

struct AIChatCompletionResult: Sendable {
    let text: String
    let openRouterCompletion: OpenRouterCompletion?
}

extension AIService {
    func performChatCompletion(
        provider: AIProvider,
        modelName: String?,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        localUserPrompt: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> AIChatCompletionResult {
        let resolvedModel = modelName?.isEmpty == false ? modelName! : selectedModel(for: provider)

        let result: String
        let openRouterCompletion: OpenRouterCompletion? = nil
        switch provider {
        case .anthropic:
            result = try await AnthropicLLMClient.chatCompletion(
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                timeout: timeout
            )
        case .openRouter:
            let policy = OpenRouterRequestPolicy.lowLatency(
                modelName: resolvedModel,
                modelMetadata: openRouterModelMetadata(for: resolvedModel)
            )
            // Kept-alive connection (warmed at key down) instead of LLMkit's per-request session.
            let completion = try await FlowOpenRouterFast.chatCompletion(
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: policy.model,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: policy.temperature,
                reasoning: policy.reasoning,
                provider: policy.provider,
                appTitle: "Free Flow",
                timeout: timeout
            )
            guard !OpenRouterRequestPolicy.outputWasTruncated(finishReason: completion.finishReason) else {
                throw EnhancementError.outputTruncated
            }
            result = completion.text
        case .openAI:
            guard let baseURL = URL(string: provider.baseURL) else { throw EnhancementError.notConfigured }
            result = try await OpenAILLMClient.chatCompletion(
                baseURL: baseURL,
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: 0.3,
                // GPT-5 and later reason by default; cleanup wants the fast path.
                reasoningEffort: resolvedModel.hasPrefix("gpt-4") ? nil : "none",
                timeout: timeout
            )
        case .custom:
            guard
                let customConfiguration = CustomAIProviderManager.shared.requestConfiguration(forModel: resolvedModel),
                let baseURL = URL(string: customConfiguration.baseURL)
            else {
                throw EnhancementError.notConfigured
            }
            result = try await OpenAILLMClient.chatCompletion(
                baseURL: baseURL,
                apiKey: customConfiguration.apiKey,
                model: customConfiguration.modelName,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: 0.3,
                timeout: timeout
            )
        case .appleIntelligence:
            result = try await ParleAppleModel.respond(
                systemPrompt: systemPrompt,
                userPrompt: localUserPrompt ?? chatPrompt(from: messages)
            )
        }

        return AIChatCompletionResult(text: result, openRouterCompletion: openRouterCompletion)
    }

    func completeChat(
        provider: AIProvider,
        modelName: String?,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        let completion = try await performChatCompletion(
            provider: provider,
            modelName: modelName,
            messages: messages,
            systemPrompt: systemPrompt,
            timeout: timeout
        )
        let result = completion.text
        let filteredResult = AIEnhancementOutputFilter.filter(result)
        guard provider != .openRouter || !filteredResult.isEmpty else {
            throw EnhancementError.enhancementFailed
        }
        return filteredResult
    }

    private func chatAPIKey(for provider: AIProvider, modelName: String) throws -> String {
        if provider == .custom {
            guard let customConfiguration = CustomAIProviderManager.shared.requestConfiguration(forModel: modelName)
            else {
                throw EnhancementError.notConfigured
            }
            return customConfiguration.apiKey
        }

        guard let key = APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue), !key.isEmpty else {
            throw EnhancementError.notConfigured
        }
        return key
    }

    private func chatPrompt(from messages: [ChatMessage]) -> String {
        let formattedMessages = messages.map { message in
            let label: String
            switch message.role {
            case "assistant":
                label = "assistant"
            case "user":
                label = "user"
            case "system":
                label = "system"
            default:
                label = "other"
            }
            return """
                <message role="\(label)">
                \(message.content)
                </message>
                """
        }
        .joined(separator: "\n\n")

        return """
            <conversation>
            \(formattedMessages)
            </conversation>
            """
    }
}
