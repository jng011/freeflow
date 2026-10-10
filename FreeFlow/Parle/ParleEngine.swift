import Combine
import Foundation
import OSLog

// MARK: - Device profile

/// Which kind of Mac Parle is running on. Hard-coded for the two Macs Parle
/// ships to today.
enum ParleDeviceProfile {
    /// Mom's Mac — M2 Max, 32 GB. Everything runs on this Mac.
    case onDevice
    /// Everything else (e.g. an 8 GB Mac) — transcribe on the server,
    /// fall back to Apple's built-in speech recognition.
    case standard

    static let current: ParleDeviceProfile = {
        let chip = sysctlString("machdep.cpu.brand_string") ?? ""
        let memory = sysctlUInt64("hw.memsize")
        if chip.contains("M2 Max") && memory >= 32 * 1_073_741_824 {
            return .onDevice
        }
        return .standard
    }()

    static var chipName: String { sysctlString("machdep.cpu.brand_string") ?? "Mac" }
    static var memoryGB: Int { Int(sysctlUInt64("hw.memsize") / 1_073_741_824) }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : 0
    }
}

// MARK: - Server

enum ParlePC {
    static let serverNameKey = "FlowServerName"
    /// The name the server gave when the invite was redeemed.
    static var displayName: String {
        let name = UserDefaults.standard.string(forKey: serverNameKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? "Server" : name
    }
    /// Fixed identity of the PC transcription model.
    static let modelID = UUID(uuidString: "5041524C-4500-4000-8000-000000000001")!
    static let modelSelectionKey = "Custom:\(modelID.uuidString)"
    /// Used before this Mac has a pass (redeeming an invite, requesting access).
    /// Every request is signed with this Mac's device key.
    static let defaultURLs = ["https://parle.hb9core.com"]

    /// Whisper takes base language codes: "en-US" -> "en".
    static func whisperLanguage(_ code: String) -> String {
        String(code.replacingOccurrences(of: "_", with: "-").split(separator: "-").first ?? Substring(code)).lowercased()
    }

    /// One session for every request, so the TLS connection to the PC stays warm
    /// between dictations instead of being renegotiated each time.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    static var model: CustomCloudModel {
        CustomCloudModel(
            id: modelID,
            name: "parle-pc",
            displayName: displayName,
            description: "Whisper large-v3 turbo on the server.",
            apiEndpoint: (ParlePassStore.current?.payload.urls.first ?? defaultURLs[0]) + "/v1/audio/transcriptions",
            modelName: "large-v3",
            isMultilingual: true,
            supportedLanguages: LanguageDictionary.forProvider(isMultilingual: true, provider: .custom)
        )
    }

    static func isPCModel(_ model: any TranscriptionModel) -> Bool {
        (model as? CustomCloudModel)?.id == modelID
    }

    /// Models contributed to the registry: the PC model exists only once this
    /// Mac holds a pass.
    static var registryModels: [any TranscriptionModel] {
        ParlePassStore.current == nil ? [] : [model]
    }

    static var urls: [String] {
        ParlePassStore.current?.payload.urls ?? defaultURLs
    }
}

// MARK: - Engine

/// The single switch that decides where dictation is transcribed.
@MainActor
final class ParleEngine: ObservableObject {
    static let shared = ParleEngine()

    enum Source: String, CaseIterable, Identifiable {
        case pc
        case thisMac
        var id: String { rawValue }
    }

    enum PCStatus: Equatable {
        case noPass
        case checking
        case online(latencyMs: Int)
        case offline
    }

    @Published var source: Source {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey)
            objectWillChangeDownstream()
        }
    }
    @Published private(set) var pcStatus: PCStatus = .noPass
    @Published private(set) var hasPass: Bool = ParlePassStore.current != nil
    /// The server stays hidden until an invite code is redeemed on this Mac.
    static let invitedKey = "FlowServerInvited"
    @Published private(set) var isInvited: Bool = UserDefaults.standard.bool(forKey: ParleEngine.invitedKey)
    @Published private(set) var serverName: String = ParlePC.displayName
    /// Anything about the server shows only with an invite or a pass.
    var serverVisible: Bool { isInvited || hasPass }
    /// Requester side: status of the access request.
    @Published private(set) var requestStatus: ParleAccessClient.RequestStatus =
        UserDefaults.standard.bool(forKey: "ParleAccessRequested") ? .pending : .none
    @Published var accessError: String?
    /// Limits and usage for this Mac's pass (from the PC).
    @Published private(set) var passInfo: ParleAccessClient.PassInfo?

    private static let sourceKey = "ParleTranscriptionSource"
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "Engine")
    private var healthTask: Task<Void, Never>?

    /// Whisper model used for on-device transcription on Mom's Mac.
    static let onDeviceWhisperModelName = "ggml-large-v3-turbo"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.sourceKey).flatMap(Source.init(rawValue:))
        switch ParleDeviceProfile.current {
        case .onDevice:
            source = stored ?? .thisMac
        case .standard:
            source = stored ?? (ParlePassStore.current != nil ? .pc : .thisMac)
        }
    }

    /// Model "This Mac" transcribes with. Chosen on the Engine page; defaults
    /// to the best fit for this hardware once downloaded, Apple Speech until then.
    @Published var localModelKey: String =
        UserDefaults.standard.string(forKey: "ParleLocalModel")
        ?? (ParleDeviceProfile.current == .onDevice ? ParleEngine.onDeviceWhisperModelName : "apple-speech")
    {
        didSet {
            UserDefaults.standard.set(localModelKey, forKey: "ParleLocalModel")
            refreshModels()
        }
    }

    var localModelSelectionKey: String { localModelKey }

    var localEngineName: String {
        let name = ParleLocalCatalog.option(forKey: localModelKey)?.title ?? "Apple Speech"
        return "\(name) on this Mac"
    }

    /// The model every mode transcribes with.
    var transcriptionSelectionKey: String {
        if source == .pc && hasPass { return ParlePC.modelSelectionKey }
        return localModelSelectionKey
    }

    var isUsingPC: Bool { source == .pc && hasPass }

    /// Mom's Mac: start downloading the on-device Whisper model in the
    /// background (during onboarding or on first launch). Apple Speech covers
    /// dictation until it finishes.
    static func prepareOnDeviceModelIfNeeded(whisperModelManager: WhisperModelManager) {
        guard ParleDeviceProfile.current == .onDevice else { return }
        let name = onDeviceWhisperModelName
        guard !whisperModelManager.availableModels.contains(where: { $0.name == name }),
            whisperModelManager.downloadProgress[name] == nil,
            let model = TranscriptionModelRegistry.models.first(where: { $0.name == name }) as? WhisperModel
        else { return }
        whisperModelManager.startDownload(model)
    }

    // Passes --------------------------------------------------------------------

    func installPass(code: String) throws {
        _ = try ParlePassStore.install(code: code)
        hasPass = true
        source = .pc
        refreshModels()
        checkPCNow()
    }

    func removePass() {
        ParlePassStore.remove()
        hasPass = false
        source = .thisMac
        pcStatus = .noPass
        refreshModels()
    }

    // Invites ------------------------------------------------------------------------

    /// Redeems an invite code, then asks for access in the same step.
    /// Returns nil on success, or what to tell the person.
    func redeemInvite(code: String, name: String) async -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter a code." }
        do {
            let name = try await ParleAccessClient.redeemInvite(trimmed)
            UserDefaults.standard.set(true, forKey: Self.invitedKey)
            UserDefaults.standard.set(name, forKey: ParlePC.serverNameKey)
            isInvited = true
            serverName = ParlePC.displayName
        } catch {
            if case ParlePCError.unreachable = error { return "Can’t connect right now. Try again in a bit." }
            return ParleAccessClient.detail(of: error) ?? "That code didn’t work."
        }
        await requestAccess(name: name)
        return accessError
    }

    private func clearInvite() {
        UserDefaults.standard.removeObject(forKey: Self.invitedKey)
        isInvited = false
    }

    // Access requests ---------------------------------------------------------------

    func requestAccess(name: String) async {
        accessError = nil
        do {
            try await ParleAccessClient.requestAccess(name: name)
            UserDefaults.standard.set(true, forKey: "ParleAccessRequested")
            requestStatus = .pending
        } catch {
            accessError = message(for: error)
        }
    }

    func refreshAccess() async {
        guard !hasPass, requestStatus != .none else { return }
        guard let (status, pass) = try? await ParleAccessClient.status() else { return }
        requestStatus = status
        if status == .approved, let pass {
            try? installPass(code: pass)
            UserDefaults.standard.removeObject(forKey: "ParleAccessRequested")
        }
        if status == .none || status == .denied {
            UserDefaults.standard.removeObject(forKey: "ParleAccessRequested")
        }
    }

    /// Heartbeat + limits. If the PC says the pass is over, drop it quietly.
    func pingPC() async {
        guard hasPass else { return }
        _ = await confirmAccess()
    }

    private var dictationAccessCheck: Task<Bool, Never>?

    /// Called the moment a dictation starts. Confirms with the PC that this Mac's
    /// pass is still valid while the person is still talking, so it adds no wait,
    /// and a revoked pass never uploads any audio.
    func beginDictationAccessCheck() {
        guard source == .pc, hasPass else {
            dictationAccessCheck = nil
            return
        }
        dictationAccessCheck = Task { await self.confirmAccess() }
    }

    /// Result of the check started with the dictation (true when none was needed).
    func dictationAccessAllowed() async -> Bool {
        guard let check = dictationAccessCheck else { return hasPass }
        return await check.value
    }

    /// False only when the PC says the pass is over. Network trouble returns true:
    /// the upload then fails over to this Mac on its own.
    private func confirmAccess() async -> Bool {
        do {
            passInfo = try await ParleAccessClient.ping()
            return true
        } catch ParlePCError.rejected(_, let body) {
            if body.contains("revoked") || body.contains("expired") || body.contains("limit") || body.contains("Invite") {
                accessEnded(reason: body.contains("limit") ? "You’ve used all your words." : "Your access to the server ended.")
                return false
            }
            return true
        } catch {
            return true
        }
    }

    /// Called when the PC refuses this Mac's pass (removed, expired, or out of words).
    func accessEnded(reason: String) {
        ParlePassStore.remove()
        hasPass = false
        passInfo = nil
        source = .thisMac
        pcStatus = .noPass
        requestStatus = .none
        accessError = reason
        UserDefaults.standard.removeObject(forKey: "ParleAccessRequested")
        clearInvite()
        refreshModels()
    }

    private func message(for error: Error) -> String {
        if case ParlePCError.unreachable = error { return "Can’t reach the server right now." }
        return error.localizedDescription
    }

    private func refreshModels() {
        NotificationCenter.default.post(name: .parleEngineDidChange, object: nil)
    }

    private func objectWillChangeDownstream() {
        NotificationCenter.default.post(name: .parleEngineDidChange, object: nil)
    }

    // Health ----------------------------------------------------------------------

    func startMonitoring() {
        guard healthTask == nil else { return }
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkPC()
                await self?.pingPC()
                await self?.refreshAccess()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    func checkPCNow() {
        Task { await checkPC() }
    }

    private func checkPC() async {
        guard hasPass else {
            pcStatus = .noPass
            return
        }
        if case .online = pcStatus {} else { pcStatus = .checking }
        for base in ParlePC.urls {
            guard let url = URL(string: base + "/health") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let start = Date()
            if let (_, response) = try? await ParlePC.session.data(for: request),
                (response as? HTTPURLResponse)?.statusCode == 200
            {
                pcStatus = .online(latencyMs: Int(Date().timeIntervalSince(start) * 1000))
                return
            }
        }
        pcStatus = .offline
    }
}

extension Notification.Name {
    static let parleEngineDidChange = Notification.Name("ParleEngineDidChange")
}

// MARK: - PC transcription (with fallback)

enum ParlePCError: LocalizedError {
    case unreachable
    case rejected(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unreachable: "The server isn’t reachable."
        case .rejected(let code, let message): "The server refused the request (\(code)): \(message)"
        case .badResponse: "The server sent an unexpected response."
        }
    }
}

/// Transcribes on the server with a Secure Enclave–signed request. If the PC
/// can't be reached, transcribes with Apple Speech on this Mac instead so a
/// dictation is never lost.
/// The PC's Whisper reads an initial prompt as a spelling hint, so dictionary words
/// (unusual names) come out right before cleanup ever sees them.
enum ParlePCVocabulary {
    private static let limit = 60

    @MainActor
    static func prompt(_ existing: String?) -> String? {
        if let existing, !existing.isEmpty { return existing }
        let entries = FlowDictionaryStore.shared.entries.sorted {
            if $0.isStarred != $1.isStarred { return $0.isStarred }
            return $0.frequencyUsed > $1.frequencyUsed
        }
        var seen = Set<String>()
        var words: [String] = []
        for entry in entries {
            let word = (entry.replacement ?? entry.phrase).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= 40, seen.insert(word.lowercased()).inserted else { continue }
            words.append(word)
            if words.count == limit { break }
        }
        return words.isEmpty ? nil : words.joined(separator: ", ") + "."
    }
}

final class ParlePCTranscriptionService: TranscriptionService {
    private let fallback: TranscriptionService
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "PCTranscription")

    init(fallback: TranscriptionService) {
        self.fallback = fallback
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        do {
            guard await ParleEngine.shared.dictationAccessAllowed() else {
                throw ParlePCError.rejected(403, "revoked")
            }
            let pcContext = TranscriptionRequestContext(
                language: context.language,
                prompt: await ParlePCVocabulary.prompt(context.prompt)
            )
            return try await transcribeOnPC(audioURL: audioURL, context: pcContext)
        } catch {
            logger.notice("PC transcription failed (\(error.localizedDescription, privacy: .public)); using Apple Speech")
            if case ParlePCError.rejected(_, let body) = error,
                body.contains("revoked") || body.contains("expired") || body.contains("limit") || body.contains("Invite")
            {
                await MainActor.run {
                    ParleEngine.shared.accessEnded(
                        reason: body.contains("limit") ? "You’ve used all your words." : "Your access to the server ended.")
                }
            }
            // Never fall back silently: a silent fallback once hid a PC bug for a day.
            await MainActor.run {
                NotificationManager.shared.showNotification(
                    title: String(localized: "The server didn’t answer, so this Mac transcribed it."),
                    type: .warning,
                    duration: 4.0
                )
            }
            guard
                let apple = TranscriptionModelRegistry.models.first(where: { $0.provider == .nativeApple })
            else { throw ParlePCError.unreachable }
            return try await fallback.transcribe(audioURL: audioURL, model: apple, context: context.scoped(to: apple))
        }
    }

    private func transcribeOnPC(audioURL: URL, context: TranscriptionRequestContext) async throws -> String {
        // Lossless FLAC: same transcript as the WAV, about 40% less to upload.
        let compressed = ParleAudioCompressor.flac(from: audioURL)
        let audio = try compressed ?? Data(contentsOf: audioURL)
        let filename = compressed == nil
            ? audioURL.lastPathComponent : audioURL.deletingPathExtension().lastPathComponent + ".flac"
        let headers = try ParlePassStore.authorizationHeaders(for: audio)
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = Self.multipart(audio: audio, filename: filename, boundary: boundary, context: context)

        var lastNetworkError: Error?
        for base in ParlePC.urls {
            guard let url = URL(string: base + "/v1/audio/transcriptions") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

            do {
                let (data, response) = try await ParlePC.session.upload(for: request, from: body)
                guard let http = response as? HTTPURLResponse else { throw ParlePCError.badResponse }
                guard (200...299).contains(http.statusCode) else {
                    throw ParlePCError.rejected(http.statusCode, String(data: data, encoding: .utf8) ?? "")
                }
                struct Reply: Decodable { let text: String }
                guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
                    throw ParlePCError.badResponse
                }
                return reply.text
            } catch let error as URLError {
                lastNetworkError = error
                continue
            }
        }
        logger.error("All PC URLs failed: \(String(describing: lastNetworkError), privacy: .public)")
        throw ParlePCError.unreachable
    }

    private static func multipart(audio: Data, filename: String, boundary: String, context: TranscriptionRequestContext)
        -> Data
    {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(filename.hasSuffix(".flac") ? "audio/flac" : "audio/wav")\r\n\r\n")
        body.append(audio)
        append("\r\n")
        field("model", "large-v3-turbo")
        field("response_format", "json")
        if let language = context.language, language != "auto", !language.isEmpty {
            field("language", ParlePC.whisperLanguage(language))
        }
        if let prompt = context.prompt, !prompt.isEmpty {
            field("prompt", prompt)
        }
        append("--\(boundary)--\r\n")
        return body
    }
}
