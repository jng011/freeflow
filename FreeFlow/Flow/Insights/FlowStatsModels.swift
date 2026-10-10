import Foundation

// MARK: - Capture (built by the engine for every dictation)

struct FlowDictationCapture {
    enum Status: String, Codable { case completed, canceled, failed, empty }

    var transcriptionID: UUID
    var startedAt: Date
    var stoppedAt: Date
    var audioDuration: TimeInterval
    var speechDuration: TimeInterval?       // nil when unknown
    var asrText: String                      // ASR output after filter/formatting, BEFORE dictionary replacement and cleanup
    var finalText: String                    // exactly what was delivered (or would have been)
    var dictionaryReplacementCount: Int      // total substitutions from both replacement passes
    var appBundleID: String?
    var appName: String?
    var url: String?
    var language: String?
    var transcriptionSource: String          // "pc" | "mac"
    var stopToTextMs: Int?
    var stopToPasteMs: Int?
    var pasted: Bool
    var status: Status
}

// MARK: - Log record (one JSON object per line in flow-stats.jsonl)

/// Keys are part of the file contract with the MCP server. Do not rename.
struct FlowDictationRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var ts: Date
    var tz: Int
    var words: Int
    var audio: Double
    var speech: Double?
    var wpm: Int?
    var fixesWords: Int
    var fixesDict: Int
    var app: String?
    var appName: String?
    var url: String?
    var cat: FlowAppCategory
    var lang: String?
    var src: String?
    var latencyMs: Int?
    var pasted: Bool
    var status: String
    var backfilled: Bool
    var removed: [String]

    /// Completed records with words count toward totals, streaks, the heatmap and categories.
    var isCounted: Bool { status == FlowDictationCapture.Status.completed.rawValue && words > 0 }

    init(
        id: UUID, ts: Date, tz: Int = TimeZone.current.secondsFromGMT() / 60,
        words: Int, audio: Double, speech: Double? = nil, wpm: Int? = nil,
        fixesWords: Int = 0, fixesDict: Int = 0,
        app: String? = nil, appName: String? = nil, url: String? = nil, cat: FlowAppCategory = .other,
        lang: String? = nil, src: String? = nil, latencyMs: Int? = nil, pasted: Bool = false,
        status: String = FlowDictationCapture.Status.completed.rawValue,
        backfilled: Bool = false, removed: [String] = []
    ) {
        self.id = id; self.ts = ts; self.tz = tz
        self.words = words; self.audio = audio; self.speech = speech; self.wpm = wpm
        self.fixesWords = fixesWords; self.fixesDict = fixesDict
        self.app = app; self.appName = appName; self.url = url; self.cat = cat
        self.lang = lang; self.src = src; self.latencyMs = latencyMs; self.pasted = pasted
        self.status = status; self.backfilled = backfilled; self.removed = removed
    }

    enum CodingKeys: String, CodingKey {
        case id, ts, tz, words, audio, speech, wpm, fixesWords, fixesDict, app, appName, url, cat
        case lang, src, latencyMs, pasted, status, backfilled, removed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let tsString = try c.decode(String.self, forKey: .ts)
        guard let date = FlowStatsDateCoding.parse(tsString) else {
            throw DecodingError.dataCorruptedError(forKey: .ts, in: c, debugDescription: "Bad timestamp")
        }
        ts = date
        tz = (try? c.decodeIfPresent(Int.self, forKey: .tz)) ?? 0
        words = (try? c.decodeIfPresent(Int.self, forKey: .words)) ?? 0
        audio = (try? c.decodeIfPresent(Double.self, forKey: .audio)) ?? 0
        speech = try? c.decodeIfPresent(Double.self, forKey: .speech)
        wpm = try? c.decodeIfPresent(Int.self, forKey: .wpm)
        fixesWords = (try? c.decodeIfPresent(Int.self, forKey: .fixesWords)) ?? 0
        fixesDict = (try? c.decodeIfPresent(Int.self, forKey: .fixesDict)) ?? 0
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        appName = try? c.decodeIfPresent(String.self, forKey: .appName)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        let catRaw = (try? c.decodeIfPresent(String.self, forKey: .cat)) ?? nil
        cat = catRaw.flatMap(FlowAppCategory.init(rawValue:)) ?? .other
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
        src = try? c.decodeIfPresent(String.self, forKey: .src)
        latencyMs = try? c.decodeIfPresent(Int.self, forKey: .latencyMs)
        pasted = (try? c.decodeIfPresent(Bool.self, forKey: .pasted)) ?? false
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? FlowDictationCapture.Status.completed.rawValue
        backfilled = (try? c.decodeIfPresent(Bool.self, forKey: .backfilled)) ?? false
        removed = (try? c.decodeIfPresent([String].self, forKey: .removed)) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(FlowStatsDateCoding.format(ts), forKey: .ts)
        try c.encode(tz, forKey: .tz)
        try c.encode(words, forKey: .words)
        try c.encode(audio, forKey: .audio)
        try c.encode(speech, forKey: .speech)          // explicit null when nil
        try c.encode(wpm, forKey: .wpm)
        try c.encode(fixesWords, forKey: .fixesWords)
        try c.encode(fixesDict, forKey: .fixesDict)
        try c.encode(app, forKey: .app)
        try c.encode(appName, forKey: .appName)
        try c.encode(url, forKey: .url)
        try c.encode(cat.rawValue, forKey: .cat)
        try c.encode(lang, forKey: .lang)
        try c.encode(src, forKey: .src)
        try c.encode(latencyMs, forKey: .latencyMs)
        try c.encode(pasted, forKey: .pasted)
        try c.encode(status, forKey: .status)
        try c.encode(backfilled, forKey: .backfilled)
        try c.encode(removed, forKey: .removed)
    }
}

/// ISO8601 with fractional seconds, tolerant of timestamps without fractions.
enum FlowStatsDateCoding {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func format(_ date: Date) -> String { fractional.string(from: date) }

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}

// MARK: - Summary

struct FlowCategoryUsage: Codable, Equatable {
    var category: FlowAppCategory
    var words: Int
    var dictations: Int
}

struct FlowAppUsage: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var words: Int
    var id: String { bundleID }
}

struct FlowStatsSummary: Codable, Equatable {
    var isLoading: Bool
    var totalWords: Int
    var totalDictations: Int
    var wpm: Int?
    var wpmTopPercent: Double?
    var dayStreak: Int
    var longestDayStreak: Int
    var weekStreak: Int
    var wordsThisMonth: Int
    var wordsSamePeriodLastMonth: Int?
    var monthChangePercent: Int?
    var monthChangeUp: Bool
    var wordsCorrected: Int
    var dictionaryFixes: Int
    var categories: [FlowCategoryUsage]
    var appsUsed: Int
    var topApps: [FlowAppUsage]
    var dailyWords: [String: Int]      // "yyyy-MM-dd" -> words
    var firstDay: String?
    var funFact: String?

    static let loading = FlowStatsSummary(isLoading: true)

    init(
        isLoading: Bool = false, totalWords: Int = 0, totalDictations: Int = 0, wpm: Int? = nil,
        wpmTopPercent: Double? = nil, dayStreak: Int = 0, longestDayStreak: Int = 0, weekStreak: Int = 0,
        wordsThisMonth: Int = 0, wordsSamePeriodLastMonth: Int? = nil, monthChangePercent: Int? = nil,
        monthChangeUp: Bool = true, wordsCorrected: Int = 0, dictionaryFixes: Int = 0,
        categories: [FlowCategoryUsage] = [], appsUsed: Int = 0, topApps: [FlowAppUsage] = [],
        dailyWords: [String: Int] = [:], firstDay: String? = nil, funFact: String? = nil
    ) {
        self.isLoading = isLoading; self.totalWords = totalWords; self.totalDictations = totalDictations
        self.wpm = wpm; self.wpmTopPercent = wpmTopPercent; self.dayStreak = dayStreak
        self.longestDayStreak = longestDayStreak; self.weekStreak = weekStreak
        self.wordsThisMonth = wordsThisMonth; self.wordsSamePeriodLastMonth = wordsSamePeriodLastMonth
        self.monthChangePercent = monthChangePercent; self.monthChangeUp = monthChangeUp
        self.wordsCorrected = wordsCorrected; self.dictionaryFixes = dictionaryFixes
        self.categories = categories; self.appsUsed = appsUsed; self.topApps = topApps
        self.dailyWords = dailyWords; self.firstDay = firstDay; self.funFact = funFact
    }
}

/// The summary file written for the MCP server: the summary plus "updatedAt".
struct FlowStatsSummaryFile: Encodable {
    var summary: FlowStatsSummary
    var updatedAt: Date

    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(FlowStatsDateCoding.format(updatedAt), forKey: .updatedAt)
    }
    private enum Keys: String, CodingKey { case updatedAt }
}

// MARK: - Voice profile

struct FlowVoiceProfile: Codable, Equatable {
    var createdAt: Date
    var wordsAtGeneration: Int
    var model: String
    var superpowerTitle: String
    var superpowerDescription: String
    var persona: String
    var catchPhrase: String
    var catchPhraseDescription: String
    var peakTimeTitle: String
    var peakTimeDescription: String
    var peakApp: String?
    var peakAppBundleID: String?
    var mostUsedWord: String?
    var mostCorrectedWord: String?
}
