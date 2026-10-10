import Foundation
import SwiftData
import os

enum FlowVoiceProfileState: Equatable {
    case idle
    case generating
    case failed(String)
}

/// Builds the "Your voice" profile from the owner's own dictations: local counts plus one
/// OpenRouter request with the owner's key.
@MainActor
final class FlowVoiceProfileService: ObservableObject {
    static let shared = FlowVoiceProfileService()

    @Published private(set) var profile: FlowVoiceProfile?
    @Published private(set) var state: FlowVoiceProfileState = .idle

    static let unlockWords = 2000
    static let noKeyMessage = "Add an OpenRouter key in Settings, AI Cleanup to generate your profile"
    static let noHistoryMessage = "Turn on local data storage to build your Voice Profile"

    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowVoiceProfile")
    private var fileURL: URL { FlowPaths.file("flow-voice-profile.json") }

    private init() {
        profile = Self.loadProfile(from: fileURL)
    }

    // MARK: - Thresholds

    private static let baseThresholds = [2000, 12000, 37000, 87000, 162000, 262000, 362000]

    /// The n-th threshold (0 based): the fixed list, then every +100,000.
    static func threshold(at index: Int) -> Int {
        if index < baseThresholds.count { return baseThresholds[max(0, index)] }
        return baseThresholds[baseThresholds.count - 1] + (index - baseThresholds.count + 1) * 100_000
    }

    /// Number of thresholds reached by `words`.
    static func thresholdsReached(_ words: Int) -> Int {
        var index = 0
        while threshold(at: index) <= words { index += 1 }
        return index
    }

    /// First threshold strictly above `words`.
    static func nextThreshold(after words: Int) -> Int {
        threshold(at: thresholdsReached(words))
    }

    /// Largest threshold at or below `words` (at least the unlock threshold).
    static func previousThreshold(atOrBelow words: Int) -> Int {
        let reached = thresholdsReached(words)
        return reached == 0 ? unlockWords : threshold(at: reached - 1)
    }

    struct Progress: Equatable {
        var previous: Int
        var next: Int
        var fraction: Double
        var remaining: Int
        var isUpdateReady: Bool
    }

    static func progress(totalWords: Int, profile: FlowVoiceProfile) -> Progress {
        let previous = previousThreshold(atOrBelow: profile.wordsAtGeneration)
        let next = nextThreshold(after: profile.wordsAtGeneration)
        let span = max(1, next - previous)
        let fraction = min(1, max(0, Double(totalWords - previous) / Double(span)))
        return Progress(
            previous: previous,
            next: next,
            fraction: fraction,
            remaining: max(0, next - totalWords),
            isUpdateReady: totalWords >= next
        )
    }

    // MARK: - Generation

    func generate() async {
        guard state != .generating else { return }
        let store = FlowStatsStore.shared
        let totalWords = store.summary.totalWords
        guard totalWords >= Self.unlockWords else { return }

        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "openrouter")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            state = .failed(Self.noKeyMessage)
            return
        }
        guard let container = store.modelContainer else {
            state = .failed(Self.noHistoryMessage)
            return
        }

        state = .generating
        let records = store.allRecords().filter(\.isCounted)
        let excluded = FlowFilesStore.shared.transcriptionIDs
        let wordCap: Int
        switch Self.thresholdsReached(totalWords) {
        case 0, 1: wordCap = 2_000
        case 2: wordCap = 12_000
        default: wordCap = 20_000
        }
        let model = UserDefaults.standard.string(forKey: "OpenRouterSelectedModel")
            .flatMap { $0.isEmpty ? nil : $0 } ?? "google/gemini-3.5-flash"

        let samples = await Task.detached(priority: .userInitiated) {
            Self.collectSamples(container: container, records: records, excluded: excluded)
        }.value
        guard !samples.isEmpty else {
            state = .failed(Self.noHistoryMessage)
            return
        }

        let local = Self.localFacts(records: records, samples: samples)
        let prompt = Self.buildUserMessage(samples: samples, wordCap: wordCap, peakTitle: local.peakTimeTitle, peakApp: local.peakApp)

        do {
            let ai = try await Self.requestProfile(apiKey: apiKey, model: model, userMessage: prompt)
            let newProfile = FlowVoiceProfile(
                createdAt: Date(),
                wordsAtGeneration: totalWords,
                model: model,
                superpowerTitle: ai.superpowerTitle,
                superpowerDescription: ai.superpowerDescription,
                persona: ai.persona,
                catchPhrase: ai.catchPhrase,
                catchPhraseDescription: ai.catchPhraseDescription,
                peakTimeTitle: local.peakTimeTitle,
                peakTimeDescription: ai.peakTimeDescription,
                peakApp: local.peakApp,
                peakAppBundleID: local.peakAppBundleID,
                mostUsedWord: local.mostUsedWord,
                mostCorrectedWord: local.mostCorrectedWord
            )
            save(newProfile)
            profile = newProfile
            state = .idle
        } catch {
            logger.error("Voice profile generation failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func clearError() {
        if case .failed = state { state = .idle }
    }

    // MARK: - Persistence

    private static func loadProfile(from url: URL) -> FlowVoiceProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FlowVoiceProfile.self, from: data)
    }

    private func save(_ profile: FlowVoiceProfile) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(profile).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Voice profile save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Samples

    struct Sample: Sendable {
        var date: Date
        var appName: String?
        var language: String?
        var text: String
    }

    /// Latest first. Reads Transcription rows on a background context, never writes.
    nonisolated private static func collectSamples(
        container: ModelContainer,
        records: [FlowDictationRecord],
        excluded: Set<UUID>
    ) -> [Sample] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 5000
        guard let transcriptions = try? context.fetch(descriptor) else { return [] }
        var recordByID: [UUID: FlowDictationRecord] = [:]
        for record in records { recordByID[record.id] = record }

        var samples: [Sample] = []
        for transcription in transcriptions {
            guard let record = recordByID[transcription.id], !excluded.contains(transcription.id) else { continue }
            if transcription.transcriptionStatus == TranscriptionStatus.canceled.rawValue
                || transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue { continue }
            let text = (transcription.enhancedText?.isEmpty == false ? transcription.enhancedText : nil) ?? transcription.text
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != Transcription.canceledTranscriptionText else { continue }
            samples.append(Sample(date: record.ts, appName: record.appName, language: record.lang, text: trimmed))
        }
        return samples
    }

    // MARK: - Local facts

    struct LocalFacts {
        var mostUsedWord: String?
        var mostCorrectedWord: String?
        var peakTimeTitle: String
        var peakApp: String?
        var peakAppBundleID: String?
    }

    static func localFacts(records: [FlowDictationRecord], samples: [Sample], calendar: Calendar = .current) -> LocalFacts {
        // Most used word
        var counts: [String: Int] = [:]
        for sample in samples {
            for token in FlowStatsCalculator.normalizedTokens(sample.text) where token.count >= 2 {
                guard token.unicodeScalars.contains(where: { $0.properties.isAlphabetic }),
                      !stopwords.contains(token) else { continue }
                counts[token, default: 0] += 1
            }
        }
        let mostUsed = Self.topKey(counts)

        // Most corrected word
        var removedCounts: [String: Int] = [:]
        for record in records {
            for token in record.removed where !token.isEmpty { removedCounts[token, default: 0] += 1 }
        }
        let mostCorrected = Self.topKey(removedCounts)

        // Peak slot
        struct Slot: Hashable { var weekday: Int; var hour: Int }
        var slotCounts: [Slot: Int] = [:]
        for record in records {
            let c = calendar.dateComponents([.weekday, .hour], from: record.ts)
            slotCounts[Slot(weekday: c.weekday ?? 1, hour: c.hour ?? 0), default: 0] += 1
        }
        let peakEntry = slotCounts.max { (lhs: (key: Slot, value: Int), rhs: (key: Slot, value: Int)) -> Bool in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            let lhsOrder = lhs.key.weekday * 24 + lhs.key.hour
            let rhsOrder = rhs.key.weekday * 24 + rhs.key.hour
            return lhsOrder > rhsOrder
        }
        let peak = peakEntry?.key ?? Slot(weekday: calendar.component(.weekday, from: Date()), hour: 9)

        var appCounts: [String: (name: String, count: Int)] = [:]
        for record in records {
            let c = calendar.dateComponents([.weekday, .hour], from: record.ts)
            guard c.weekday == peak.weekday, c.hour == peak.hour else { continue }
            guard let key = record.app ?? record.appName else { continue }
            var entry = appCounts[key] ?? (name: record.appName ?? key, count: 0)
            entry.count += 1
            if let name = record.appName, !name.isEmpty { entry.name = name }
            appCounts[key] = entry
        }
        let topApp = appCounts.max { $0.value.count < $1.value.count }

        let symbols = calendar.weekdaySymbols
        let weekdayName = symbols.indices.contains(peak.weekday - 1) ? symbols[peak.weekday - 1] : "Monday"
        let hour12 = peak.hour % 12 == 0 ? 12 : peak.hour % 12
        let suffix = peak.hour < 12 ? "am" : "pm"

        return LocalFacts(
            mostUsedWord: mostUsed,
            mostCorrectedWord: mostCorrected,
            peakTimeTitle: "\(weekdayName) at \(hour12)\(suffix)",
            peakApp: topApp?.value.name,
            peakAppBundleID: topApp.flatMap { $0.key.contains(".") ? $0.key : nil }
        )
    }

    /// Highest count; ties go to the alphabetically first key.
    nonisolated static func topKey(_ counts: [String: Int]) -> String? {
        var best: (key: String, value: Int)?
        for (key, value) in counts {
            if let current = best {
                if value > current.value || (value == current.value && key < current.key) { best = (key, value) }
            } else {
                best = (key, value)
            }
        }
        return best?.key
    }

    // MARK: - AI

    nonisolated private static let systemPrompt = """
    You analyze a person's own dictated messages and describe their speaking and writing habits warmly and specifically. \
    Return JSON with keys superpower_title (2-3 words, a playful alliterative title like 'Demanding Debugger'), \
    superpower_description (one or two sentences, second person), persona (one of: Analysis, Brainstorm, Coding, \
    Collaboration, Create, Deep thought, Dreaming, Educate, Finance, Idea generation, Leadership, Long writing, Manage, \
    Multi-tasking, Multilingual, On the go, Organize, Presenting, Reporting, Support, Thinking), catch_phrase (a short \
    phrase they really say, max 6 words, quoted exactly from the text), catch_phrase_description, peak_time_description \
    (one sentence using the given peak slot and app). Use only evidence in the text. No dashes.
    """

    static func buildUserMessage(samples: [Sample], wordCap: Int, peakTitle: String, peakApp: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE HH:mm"
        var lines: [String] = []
        var words = 0
        var characters = 0
        for sample in samples {
            let sampleWords = FlowStatsCalculator.wordCount(sample.text)
            let flattened = sample.text.replacingOccurrences(of: "\n", with: " ")
            var label = formatter.string(from: sample.date) + " | " + (sample.appName ?? "Unknown app")
            if let lang = sample.language, !lang.isEmpty, lang != "auto", lang != "en" { label += " | " + lang }
            let line = "[\(label)] \(flattened)"
            if !lines.isEmpty && (words + sampleWords > wordCap || characters + line.count > 350_000) { break }
            lines.append(line)
            words += sampleWords
            characters += line.count + 1
        }
        return """
        Peak slot: \(peakTitle)
        Peak app: \(peakApp ?? "Unknown")

        Dictations (latest first):
        \(lines.joined(separator: "\n"))
        """
    }

    struct AIFields {
        var superpowerTitle: String
        var superpowerDescription: String
        var persona: String
        var catchPhrase: String
        var catchPhraseDescription: String
        var peakTimeDescription: String
    }

    enum GenerationError: LocalizedError {
        case http(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .http(let code, let message):
                return message.isEmpty ? "OpenRouter returned error \(code)" : "OpenRouter error \(code): \(message)"
            case .badResponse:
                return "The AI response could not be read. Try again."
            }
        }
    }

    nonisolated static func requestProfile(apiKey: String, model: String, userMessage: String) async throws -> AIFields {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else { throw GenerationError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Free Flow (local)", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.4,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw GenerationError.http(status, message)
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let fields = parseFields(content) else {
            throw GenerationError.badResponse
        }
        return fields
    }

    nonisolated static func parseFields(_ content: String) -> AIFields? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func field(_ key: String) -> String {
            let raw = (object[key] as? String) ?? ""
            return clean(raw)
        }
        let title = field("superpower_title")
        guard !title.isEmpty else { return nil }
        var catchPhrase = field("catch_phrase")
        catchPhrase = catchPhrase.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019} "))
        return AIFields(
            superpowerTitle: title,
            superpowerDescription: field("superpower_description"),
            persona: field("persona").isEmpty ? "Thinking" : field("persona"),
            catchPhrase: catchPhrase,
            catchPhraseDescription: field("catch_phrase_description"),
            peakTimeDescription: field("peak_time_description")
        )
    }

    /// Removes em and en dashes from model output.
    nonisolated static func clean(_ string: String) -> String {
        var result = string.trimmingCharacters(in: .whitespacesAndNewlines)
        for dash in [" \u{2014} ", " \u{2013} "] { result = result.replacingOccurrences(of: dash, with: ", ") }
        result = result.replacingOccurrences(of: "\u{2014}", with: ", ")
        result = result.replacingOccurrences(of: "\u{2013}", with: "-")
        return result
    }

    nonisolated private static let stopwords: Set<String> = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i", "it", "for", "not", "on", "with", "he",
        "as", "you", "do", "at", "this", "but", "his", "by", "from", "they", "we", "say", "her", "she", "or",
        "an", "will", "my", "one", "all", "would", "there", "their", "what", "so", "up", "out", "if", "about",
        "who", "get", "which", "go", "me", "when", "make", "can", "like", "time", "no", "just", "him", "know",
        "take", "into", "your", "some", "could", "them", "see", "other", "than", "then", "now", "look", "only",
        "come", "its", "over", "think", "also", "back", "after", "use", "two", "how", "our", "work", "first",
        "well", "way", "even", "want", "because", "any", "these", "give", "day", "most", "us", "is", "are",
        "was", "were", "been", "has", "had", "did", "does", "am", "i'm", "it's", "don't", "that's", "can't",
        "im", "dont", "thats", "yeah", "okay", "ok", "um", "uh", "very", "really", "here", "where", "why",
        "let", "let's", "should", "more", "need", "going", "got", "too", "thing", "things", "something",
    ]
}
