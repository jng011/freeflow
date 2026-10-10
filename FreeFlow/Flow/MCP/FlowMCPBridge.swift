import Foundation
import OSLog

/// File-based bridge between the bundled stdio MCP server (Resources/MCP/freeflow_mcp.py) and the app.
///
/// Contract, all under FlowPaths.appSupport/mcp/:
/// - inbox/dictionary/<id>.json   {"id","action":"add","phrase","replacement":null|string,"createdAt"}
/// - inbox/transcribe/<id>.json   {"id","path","cleanup":bool,"createdAt"}
/// - outbox/<id>.json             {"id","ok":bool,"message"?,"text"?,"rawText"?,"durationSec"?,"transcriptionId"?,"error"?}
/// - outbox/<id>.progress.json    {"id","progress":0..1,"phase"}
/// - heartbeat.json               {"pid","version","updatedAt"} written every 5 s while the app runs
/// - failed/                      malformed inbox files are moved here
@MainActor
final class FlowMCPBridge {
    static let shared = FlowMCPBridge()

    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowMCPBridge")
    private let fileManager = FileManager.default

    private var timer: Timer?
    private var tickCount = 0
    /// Transcribe job ids (as written by the client) that are queued or running in FlowFilesStore.
    private var activeTranscribeIDs: Set<String> = []

    /// Files younger than this are skipped so a half-written job is never read.
    private let minimumFileAge: TimeInterval = 0.2
    private let heartbeatEveryTicks = 5
    private let outboxRetention: TimeInterval = 24 * 60 * 60
    private let progressWriteInterval: TimeInterval = 1.0

    private init() {}

    // MARK: - Folders

    private var rootURL: URL { FlowPaths.appSupport.appendingPathComponent("mcp", isDirectory: true) }
    private var dictionaryInboxURL: URL { rootURL.appendingPathComponent("inbox/dictionary", isDirectory: true) }
    private var transcribeInboxURL: URL { rootURL.appendingPathComponent("inbox/transcribe", isDirectory: true) }
    private var outboxURL: URL { rootURL.appendingPathComponent("outbox", isDirectory: true) }
    private var failedURL: URL { rootURL.appendingPathComponent("failed", isDirectory: true) }
    private var heartbeatURL: URL { rootURL.appendingPathComponent("heartbeat.json", isDirectory: false) }

    // MARK: - Lifecycle

    /// Creates the folders, cleans old outbox files and polls the inbox every 1.0 s.
    func start() {
        guard timer == nil else { return }
        FlowAgentSetup.installScript()

        for url in [dictionaryInboxURL, transcribeInboxURL, outboxURL, failedURL] {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                logger.error("Could not create \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        removeOldOutboxFiles()
        writeHeartbeat()
        tickCount = 0

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.info("MCP bridge started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        try? fileManager.removeItem(at: heartbeatURL)
        logger.info("MCP bridge stopped")
    }

    private func tick() {
        tickCount += 1
        if tickCount % heartbeatEveryTicks == 0 {
            writeHeartbeat()
        }
        for file in pendingJobFiles(in: dictionaryInboxURL) {
            processDictionaryJob(at: file)
        }
        for file in pendingJobFiles(in: transcribeInboxURL) {
            processTranscribeJob(at: file)
        }
    }

    // MARK: - Inbox scanning

    /// .json files whose modification time is older than `minimumFileAge`, oldest first.
    private func pendingJobFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let now = Date()
        var dated: [(url: URL, date: Date)] = []
        for url in items where url.pathExtension.lowercased() == "json" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > minimumFileAge else { continue }
            dated.append((url, modified))
        }
        return dated.sorted { $0.date < $1.date }.map(\.url)
    }

    /// Parses a job file. On failure the file is moved to failed/ and an outbox error is written.
    private func readJob(at file: URL) -> (id: String, object: [String: Any])? {
        let fallbackID = file.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            quarantine(file, id: fallbackID, error: "The job file is not valid JSON")
            return nil
        }
        let id = (object["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackID
        return (id, object)
    }

    private func quarantine(_ file: URL, id: String, error: String) {
        let destination = failedURL.appendingPathComponent(file.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: file, to: destination)
        } catch {
            try? fileManager.removeItem(at: file)
        }
        logger.error("Malformed MCP job \(id, privacy: .public): \(error, privacy: .public)")
        writeOutbox(id: id, ["ok": false, "error": error])
    }

    // MARK: - Dictionary jobs

    private func processDictionaryJob(at file: URL) {
        guard let job = readJob(at: file) else { return }
        let object = job.object

        let action = (object["action"] as? String) ?? "add"
        guard action == "add" else {
            quarantine(file, id: job.id, error: "Unsupported dictionary action \"\(action)\"")
            return
        }
        guard let phrase = object["phrase"] as? String else {
            quarantine(file, id: job.id, error: "The job is missing \"phrase\"")
            return
        }
        let rawReplacement = object["replacement"]
        let replacement: String?
        if rawReplacement == nil || rawReplacement is NSNull {
            replacement = nil
        } else if let value = rawReplacement as? String {
            replacement = value
        } else {
            quarantine(file, id: job.id, error: "\"replacement\" must be a string or null")
            return
        }

        try? fileManager.removeItem(at: file)

        switch FlowDictionaryStore.shared.addFromExternal(phrase: phrase, replacement: replacement) {
        case .success(let message):
            writeOutbox(id: job.id, ["ok": true, "message": message.isEmpty ? "Added" : message])
            logger.info("MCP dictionary entry added")
        case .failure(let error):
            writeOutbox(id: job.id, ["ok": false, "error": error.localizedDescription])
        }
    }

    // MARK: - Transcribe jobs

    private func processTranscribeJob(at file: URL) {
        guard let job = readJob(at: file) else { return }
        let id = job.id
        let object = job.object

        guard let rawPath = object["path"] as? String, !rawPath.isEmpty else {
            quarantine(file, id: id, error: "The job is missing \"path\"")
            return
        }
        let cleanup = (object["cleanup"] as? Bool) ?? true

        // Delete right away so the job is never picked up twice.
        try? fileManager.removeItem(at: file)

        guard !activeTranscribeIDs.contains(id) else {
            logger.info("MCP transcribe job \(id, privacy: .public) is already running")
            return
        }

        let path = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            writeOutbox(id: id, ["ok": false, "error": "File not found: \(url.path)"])
            return
        }
        guard fileManager.isReadableFile(atPath: url.path) else {
            writeOutbox(id: id, ["ok": false, "error": "Free Flow cannot read \(url.path). Check its permissions."])
            return
        }
        guard SupportedMedia.isSupported(url: url) else {
            writeOutbox(id: id, ["ok": false, "error": "\(url.lastPathComponent) isn't an audio or video file Free Flow can transcribe"])
            return
        }

        activeTranscribeIDs.insert(id)
        let progressURL = progressFileURL(for: id)
        let throttle = ProgressThrottle(interval: progressWriteInterval)
        writeProgress(id: id, progress: 0, phase: "Queued", to: progressURL)

        logger.info("MCP transcribe job \(id, privacy: .public) queued")
        FlowFilesStore.shared.enqueueExternal(
            jobID: UUID(uuidString: id) ?? UUID(),
            url: url,
            cleanup: cleanup,
            progress: { [weak self] value, phase in
                guard throttle.shouldWrite(progress: value) else { return }
                self?.writeProgress(id: id, progress: value, phase: phase, to: progressURL)
            },
            completion: { [weak self] result in
                guard let self else { return }
                self.activeTranscribeIDs.remove(id)
                switch result {
                case .success(let output):
                    self.writeOutbox(id: id, [
                        "ok": true,
                        "message": "Transcribed",
                        "text": output.text,
                        "rawText": output.rawText,
                        "durationSec": output.duration,
                        "transcriptionId": output.transcriptionID.uuidString,
                    ])
                case .failure(let error):
                    self.writeOutbox(id: id, ["ok": false, "error": error.localizedDescription])
                }
                try? self.fileManager.removeItem(at: progressURL)
                self.logger.info("MCP transcribe job \(id, privacy: .public) finished")
            }
        )
    }

    /// Limits progress file writes to one per interval; the first update and 100% always pass.
    private final class ProgressThrottle {
        private let interval: TimeInterval
        private var lastWrite: Date?

        init(interval: TimeInterval) {
            self.interval = interval
        }

        func shouldWrite(progress: Double) -> Bool {
            let now = Date()
            if let lastWrite, now.timeIntervalSince(lastWrite) < interval, progress < 1 {
                return false
            }
            lastWrite = now
            return true
        }
    }

    // MARK: - Writing

    private func progressFileURL(for id: String) -> URL {
        outboxURL.appendingPathComponent("\(safeFileStem(id)).progress.json", isDirectory: false)
    }

    private func writeProgress(id: String, progress: Double, phase: String, to url: URL) {
        let clamped = progress.isFinite ? min(max(progress, 0), 1) : 0
        writeJSON(["id": id, "progress": clamped, "phase": phase], to: url)
    }

    private func writeOutbox(id: String, _ fields: [String: Any]) {
        var payload = fields
        payload["id"] = id
        let url = outboxURL.appendingPathComponent("\(safeFileStem(id)).json", isDirectory: false)
        writeJSON(payload, to: url)
    }

    private func writeHeartbeat() {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        writeJSON([
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "version": version,
            "updatedAt": formatter.string(from: now),
            "updatedAtEpoch": now.timeIntervalSince1970,
        ], to: heartbeatURL)
    }

    private func writeJSON(_ object: [String: Any], to url: URL) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Could not write \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps client-supplied ids from escaping the outbox folder.
    private func safeFileStem(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "job" : cleaned
    }

    // MARK: - Cleanup

    private func removeOldOutboxFiles() {
        let cutoff = Date().addingTimeInterval(-outboxRetention)
        for folder in [outboxURL, failedURL] {
            guard let items = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }
}
