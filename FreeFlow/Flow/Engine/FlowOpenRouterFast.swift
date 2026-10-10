import Foundation
import LLMkit
import os

/// OpenRouter cleanup over one long-lived connection.
///
/// LLMkit opens a fresh ephemeral URLSession for every request, so each cleanup paid a new
/// DNS + TCP + TLS handshake to openrouter.ai before the model even saw the text. This client
/// keeps a single session (HTTP/2, keep-alive) and warms it the moment the key goes down, so
/// by the time the person lets go the connection is already open. Same request body as
/// LLMkit's `OpenRouterClient.chatCompletion`.
enum FlowOpenRouterFast {
    struct Completion: Sendable {
        let text: String
        let provider: String?
        let finishReason: String?
    }

    private static let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "CleanupTiming")

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    private static let warmLock = OSAllocatedUnfairLock(initialState: Date.distantPast)

    /// Opens (or refreshes) the connection to openrouter.ai. Cheap: an unauthenticated HEAD
    /// that carries no text. Skipped when a request went out in the last 20 s.
    static func prewarm() {
        let now = Date()
        let shouldWarm = warmLock.withLock { last -> Bool in
            guard now.timeIntervalSince(last) > 20 else { return false }
            last = now
            return true
        }
        guard shouldWarm else { return }
        var request = URLRequest(url: OpenRouterClient.modelsURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        Task.detached(priority: .userInitiated) {
            let started = Date()
            _ = try? await session.data(for: request)
            logger.notice("prewarm \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms")
        }
    }

    static func chatCompletion(
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        systemPrompt: String?,
        temperature: Double?,
        reasoning: OpenRouterReasoning?,
        provider: OpenRouterProviderPreferences?,
        appTitle: String?,
        timeout: TimeInterval
    ) async throws -> Completion {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMKitError.missingAPIKey
        }
        var allMessages = messages
        if let systemPrompt, !systemPrompt.isEmpty {
            allMessages.insert(.system(systemPrompt), at: 0)
        }
        let body = RequestBody(
            model: model,
            messages: allMessages,
            temperature: temperature,
            reasoning: reasoning,
            provider: provider
        )

        var request = URLRequest(url: OpenRouterClient.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("enabled", forHTTPHeaderField: "X-OpenRouter-Metadata")
        if let appTitle, !appTitle.isEmpty {
            request.setValue(appTitle, forHTTPHeaderField: "X-OpenRouter-Title")
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw LLMKitError.encodingError
        }

        warmLock.withLock { $0 = Date() }
        await FlowStopLatency.mark("cleanupSent")
        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
            throw LLMKitError.timeout
        } catch {
            throw LLMKitError.networkError(error.localizedDescription)
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        await FlowStopLatency.mark("cleanupBack")

        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.networkError("No HTTP response received.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            throw LLMKitError.httpError(statusCode: http.statusCode, message: message ?? "No error details")
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw LLMKitError.noResultReturned
        }
        guard let choice = decoded.choices.first,
            let text = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            throw LLMKitError.noResultReturned
        }
        logger.notice("cleanup \(elapsed, privacy: .public)ms provider=\(decoded.provider ?? "?", privacy: .public)")
        return Completion(text: text, provider: decoded.provider, finishReason: choice.finishReason)
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let stream = false
        let reasoning: OpenRouterReasoning?
        let provider: OpenRouterProviderPreferences?
    }

    private struct ResponseBody: Decodable {
        let provider: String?
        let choices: [Choice]

        struct Choice: Decodable {
            let message: Message
            let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }

        struct Message: Decodable {
            let content: String?
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: Inner
        struct Inner: Decodable { let message: String }
    }
}
