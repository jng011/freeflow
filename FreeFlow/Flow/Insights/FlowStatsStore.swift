import Foundation
import SwiftData
import os

/// Local stats engine: an append-only JSONL log of dictations plus a summary recomputed from it.
@MainActor
final class FlowStatsStore: ObservableObject {
    static let shared = FlowStatsStore()

    @Published private(set) var summary: FlowStatsSummary = .loading
    /// Per-day details for the heatmap tooltip, keyed "yyyy-MM-dd".
    @Published private(set) var dayDetails: [String: FlowStatsCalculator.DayDetail] = [:]
    /// Non-nil when the log could not be read. The page offers "Try again".
    @Published private(set) var loadError: String?

    private(set) var modelContainer: ModelContainer?

    private var records: [FlowDictationRecord] = []
    private var started = false
    private var isLoaded = false
    private var recomputeTask: Task<Void, Never>?
    private var pendingMilestoneCheck = false
    private var dayObserver: NSObjectProtocol?
    private let io = FlowStatsLogIO()
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowStatsStore")

    private init() {}

    /// "Never store" data policy: no transcript fragments may be kept in the stats log.
    nonisolated static var storesRemovedTokens: Bool {
        let defaults = UserDefaults.standard
        let cleanupOn = defaults.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
        let retention = defaults.integer(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes)
        return !(cleanupOn && retention == 0)
    }

    // MARK: - Lifecycle

    func start(modelContainer: ModelContainer) {
        guard !started else { return }
        started = true
        self.modelContainer = modelContainer
        load(runBackfill: FlowStatsBackfill.isNeeded)
        // Streaks and "this month" depend on today's date.
        dayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in FlowStatsStore.shared.scheduleRecompute(checkMilestones: false) }
        }
    }

    private func load(runBackfill: Bool) {
        let io = self.io
        Task { @MainActor in
            let loaded: [FlowDictationRecord]
            do {
                loaded = try await io.loadAll()
                loadError = nil
            } catch {
                logger.error("Stats log read failed: \(error.localizedDescription, privacy: .public)")
                loadError = error.localizedDescription
                summary = FlowStatsSummary()
                return
            }
            var all = loaded
            var didBackfill = false
            if runBackfill, let container = modelContainer {
                let excluded = FlowFilesStore.shared.transcriptionIDs
                let backfilled = await FlowStatsBackfill.run(
                    container: container,
                    existingIDs: Set(loaded.map(\.id)),
                    excludedTranscriptionIDs: excluded
                )
                if !backfilled.isEmpty {
                    await io.append(backfilled)
                    all += backfilled
                    all.sort { $0.ts < $1.ts }
                }
                FlowStatsBackfill.markDone()
                didBackfill = true
            }
            // Keep anything recorded while the log was loading.
            let loadedIDs = Set(all.map(\.id))
            let recordedMeanwhile = records.filter { !loadedIDs.contains($0.id) }
            records = recordedMeanwhile.isEmpty ? all : (all + recordedMeanwhile).sorted { $0.ts < $1.ts }
            await recomputeNow()
            isLoaded = true
            if didBackfill { FlowMilestones.markPassedAsSeen(summary) }
        }
    }

    // MARK: - Recording

    func record(_ capture: FlowDictationCapture) {
        let record = Self.makeRecord(from: capture)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record      // e.g. a canceled dictation that was undone
        } else {
            records.append(record)
        }
        let io = self.io
        Task.detached(priority: .utility) { await io.append([record]) }
        scheduleRecompute(checkMilestones: record.isCounted)
    }

    func allRecords() -> [FlowDictationRecord] { records }

    /// Reset app / "Try again": re-reads the log and recomputes everything.
    func rebuildCaches() {
        recomputeTask?.cancel()
        isLoaded = false
        summary = .loading
        load(runBackfill: false)
    }

    func exportJSON() throws -> Data {
        struct Export: Encodable {
            var records: [FlowDictationRecord]
            var summary: FlowStatsSummary
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Export(records: records, summary: summary))
    }

    // MARK: - Recompute

    private func scheduleRecompute(checkMilestones: Bool) {
        guard isLoaded else { return }   // the initial load recomputes once it finishes
        if checkMilestones { pendingMilestoneCheck = true }
        recomputeTask?.cancel()
        recomputeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await recomputeNow()
            if pendingMilestoneCheck {
                pendingMilestoneCheck = false
                FlowMilestones.check(summary)
            }
        }
    }

    private func recomputeNow() async {
        let snapshot = records
        let result = await Task.detached(priority: .userInitiated) {
            (FlowStatsCalculator.summary(records: snapshot), FlowStatsCalculator.dayDetails(records: snapshot))
        }.value
        summary = result.0
        dayDetails = result.1
        let io = self.io
        let summaryCopy = result.0
        Task.detached(priority: .utility) { await io.writeSummary(summaryCopy) }
    }

    // MARK: - Capture to record

    static func makeRecord(from capture: FlowDictationCapture) -> FlowDictationRecord {
        let words = FlowStatsCalculator.wordCount(capture.finalText)
        let minutes = (capture.speechDuration ?? capture.audioDuration) / 60
        let wpm: Int? = (capture.audioDuration >= 1 && minutes > 0) ? Int((Double(words) / minutes).rounded()) : nil
        let corrections = FlowStatsCalculator.corrections(
            asr: capture.asrText,
            final: capture.finalText,
            dictionaryReplacements: capture.dictionaryReplacementCount
        )
        let category = FlowAppCategory.classify(bundleID: capture.appBundleID, appName: capture.appName, url: capture.url)
        let src = capture.transcriptionSource.isEmpty ? nil : capture.transcriptionSource
        return FlowDictationRecord(
            id: capture.transcriptionID,
            ts: capture.stoppedAt,
            tz: TimeZone.current.secondsFromGMT(for: capture.stoppedAt) / 60,
            words: words,
            audio: capture.audioDuration,
            speech: capture.speechDuration,
            wpm: wpm,
            fixesWords: corrections.fixesWords,
            fixesDict: max(0, capture.dictionaryReplacementCount),
            app: capture.appBundleID,
            appName: capture.appName,
            url: capture.url,
            cat: category,
            lang: capture.language,
            src: src,
            latencyMs: capture.stopToPasteMs ?? capture.stopToTextMs,
            pasted: capture.pasted,
            status: capture.status.rawValue,
            backfilled: false,
            removed: storesRemovedTokens ? corrections.removed : []
        )
    }
}

// MARK: - File I/O (serial background queue)

final class FlowStatsLogIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jaydenghiyam.FreeFlow.stats-log", qos: .utility)
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowStatsLog")

    var logURL: URL { FlowPaths.file("flow-stats.jsonl") }
    var summaryURL: URL { FlowPaths.file("flow-stats-summary.json") }

    func loadAll() async throws -> [FlowDictationRecord] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let url = self.logURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    continuation.resume(returning: [])
                    return
                }
                do {
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    continuation.resume(returning: Self.parse(data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func append(_ records: [FlowDictationRecord]) async {
        guard !records.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.appendSync(records)
                continuation.resume()
            }
        }
    }

    func writeSummary(_ summary: FlowStatsSummary) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let data = try encoder.encode(FlowStatsSummaryFile(summary: summary, updatedAt: Date()))
                    try data.write(to: self.summaryURL, options: .atomic)
                } catch {
                    self.logger.error("Summary write failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume()
            }
        }
    }

    private func appendSync(_ records: [FlowDictationRecord]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var payload = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            payload.append(line)
            payload.append(0x0A)
        }
        guard !payload.isEmpty else { return }
        let url = logURL
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try payload.write(to: url, options: .atomic)
                return
            }
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                // Make sure a previous partial write does not glue two records together.
                try handle.seek(toOffset: end - 1)
                let last = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if last?.first != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
            }
            try handle.write(contentsOf: payload)
        } catch {
            logger.error("Stats log append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Parses JSONL. Malformed lines are skipped; later lines win for duplicate ids.
    static func parse(_ data: Data) -> [FlowDictationRecord] {
        let newline = UInt8(ascii: "\n")
        let lines = data.split(separator: newline, omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return [] }
        let decoder = JSONDecoder()

        var parsed: [FlowDictationRecord]
        // Fast path: decode every line in one pass as a lossy array.
        var joined = Data()
        joined.reserveCapacity(data.count + lines.count + 2)
        joined.append(UInt8(ascii: "["))
        for (index, line) in lines.enumerated() {
            if index > 0 { joined.append(UInt8(ascii: ",")) }
            joined.append(contentsOf: line)
        }
        joined.append(UInt8(ascii: "]"))
        if let lossy = try? decoder.decode([LossyRecord].self, from: joined) {
            parsed = lossy.compactMap(\.value)
        } else {
            // Slow path: a line is not valid JSON at all.
            parsed = lines.compactMap { try? decoder.decode(FlowDictationRecord.self, from: Data($0)) }
        }

        var indexByID: [UUID: Int] = [:]
        var unique: [FlowDictationRecord] = []
        unique.reserveCapacity(parsed.count)
        for record in parsed {
            if let existing = indexByID[record.id] {
                unique[existing] = record
            } else {
                indexByID[record.id] = unique.count
                unique.append(record)
            }
        }
        unique.sort { $0.ts < $1.ts }
        return unique
    }

    private struct LossyRecord: Decodable {
        let value: FlowDictationRecord?
        init(from decoder: Decoder) throws {
            value = try? FlowDictationRecord(from: decoder)
        }
    }
}
