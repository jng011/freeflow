import Foundation
import SwiftData
import os

/// One time import of dictation history recorded before the stats log existed.
enum FlowStatsBackfill {
    static let flagKey = "FlowStatsBackfilledV1"

    private static let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowStatsBackfill")

    static var isNeeded: Bool { !UserDefaults.standard.bool(forKey: flagKey) }

    static func markDone() { UserDefaults.standard.set(true, forKey: flagKey) }

    /// Builds backfilled records on a background ModelContext. Never writes to SwiftData.
    static func run(
        container: ModelContainer,
        existingIDs: Set<UUID>,
        excludedTranscriptionIDs: Set<UUID>
    ) async -> [FlowDictationRecord] {
        await Task.detached(priority: .utility) {
            Self.buildRecords(container: container, existingIDs: existingIDs, excluded: excludedTranscriptionIDs)
        }.value
    }

    private static func buildRecords(
        container: ModelContainer,
        existingIDs: Set<UUID>,
        excluded: Set<UUID>
    ) -> [FlowDictationRecord] {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let metrics: [SessionMetric]
        let transcriptions: [Transcription]
        do {
            metrics = try context.fetch(FetchDescriptor<SessionMetric>())
            transcriptions = try context.fetch(FetchDescriptor<Transcription>())
        } catch {
            logger.error("Backfill fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var transcriptionsByID: [UUID: Transcription] = [:]
        for transcription in transcriptions { transcriptionsByID[transcription.id] = transcription }

        let tz = TimeZone.current
        var seen = existingIDs
        var records: [FlowDictationRecord] = []

        // 1. Session metrics from the recorder
        var coveredTranscriptions = Set<UUID>()
        for metric in metrics where metric.source == nil || metric.source == "recorder" {
            coveredTranscriptions.insert(metric.transcriptionId)
            let id = metric.transcriptionId
            guard !seen.contains(id), !excluded.contains(id) else { continue }
            var fixes = 0
            var removed: [String] = []
            if let transcription = transcriptionsByID[id] {
                if isSkipped(transcription) { continue }
                if let enhanced = transcription.enhancedText, !enhanced.isEmpty {
                    let result = FlowStatsCalculator.corrections(asr: transcription.text, final: enhanced, dictionaryReplacements: 0)
                    fixes = result.fixesWords
                    removed = result.removed
                }
            }
            guard metric.wordCount > 0 else { continue }
            seen.insert(id)
            records.append(FlowDictationRecord(
                id: id,
                ts: metric.timestamp,
                tz: tz.secondsFromGMT(for: metric.timestamp) / 60,
                words: metric.wordCount,
                audio: metric.audioDuration,
                wpm: wpm(words: metric.wordCount, audio: metric.audioDuration),
                fixesWords: fixes,
                cat: .other,
                pasted: true,
                status: FlowDictationCapture.Status.completed.rawValue,
                backfilled: true,
                removed: FlowStatsStore.storesRemovedTokens ? removed : []
            ))
        }

        // 2. Transcriptions without a session metric
        for transcription in transcriptions {
            let id = transcription.id
            guard !coveredTranscriptions.contains(id), !seen.contains(id), !excluded.contains(id) else { continue }
            guard !isSkipped(transcription) else { continue }
            let finalText = transcription.enhancedText ?? transcription.text
            let words = FlowStatsCalculator.wordCount(finalText)
            guard words > 0 else { continue }
            var fixes = 0
            var removed: [String] = []
            if let enhanced = transcription.enhancedText, !enhanced.isEmpty {
                let result = FlowStatsCalculator.corrections(asr: transcription.text, final: enhanced, dictionaryReplacements: 0)
                fixes = result.fixesWords
                removed = result.removed
            }
            seen.insert(id)
            records.append(FlowDictationRecord(
                id: id,
                ts: transcription.timestamp,
                tz: tz.secondsFromGMT(for: transcription.timestamp) / 60,
                words: words,
                audio: transcription.duration,
                wpm: wpm(words: words, audio: transcription.duration),
                fixesWords: fixes,
                cat: .other,
                pasted: true,
                status: FlowDictationCapture.Status.completed.rawValue,
                backfilled: true,
                removed: FlowStatsStore.storesRemovedTokens ? removed : []
            ))
        }

        records.sort { $0.ts < $1.ts }
        logger.info("Backfilled \(records.count) dictation records")
        return records
    }

    private static func isSkipped(_ transcription: Transcription) -> Bool {
        let status = transcription.transcriptionStatus
        return status == TranscriptionStatus.canceled.rawValue
            || status == TranscriptionStatus.failed.rawValue
            || transcription.text == Transcription.canceledTranscriptionText
    }

    private static func wpm(words: Int, audio: TimeInterval) -> Int? {
        guard audio >= 1 else { return nil }
        return Int((Double(words) / (audio / 60)).rounded())
    }
}
