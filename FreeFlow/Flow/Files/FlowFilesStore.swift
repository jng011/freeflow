import AppKit
import Foundation
import SwiftData
import os

extension Notification.Name {
    /// Posted by AudioTranscriptionManager when a queue item finishes.
    /// userInfo: ["itemID": UUID, "transcriptionID": UUID?, "error": String?]
    static let flowFileTranscriptionFinished = Notification.Name("FlowFileTranscriptionFinished")
}

enum FlowFileOrigin: String, Codable { case user, mcp }

struct FlowFileResult: Codable {
    let transcriptionID: UUID
    let text: String
    let rawText: String
    let duration: TimeInterval
}

struct FlowFileJob: Codable, Identifiable {
    let id: UUID
    var filename: String
    var sourcePath: String
    var transcriptionID: UUID?
    var origin: FlowFileOrigin
    var addedAt: Date
    var finishedAt: Date?
    var status: String  // pending|processing|completed|failed|canceled
    var errorMessage: String?
    var cleanup: Bool
    /// Media length in seconds, once known.
    var audioDuration: TimeInterval? = nil
    /// Source file size in bytes, captured at enqueue time.
    var fileSize: Int64? = nil
}

extension FlowFileJob {
    enum Status {
        static let pending = "pending"
        static let processing = "processing"
        static let completed = "completed"
        static let failed = "failed"
        static let canceled = "canceled"
    }

    var isActive: Bool { status == Status.pending || status == Status.processing }
    var isFinished: Bool { !isActive }
    var isCompleted: Bool { status == Status.completed }
    var isFailed: Bool { status == Status.failed }
    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
}

enum FlowFilesError: LocalizedError {
    case unsupported(String)
    case missingFile(String)
    case canceled
    case transcriptionMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): return "\(name) isn't an audio or video file"
        case .missingFile(let name): return "\(name) could not be found"
        case .canceled: return "Canceled"
        case .transcriptionMissing: return "The transcript could not be found"
        case .failed(let message): return message
        }
    }
}

@MainActor
final class FlowFilesStore: ObservableObject {
    static let shared = FlowFilesStore()

    @Published private(set) var jobs: [FlowFileJob] = []
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var phaseText: [UUID: String] = [:]
    @Published private(set) var transcriptionIDs: Set<UUID> = []

    // MARK: - Private state

    private struct ExternalHandlers {
        let progress: (Double, String) -> Void
        let completion: (Result<FlowFileResult, Error>) -> Void
    }

    private static let maxJobs = 200
    private static let longFileThreshold: TimeInterval = 2 * 60 * 60

    private weak var engine: FreeFlowEngine?
    private var modelContext: ModelContext?
    private var isConfigured = false
    private var didLoad = false

    /// Manager queue item id -> job id, and back.
    private var itemToJob: [UUID: UUID] = [:]
    private var jobToItem: [UUID: UUID] = [:]
    private var externalHandlers: [UUID: ExternalHandlers] = [:]
    private var archivedIDs: Set<UUID> = []
    private var longFileWarned: Set<UUID> = []

    private var tickTimer: Timer?
    private var finishedObserver: NSObjectProtocol?
    private let ioQueue = DispatchQueue(label: "com.jaydenghiyam.FreeFlow.files-io", qos: .utility)
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowFilesStore")

    private var manager: AudioTranscriptionManager { AudioTranscriptionManager.shared }

    private var jobsFileURL: URL { FlowPaths.file("flow-files-jobs.json") }
    private var idsFileURL: URL { FlowPaths.file("flow-files-ids.json") }

    private init() {
        loadFromDisk()
    }

    // MARK: - Configuration

    func configure(engine: FreeFlowEngine, modelContext: ModelContext) {
        self.engine = engine
        self.modelContext = modelContext

        if !isConfigured {
            isConfigured = true
            finishedObserver = NotificationCenter.default.addObserver(
                forName: .flowFileTranscriptionFinished,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let itemID = note.userInfo?["itemID"] as? UUID
                let transcriptionID = note.userInfo?["transcriptionID"] as? UUID
                let error = note.userInfo?["error"] as? String
                MainActor.assumeIsolated {
                    guard let self, let itemID else { return }
                    self.handleFinished(itemID: itemID, transcriptionID: transcriptionID, error: error)
                }
            }
        }

        startProcessingIfNeeded()
    }

    // MARK: - Public API

    @discardableResult
    func enqueue(urls: [URL], origin: FlowFileOrigin = .user, cleanup: Bool = true) -> [UUID] {
        var created: [UUID] = []
        for url in urls {
            if let id = addJob(id: UUID(), url: url, origin: origin, cleanup: cleanup, notifyUser: true) {
                created.append(id)
            }
        }
        if !created.isEmpty {
            saveJobs()
            startProcessingIfNeeded()
            updateTimer()
        }
        return created
    }

    func enqueueExternal(
        jobID: UUID,
        url: URL,
        cleanup: Bool,
        progress: @escaping (Double, String) -> Void,
        completion: @escaping (Result<FlowFileResult, Error>) -> Void
    ) {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(.failure(FlowFilesError.missingFile(name)))
            return
        }
        guard SupportedMedia.isSupported(url: url) else {
            completion(.failure(FlowFilesError.unsupported(name)))
            return
        }

        // Same path already queued: attach to that job instead of failing.
        if let existing = activeJob(forPath: url.standardizedFileURL.path) {
            guard externalHandlers[existing.id] == nil else {
                completion(.failure(FlowFilesError.failed("\(name) is already being transcribed")))
                return
            }
            externalHandlers[existing.id] = ExternalHandlers(progress: progress, completion: completion)
            return
        }

        guard addJob(id: jobID, url: url, origin: .mcp, cleanup: cleanup, notifyUser: false) != nil else {
            completion(.failure(FlowFilesError.failed("The file could not be added to the queue")))
            return
        }
        externalHandlers[jobID] = ExternalHandlers(progress: progress, completion: completion)
        progress(0, FlowFileProgressEstimator.phaseText(.pending))
        saveJobs()
        startProcessingIfNeeded()
        updateTimer()
    }

    func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].isActive else { return }

        if let itemID = jobToItem[jobID], let item = manager.queue.first(where: { $0.id == itemID }) {
            switch item.status {
            case .pending:
                manager.removeFromQueue(id: itemID)
            case .processing:
                manager.cancelProcessing()
                // cancelProcessing resets the current item to pending; drop it so it is not picked up again.
                manager.removeFromQueue(id: itemID)
            case .completed, .failed:
                break
            }
            unmap(jobID: jobID)
        }

        jobs[index].status = FlowFileJob.Status.canceled
        jobs[index].finishedAt = Date()
        jobs[index].errorMessage = nil
        progress[jobID] = nil
        phaseText[jobID] = "Canceled"
        finishExternal(jobID: jobID, result: .failure(FlowFilesError.canceled))
        saveJobs()

        startProcessingIfNeeded()
        updateTimer()
    }

    func retry(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), !jobs[index].isActive else { return }
        let job = jobs[index]

        if let itemID = jobToItem[jobID],
            let item = manager.queue.first(where: { $0.id == itemID }),
            case .failed = item.status
        {
            item.skipEnhancement = !job.cleanup
            manager.retryItem(id: itemID)
        } else {
            unmap(jobID: jobID)
            guard FileManager.default.fileExists(atPath: job.sourcePath) else {
                jobs[index].status = FlowFileJob.Status.failed
                jobs[index].errorMessage = FlowFilesError.missingFile(job.filename).localizedDescription
                phaseText[jobID] = jobs[index].errorMessage
                saveJobs()
                return
            }
            guard let item = addManagerItem(url: job.sourceURL) else {
                FlowToastCenter.shared.show("\(job.filename) is already in the queue", style: .info)
                return
            }
            map(itemID: item.id, jobID: jobID)
            item.skipEnhancement = !job.cleanup
        }

        jobs[index].status = FlowFileJob.Status.pending
        jobs[index].errorMessage = nil
        jobs[index].finishedAt = nil
        jobs[index].transcriptionID = nil
        progress[jobID] = 0
        phaseText[jobID] = FlowFileProgressEstimator.phaseText(.pending)
        saveJobs()
        startProcessingIfNeeded()
        updateTimer()
    }

    func remove(jobID: UUID) {
        if let job = jobs.first(where: { $0.id == jobID }), job.isActive {
            cancel(jobID: jobID)
        }
        jobs.removeAll { $0.id == jobID }
        progress[jobID] = nil
        phaseText[jobID] = nil
        unmap(jobID: jobID)
        saveJobs()
    }

    func clearFinished() {
        let finished = jobs.filter(\.isFinished).map(\.id)
        guard !finished.isEmpty else { return }
        jobs.removeAll { $0.isFinished }
        for id in finished {
            progress[id] = nil
            phaseText[id] = nil
            unmap(jobID: id)
        }
        saveJobs()
    }

    // MARK: - Helpers for the page

    /// Fetches the stored transcription for a completed job.
    func transcription(for job: FlowFileJob) -> Transcription? {
        guard let id = job.transcriptionID else { return nil }
        return fetchTranscription(id: id)
    }

    /// The text shown and copied for a completed job: cleaned text when available, else the original.
    func displayText(for job: FlowFileJob) -> String? {
        guard let transcription = transcription(for: job) else { return nil }
        return Self.bestText(for: transcription)
    }

    static func bestText(for transcription: Transcription) -> String {
        if let enhanced = transcription.enhancedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !enhanced.isEmpty
        {
            return enhanced
        }
        return transcription.text
    }

    /// The converted 16 kHz WAV kept in Recordings, if it still exists.
    func audioURL(for job: FlowFileJob) -> URL? {
        guard let transcription = transcription(for: job),
            let string = transcription.audioFileURL,
            let url = URL(string: string),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    // MARK: - Job creation

    private func activeJob(forPath path: String) -> FlowFileJob? {
        jobs.first { $0.isActive && URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path == path }
    }

    /// Creates a job and its manager item. Returns the job id, or nil when skipped.
    private func addJob(id: UUID, url: URL, origin: FlowFileOrigin, cleanup: Bool, notifyUser: Bool) -> UUID? {
        let name = url.lastPathComponent
        guard SupportedMedia.isSupported(url: url) else {
            if notifyUser { FlowToastCenter.shared.show("\(name) isn't an audio or video file", style: .error) }
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            if notifyUser { FlowToastCenter.shared.show("\(name) could not be found", style: .error) }
            return nil
        }
        let path = url.standardizedFileURL.path
        // Duplicate drop of a file that is still waiting or running: ignore.
        if activeJob(forPath: path) != nil { return nil }

        guard let item = addManagerItem(url: url) else { return nil }
        item.skipEnhancement = !cleanup

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) }
        let job = FlowFileJob(
            id: id,
            filename: name,
            sourcePath: path,
            transcriptionID: nil,
            origin: origin,
            addedAt: Date(),
            finishedAt: nil,
            status: FlowFileJob.Status.pending,
            errorMessage: nil,
            cleanup: cleanup,
            audioDuration: nil,
            fileSize: size
        )
        jobs.append(job)
        map(itemID: item.id, jobID: id)
        progress[id] = 0
        phaseText[id] = FlowFileProgressEstimator.phaseText(.pending)
        return id
    }

    private func addManagerItem(url: URL) -> AudioFileQueueItem? {
        let before = Set(manager.queue.map(\.id))
        manager.addToQueue(urls: [url])
        return manager.queue.last(where: { !before.contains($0.id) })
    }

    private func map(itemID: UUID, jobID: UUID) {
        itemToJob[itemID] = jobID
        jobToItem[jobID] = itemID
        manager.queue.first(where: { $0.id == itemID })?.jobID = jobID
    }

    private func unmap(jobID: UUID) {
        if let itemID = jobToItem.removeValue(forKey: jobID) {
            itemToJob[itemID] = nil
        }
    }

    // MARK: - Processing

    private func startProcessingIfNeeded() {
        guard let engine, let modelContext else { return }
        guard !manager.isProcessingQueue, manager.hasPendingItems else { return }
        let modeManager = ModeManager.shared
        guard
            let mode = modeManager.currentEffectiveConfiguration
                ?? modeManager.getDefaultConfiguration()
                ?? modeManager.configurations.first
        else {
            failAllPending(message: "No transcription mode is set up")
            return
        }
        manager.startProcessing(modelContext: modelContext, engine: engine, mode: mode)
        updateTimer()
    }

    private func failAllPending(message: String) {
        for index in jobs.indices where jobs[index].isActive {
            let jobID = jobs[index].id
            if let itemID = jobToItem[jobID] { manager.removeFromQueue(id: itemID) }
            unmap(jobID: jobID)
            jobs[index].status = FlowFileJob.Status.failed
            jobs[index].errorMessage = message
            jobs[index].finishedAt = Date()
            progress[jobID] = nil
            phaseText[jobID] = message
            finishExternal(jobID: jobID, result: .failure(FlowFilesError.failed(message)))
        }
        saveJobs()
        updateTimer()
    }

    private func handleFinished(itemID: UUID, transcriptionID: UUID?, error: String?) {
        if let transcriptionID {
            // Always remember file transcription ids so they never show in dictation history.
            insertTranscriptionID(transcriptionID)
        }
        guard let jobID = itemToJob[itemID], let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        // A late result for a job the user already canceled: keep it canceled.
        guard jobs[index].isActive else { return }

        if let item = manager.queue.first(where: { $0.id == itemID }), let duration = item.audioDuration {
            jobs[index].audioDuration = duration
        }
        jobs[index].finishedAt = Date()

        if let transcriptionID {
            jobs[index].status = FlowFileJob.Status.completed
            jobs[index].transcriptionID = transcriptionID
            jobs[index].errorMessage = nil
            progress[jobID] = 1
            phaseText[jobID] = FlowFileProgressEstimator.phaseText(.completed)
            externalHandlers[jobID]?.progress(1, FlowFileProgressEstimator.phaseText(.completed))

            if let transcription = fetchTranscription(id: transcriptionID) {
                let result = FlowFileResult(
                    transcriptionID: transcriptionID,
                    text: Self.bestText(for: transcription),
                    rawText: transcription.text,
                    duration: transcription.duration
                )
                finishExternal(jobID: jobID, result: .success(result))
            } else {
                finishExternal(jobID: jobID, result: .failure(FlowFilesError.transcriptionMissing))
            }
        } else {
            let message = error ?? "Transcription failed"
            jobs[index].status = FlowFileJob.Status.failed
            jobs[index].errorMessage = message
            progress[jobID] = nil
            phaseText[jobID] = message
            finishExternal(jobID: jobID, result: .failure(FlowFilesError.failed(message)))
        }

        saveJobs()
        updateTimer()
    }

    private func finishExternal(jobID: UUID, result: Result<FlowFileResult, Error>) {
        guard let handlers = externalHandlers.removeValue(forKey: jobID) else { return }
        handlers.completion(result)
    }

    private func fetchTranscription(id: UUID) -> Transcription? {
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    // MARK: - Progress ticking

    private var hasActiveJobs: Bool { jobs.contains(where: \.isActive) }

    private func updateTimer() {
        if hasActiveJobs {
            guard tickTimer == nil else { return }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
            tick()
        } else {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func tick() {
        let usingPC = ParleEngine.shared.isUsingPC
        let now = Date()
        var statusChanged = false

        for index in jobs.indices where jobs[index].isActive {
            let jobID = jobs[index].id
            guard let itemID = jobToItem[jobID],
                let item = manager.queue.first(where: { $0.id == itemID })
            else { continue }

            if let duration = item.audioDuration, jobs[index].audioDuration != duration {
                jobs[index].audioDuration = duration
                statusChanged = true
                if duration > Self.longFileThreshold, !longFileWarned.contains(jobID) {
                    longFileWarned.insert(jobID)
                    FlowToastCenter.shared.show("Long file, this may take a while", style: .info)
                }
            }

            guard let phase = FlowFileProgressEstimator.phase(for: item.status) else { continue }

            if case .processing = item.status, jobs[index].status != FlowFileJob.Status.processing {
                jobs[index].status = FlowFileJob.Status.processing
                statusChanged = true
            }

            let elapsed = now.timeIntervalSince(item.phaseStartedAt ?? now)
            let estimate = FlowFileProgressEstimator.progress(
                phase: phase,
                elapsed: elapsed,
                audioDuration: item.audioDuration,
                usingPC: usingPC
            )
            // Never move backwards.
            let value = max(progress[jobID] ?? 0, estimate)
            if progress[jobID] != value { progress[jobID] = value }
            let text = FlowFileProgressEstimator.phaseText(phase)
            if phaseText[jobID] != text { phaseText[jobID] = text }
            externalHandlers[jobID]?.progress(value, text)
        }

        if statusChanged { saveJobs() }
        // The manager loop may have stopped while jobs are still pending (for example after a cancel).
        if !manager.isProcessingQueue, manager.hasPendingItems { startProcessingIfNeeded() }
        if !hasActiveJobs { updateTimer() }
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard !didLoad else { return }
        didLoad = true

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: idsFileURL),
            let ids = try? decoder.decode([UUID].self, from: data)
        {
            archivedIDs = Set(ids)
        }

        if let data = try? Data(contentsOf: jobsFileURL) {
            do {
                jobs = try decoder.decode([FlowFileJob].self, from: data)
            } catch {
                logger.error("Could not read Files jobs: \(error.localizedDescription, privacy: .public)")
                jobs = []
            }
        }

        // Anything still running when the app quit cannot resume.
        var changed = false
        for index in jobs.indices where jobs[index].isActive {
            jobs[index].status = FlowFileJob.Status.failed
            jobs[index].errorMessage = "Interrupted"
            jobs[index].finishedAt = jobs[index].finishedAt ?? Date()
            phaseText[jobs[index].id] = "Interrupted"
            changed = true
        }

        recomputeTranscriptionIDs()
        if changed { saveJobs() }
    }

    private func insertTranscriptionID(_ id: UUID) {
        guard !archivedIDs.contains(id) else { return }
        archivedIDs.insert(id)
        recomputeTranscriptionIDs()
        let ids = Array(archivedIDs)
        let url = idsFileURL
        ioQueue.async {
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(ids) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func recomputeTranscriptionIDs() {
        let fromJobs = Set(jobs.compactMap(\.transcriptionID))
        let combined = archivedIDs.union(fromJobs)
        if combined != transcriptionIDs { transcriptionIDs = combined }
    }

    private func saveJobs() {
        if jobs.count > Self.maxJobs {
            // Keep the most recent jobs; never drop active ones.
            let sorted = jobs.sorted { $0.addedAt > $1.addedAt }
            var keep = Set(sorted.prefix(Self.maxJobs).map(\.id))
            for job in jobs where job.isActive { keep.insert(job.id) }
            jobs.removeAll { !keep.contains($0.id) }
        }
        // Make sure every id ever produced stays excluded after jobs are cleared.
        for id in jobs.compactMap(\.transcriptionID) where !archivedIDs.contains(id) {
            insertTranscriptionID(id)
        }
        recomputeTranscriptionIDs()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(jobs) else { return }
        let url = jobsFileURL
        ioQueue.async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowFilesStore")
                    .error("Could not save Files jobs: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
