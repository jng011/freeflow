import Foundation

/// Pure functions behind every Insights number. No I/O, no global state besides the passed calendar.
enum FlowStatsCalculator {

    // MARK: - Tokens

    /// Word tokens: runs matching [\p{L}\p{N}][\p{L}\p{N}'’-]*, with each CJK character counted as its own token.
    static func tokens(in text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        func flush() {
            if !current.isEmpty {
                result.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                flush()
                result.append(String(scalar))
            } else if isWordScalar(scalar) {
                current.append(scalar)
            } else if !current.isEmpty, scalar == "'" || scalar == "\u{2019}" || scalar == "-" {
                current.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    static func wordCount(_ text: String) -> Int { tokens(in: text).count }

    /// Lowercased tokens with surrounding punctuation stripped, for alignment.
    static func normalizedTokens(_ text: String) -> [String] {
        let strip = CharacterSet(charactersIn: "'\u{2019}-")
        return tokens(in: text.lowercased()).compactMap { token in
            let trimmed = token.trimmingCharacters(in: strip)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        let p = s.properties
        if p.isAlphabetic { return true }
        switch p.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: return true
        default: return false
        }
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        if s.properties.isIdeographic { return true }
        switch s.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D: return true   // kana
        default: return false
        }
    }

    // MARK: - Corrections

    struct Corrections: Equatable {
        var fixesWords: Int
        var removed: [String]
    }

    /// Counts ASR tokens deleted or substituted on the way to the final text (LCS alignment),
    /// minus the tokens consumed by dictionary replacements.
    static func corrections(asr: String, final: String, dictionaryReplacements: Int, maxTokens: Int = 600) -> Corrections {
        let a = normalizedTokens(asr)
        let b = normalizedTokens(final)
        guard !a.isEmpty else { return Corrections(fixesWords: 0, removed: []) }
        guard a.count <= maxTokens, b.count <= maxTokens else { return Corrections(fixesWords: 0, removed: []) }

        let n = a.count, m = b.count
        let width = m + 1
        var dp = [UInt16](repeating: 0, count: (n + 1) * width)
        if m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if a[i] == b[j] {
                        dp[i * width + j] = dp[(i + 1) * width + j + 1] + 1
                    } else {
                        dp[i * width + j] = max(dp[(i + 1) * width + j], dp[i * width + j + 1])
                    }
                }
            }
        }
        var unmatched: [String] = []
        var i = 0, j = 0
        while i < n {
            if j < m, a[i] == b[j] {
                i += 1; j += 1
            } else if j < m, dp[i * width + j + 1] >= dp[(i + 1) * width + j] {
                j += 1
            } else {
                unmatched.append(a[i])
                i += 1
            }
        }
        let deletions = unmatched.count
        let fixes = max(0, deletions - min(max(0, dictionaryReplacements), deletions))
        return Corrections(fixesWords: fixes, removed: Array(unmatched.prefix(20)))
    }

    // MARK: - Summary

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func wpm(records: [FlowDictationRecord]) -> Int? {
        let recent = records
            .filter { $0.isCounted && $0.audio < 400 }
            .sorted { $0.ts > $1.ts }
            .prefix(100)
        guard recent.count >= 3 else { return nil }
        let words = recent.reduce(0) { $0 + $1.words }
        let seconds = recent.reduce(0.0) { $0 + ($1.speech ?? $1.audio) }
        guard seconds > 0 else { return nil }
        return Int((Double(words) / (seconds / 60)).rounded())
    }

    /// Current day streak (with a one day grace) and the longest run.
    static func dayStreaks(activeDays: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        guard !activeDays.isEmpty else { return (0, 0) }
        let sorted = activeDays.sorted()
        var longest = 1, run = 1
        for index in sorted.indices.dropFirst() {
            let gap = calendar.dateComponents([.day], from: sorted[index - 1], to: sorted[index]).day ?? 0
            run = gap == 1 ? run + 1 : 1
            longest = max(longest, run)
        }
        let todayStart = calendar.startOfDay(for: today)
        guard let latest = sorted.last else { return (0, longest) }
        let sinceLatest = calendar.dateComponents([.day], from: latest, to: todayStart).day ?? Int.max
        guard sinceLatest <= 1 else { return (0, longest) }
        var current = 1
        var cursor = latest
        while let previous = calendar.date(byAdding: .day, value: -1, to: cursor), activeDays.contains(previous) {
            current += 1
            cursor = previous
        }
        return (current, max(longest, current))
    }

    static func weekStreak(activeDays: Set<Date>, today: Date) -> Int {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        func weekStart(_ date: Date) -> Date? { calendar.dateInterval(of: .weekOfYear, for: date)?.start }
        let weeks = Set(activeDays.compactMap(weekStart))
        guard let thisWeek = weekStart(today) else { return 0 }
        var anchor: Date
        if weeks.contains(thisWeek) {
            anchor = thisWeek
        } else if let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek),
                  let prevStart = weekStart(previous), weeks.contains(prevStart) {
            anchor = prevStart
        } else {
            return 0
        }
        var count = 1
        while let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: anchor),
              let prevStart = weekStart(previous), weeks.contains(prevStart) {
            count += 1
            anchor = prevStart
        }
        return count
    }

    static func summary(records: [FlowDictationRecord], now: Date = Date(), calendar: Calendar = .current) -> FlowStatsSummary {
        var summary = FlowStatsSummary()
        let counted = records.filter(\.isCounted)

        summary.totalWords = counted.reduce(0) { $0 + $1.words }
        summary.totalDictations = counted.count
        summary.wpm = wpm(records: counted)
        if let wpm = summary.wpm {
            summary.wpmTopPercent = FlowTypingPercentile.topPercent(forWPM: wpm)
        }
        summary.wordsCorrected = counted.reduce(0) { $0 + $1.fixesWords }
        summary.dictionaryFixes = counted.reduce(0) { $0 + $1.fixesDict }

        // Daily words and active days
        var daily: [String: Int] = [:]
        var activeDays = Set<Date>()
        var firstDate: Date?
        for record in counted {
            daily[dayKey(record.ts, calendar: calendar), default: 0] += record.words
            activeDays.insert(calendar.startOfDay(for: record.ts))
            firstDate = min(firstDate ?? record.ts, record.ts)
        }
        summary.dailyWords = daily
        summary.firstDay = firstDate.map { dayKey($0, calendar: calendar) }

        let streaks = dayStreaks(activeDays: activeDays, today: now, calendar: calendar)
        summary.dayStreak = streaks.current
        summary.longestDayStreak = streaks.longest
        summary.weekStreak = weekStreak(activeDays: activeDays, today: now)

        // Month over month
        if let monthStart = calendar.dateInterval(of: .month, for: now)?.start,
           let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart) {
            let current = counted.filter { $0.ts >= monthStart && $0.ts <= now }.reduce(0) { $0 + $1.words }
            summary.wordsThisMonth = current
            let dayOfMonth = calendar.component(.day, from: now)
            let lastMonthLength = calendar.range(of: .day, in: .month, for: lastMonthStart)?.count ?? 30
            let span = min(dayOfMonth, lastMonthLength)
            if let previousEnd = calendar.date(byAdding: .day, value: span, to: lastMonthStart) {
                let previous = counted.filter { $0.ts >= lastMonthStart && $0.ts < previousEnd }.reduce(0) { $0 + $1.words }
                let hasHistory = firstDate.map { $0 <= lastMonthStart } ?? false
                if previous > 0 && hasHistory {
                    summary.wordsSamePeriodLastMonth = previous
                    let change = (Double(current - previous) / Double(previous) * 100).rounded()
                    summary.monthChangePercent = abs(Int(change))
                    summary.monthChangeUp = current >= previous
                }
            }
        }

        // Categories
        var categoryWords: [FlowAppCategory: (words: Int, dictations: Int)] = [:]
        var bundles = Set<String>()
        for record in counted {
            var entry = categoryWords[record.cat] ?? (words: 0, dictations: 0)
            entry.words += record.words
            entry.dictations += 1
            categoryWords[record.cat] = entry
            if let app = record.app, !app.isEmpty { bundles.insert(app) }
        }
        summary.categories = categoryWords
            .map { FlowCategoryUsage(category: $0.key, words: $0.value.words, dictations: $0.value.dictations) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.category.rawValue < $1.category.rawValue }
        summary.appsUsed = bundles.count

        // Top apps over the last 30 days
        let cutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        var apps: [String: (name: String, nameDate: Date, words: Int)] = [:]
        for record in counted where record.ts >= cutoff {
            guard let bundle = record.app, !bundle.isEmpty else { continue }
            var entry = apps[bundle] ?? (name: record.appName ?? bundle, nameDate: record.ts, words: 0)
            entry.words += record.words
            if record.ts >= entry.nameDate, let name = record.appName, !name.isEmpty {
                entry.name = name
                entry.nameDate = record.ts
            }
            apps[bundle] = entry
        }
        summary.topApps = apps
            .map { FlowAppUsage(bundleID: $0.key, name: $0.value.name, words: $0.value.words) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.name < $1.name }
            .prefix(5)
            .map { $0 }

        summary.funFact = FlowFunFacts.fact(forWords: summary.totalWords)
        summary.isLoading = false
        return summary
    }

    // MARK: - Per-day details (heatmap tooltip)

    struct DayDetail: Equatable {
        var words: Int
        var topApp: String?
        var appsUsed: Int
    }

    static func dayDetails(records: [FlowDictationRecord], calendar: Calendar = .current) -> [String: DayDetail] {
        var grouped: [String: [FlowDictationRecord]] = [:]
        for record in records where record.isCounted {
            grouped[dayKey(record.ts, calendar: calendar), default: []].append(record)
        }
        var result: [String: DayDetail] = [:]
        for (key, dayRecords) in grouped {
            var perApp: [String: (name: String, words: Int)] = [:]
            for record in dayRecords {
                guard let bundle = record.app, !bundle.isEmpty else { continue }
                var entry = perApp[bundle] ?? (name: record.appName ?? bundle, words: 0)
                entry.words += record.words
                perApp[bundle] = entry
            }
            let top = perApp.max { $0.value.words < $1.value.words }?.value.name
            result[key] = DayDetail(words: dayRecords.reduce(0) { $0 + $1.words }, topApp: top, appsUsed: perApp.count)
        }
        return result
    }
}
