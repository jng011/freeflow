import Foundation
import os

/// Streams a dictation to the server while the person is still talking, so on
/// release only the last couple of seconds are left to transcribe.
///
/// Timings follow what production dictation apps use: audio is forwarded as it is
/// captured, the connection opens on key-down and is kept warm with a ping every
/// 4 s, and the stream is abandoned (the caller then uploads the whole recording)
/// if the PC goes quiet for 4 s before release or 2 s after it, falls more than
/// 2 s behind, or hasn't returned the final text within 4 s plus its lag.
final class ParlePCStream: @unchecked Sendable {
    private static let pingInterval: TimeInterval = 4
    private static let quietLimitBeforeRelease: TimeInterval = 4
    private static let quietLimitAfterRelease: TimeInterval = 2
    private static let maxServerLag: TimeInterval = 2
    private static let finalWait: TimeInterval = 4
    private static let bytesPerSecond: Double = 16_000 * 2

    private let queue = DispatchQueue(label: "com.jaydenghiyam.parle.stream")
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "PCStream")
    private var task: URLSessionWebSocketTask?
    private var pingTimer: DispatchSourceTimer?
    private var sentBytes = 0
    private var serverReceivedSeconds: Double = 0
    private var lastServerMessage = Date()
    private var released = false
    private(set) var failed = false
    private var finalText: String?
    private var finalTail: String?
    private var finalWaiters: [CheckedContinuation<String?, Never>] = []

    /// Called (off the main thread) with each stretch of text the PC locks in while
    /// the person is still talking, in order.
    var onLocked: (@Sendable (String) -> Void)?

    /// The part of the final text that was not delivered through `onLocked`.
    var tail: String? { queue.sync { finalTail } }

    /// Opens the signed connection. Audio sent before the handshake finishes is
    /// queued by URLSession and delivered once it's open.
    init?(language: String?, prompt: String?) {
        guard let pass = ParlePassStore.current,
            let base = pass.payload.urls.first ?? ParlePC.urls.first,
            var components = URLComponents(string: base + "/v1/stream"),
            let headers = try? ParleAccessClient.deviceHeaders("parle-stream")
        else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(pass.code, forHTTPHeaderField: "X-Parle-Pass")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        let task = ParlePC.session.webSocketTask(with: request)
        self.task = task
        task.resume()

        var start: [String: String] = ["type": "start"]
        if let language, language != "auto", !language.isEmpty { start["language"] = ParlePC.whisperLanguage(language) }
        if let prompt, !prompt.isEmpty { start["prompt"] = prompt }
        if let data = try? JSONSerialization.data(withJSONObject: start), let text = String(data: data, encoding: .utf8) {
            task.send(.string(text)) { [weak self] error in if error != nil { self?.fail("start") } }
        }
        receive()
        startPinging()
    }

    /// Called on the audio thread with 16 kHz mono 16-bit PCM.
    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.failed, !self.released, let task = self.task else { return }
            self.sentBytes += data.count
            task.send(.data(data)) { [weak self] error in if error != nil { self?.fail("send") } }
        }
    }

    /// Ends the dictation and waits for the PC's final text. Returns nil when the
    /// stream can't be trusted, so the caller falls back to uploading the file.
    func finish() async -> String? {
        let wait: TimeInterval = await withCheckedContinuation { continuation in
            queue.async {
                self.released = true
                guard !self.failed, self.healthy(afterRelease: false) else {
                    continuation.resume(returning: -1)
                    return
                }
                self.task?.send(.string(#"{"type":"end"}"#)) { [weak self] error in if error != nil { self?.fail("end") } }
                self.lastServerMessage = Date()
                continuation.resume(returning: Self.finalWait + self.lagSeconds)
            }
        }
        guard wait >= 0 else {
            close()
            return nil
        }

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queue.async {
                if let finalText = self.finalText { continuation.resume(returning: finalText); return }
                if self.failed { continuation.resume(returning: nil); return }
                self.finalWaiters.append(continuation)
                self.queue.asyncAfter(deadline: .now() + wait) { self.resolveWaiters(with: nil) }
            }
        }
        close()
        return text
    }

    func cancel() {
        queue.async { self.failed = true; self.resolveWaiters(with: nil) }
        close()
    }

    // MARK: - Internals (all on `queue`)

    private var lagSeconds: Double {
        max(0, Double(sentBytes) / Self.bytesPerSecond - serverReceivedSeconds)
    }

    private func healthy(afterRelease: Bool) -> Bool {
        let quietLimit = afterRelease ? Self.quietLimitAfterRelease : Self.quietLimitBeforeRelease
        let quiet = Date().timeIntervalSince(lastServerMessage)
        // Before any audio is acknowledged the PC has nothing to say yet.
        if sentBytes > 0 && serverReceivedSeconds > 0 && quiet > quietLimit { return false }
        return lagSeconds <= Self.maxServerLag + Self.finalWait
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure:
                    self.fail("receive")
                case .success(let message):
                    self.lastServerMessage = Date()
                    if case .string(let text) = message, let data = text.data(using: .utf8),
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    {
                        if json["type"] as? String == "ack", let received = json["received"] as? Double {
                            self.serverReceivedSeconds = received
                        } else if json["type"] as? String == "locked", let locked = json["text"] as? String {
                            if !locked.isEmpty { self.onLocked?(locked) }
                        } else if json["type"] as? String == "final" {
                            self.finalText = (json["text"] as? String) ?? ""
                            self.finalTail = json["tail"] as? String
                            self.resolveWaiters(with: self.finalText)
                            return
                        }
                    }
                    if !self.released && self.lagSeconds > Self.maxServerLag + 1 {
                        self.logger.notice("PC is \(self.lagSeconds, privacy: .public)s behind; will upload the file instead")
                    }
                    self.receive()
                }
            }
        }
    }

    private func startPinging() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, !self.failed else { return }
            self.task?.sendPing { [weak self] error in if error != nil { self?.fail("ping") } }
        }
        timer.resume()
        pingTimer = timer
    }

    private func fail(_ stage: String) {
        queue.async {
            guard !self.failed else { return }
            self.failed = true
            self.logger.notice("PC stream failed at \(stage, privacy: .public); falling back to file upload")
            self.resolveWaiters(with: self.finalText)
        }
    }

    private func resolveWaiters(with text: String?) {
        let waiters = finalWaiters
        finalWaiters.removeAll()
        waiters.forEach { $0.resume(returning: text) }
    }

    private func close() {
        queue.async {
            self.pingTimer?.cancel()
            self.pingTimer = nil
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
        }
    }
}

/// Cleans up text while the person is still talking, the way Free Flow formats
/// behind the transcriber: text the PC has locked in is buffered until it ends a
/// sentence and has enough words, then cleaned with the last ~500 characters of
/// already-cleaned text as fixed context. At release only the remainder is left.
/// Any failure turns it off for this dictation, and the normal full cleanup runs.
@MainActor
final class ParleLiveCleanup {
    typealias Cleaner = (_ text: String, _ preceding: String) async throws -> String

    private static let minimumWords = 12
    private static let contextCharacters = 500
    private static let finishTimeout: TimeInterval = 4

    private let cleaner: Cleaner
    private var pendingRaw = ""
    private var cleanedParts: [String] = []
    private var chain: Task<Void, Never>?
    private var failed = false

    init(cleaner: @escaping Cleaner) {
        self.cleaner = cleaner
    }

    func receive(_ locked: String) {
        guard !failed else { return }
        pendingRaw = pendingRaw.isEmpty ? locked : pendingRaw + " " + locked
        let trimmed = pendingRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WordCounter.count(in: trimmed) >= Self.minimumWords,
            let last = trimmed.last, ".?!".contains(last)
        else { return }
        let piece = trimmed
        pendingRaw = ""
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            guard let self, !self.failed else { return }
            let preceding = String(self.cleanedParts.joined(separator: " ").suffix(Self.contextCharacters))
            do {
                let cleaned = try await self.cleaner(piece, preceding)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty { self.failed = true } else { self.cleanedParts.append(cleaned) }
            } catch {
                self.failed = true
            }
        }
    }

    /// Waits briefly for in-flight cleanup. Returns the cleaned text so far and the
    /// raw text still to clean, or nil when the normal full cleanup should run.
    func finish(serverTail: String) async -> (cleanedPrefix: String, rawRemainder: String)? {
        if let chain {
            let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
                group.addTask { await chain.value; return true }
                group.addTask {
                    try? await Task.sleep(for: .seconds(Self.finishTimeout))
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !finished { failed = true }
        }
        guard !failed, !cleanedParts.isEmpty else { return nil }
        let remainder = [pendingRaw, serverTail]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return (cleanedParts.joined(separator: " "), remainder)
    }
}

/// Session used whenever the server is the transcription source: streams while
/// recording, and falls back to uploading the finished recording if the stream
/// can't deliver (which itself falls back to this Mac if the PC is unreachable).
@MainActor
final class ParlePCStreamingSession: TranscriptionSession {
    private let fileService: TranscriptionService
    private var model: (any TranscriptionModel)?
    private var context: TranscriptionRequestContext = .currentDefaults
    private var stream: ParlePCStream?
    private var liveCleanup: ParleLiveCleanup?
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "PCStreamingSession")

    /// Set by the engine when AI cleanup is on, before `prepare`; enables live cleanup.
    var liveCleaner: ParleLiveCleanup.Cleaner?

    init(fileService: TranscriptionService) {
        self.fileService = fileService
    }

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        model = configuration.model
        context = configuration.requestContext.scoped(to: configuration.model)
        let prompt = await ParlePCVocabulary.prompt(context.prompt)
        guard ParleEngine.shared.source == .pc, ParlePassStore.current != nil,
            let stream = ParlePCStream(language: context.language, prompt: prompt)
        else { return nil }
        self.stream = stream
        let live: ParleLiveCleanup? = liveCleaner.map { ParleLiveCleanup(cleaner: $0) }
        liveCleanup = live
        // The first words back from the PC decide the "Ask Siri" icon while still talking.
        let firstText = FirstLockedText()
        stream.onLocked = { [live] text in
            Task { @MainActor in
                live?.receive(text)
                guard firstText.take() else { return }
                // "x" stands in for the rest of the question, which may not have arrived yet.
                if FlowAskSiriCommand.isEnabled, FlowAskSiriCommand.question(in: text + " x") != nil {
                    FlowDictationState.shared.setModeBadge(.siri)
                }
            }
        }
        return { [stream] data in stream.send(data) }
    }

    private var finishTask: Task<String?, Never>?

    /// Sends "end" the moment recording stops, so the PC finishes the last words while the
    /// app saves the history row and checks access instead of after.
    func beginFinish() {
        guard finishTask == nil, let stream else { return }
        finishTask = Task { await stream.finish() }
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let model else { throw FreeFlowEngineError.transcriptionFailed }
        if let stream {
            let finished = finishTask ?? Task { await stream.finish() }
            finishTask = finished
            // The audio was already streamed while talking; the check only decides whether
            // the result is used.
            if await ParleEngine.shared.dictationAccessAllowed(), let text = await finished.value, !text.isEmpty {
                FlowStopLatency.mark("pcFinal")
                return text
            }
            logger.notice("Stream didn't deliver; uploading the recording instead")
        }
        return try await fileService.transcribe(audioURL: audioURL, model: model, context: context)
    }

    /// Cleaned-so-far text plus what's left to clean, when live cleanup kept up.
    func liveCleanupResult() async -> (cleanedPrefix: String, rawRemainder: String)? {
        guard let liveCleanup, let tail = stream?.tail else { return nil }
        return await liveCleanup.finish(serverTail: tail)
    }

    func cancel() {
        finishTask?.cancel()
        finishTask = nil
        stream?.cancel()
        stream = nil
        liveCleanup = nil
    }
}

/// True exactly once: the first stretch of text the PC locks in for a dictation.
@MainActor
private final class FirstLockedText {
    private var seen = false

    func take() -> Bool {
        defer { seen = true }
        return !seen
    }
}
