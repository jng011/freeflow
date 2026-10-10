import SwiftUI

/// Streak tile: title, a paged week by weekday heatmap of daily words, and a legend.
struct InsightsHeatmap: View {
    var summary: FlowStatsSummary
    var dayDetails: [String: FlowStatsCalculator.DayDetail]

    @State private var weeksBack = 0
    @State private var gridWidth: CGFloat = 0

    private var calendar: Calendar { InsightsHeatmapGrid.gridCalendar }

    private var visibleColumns: Int {
        let available = gridWidth - InsightsHeatmapGrid.labelColumnWidth - InsightsHeatmapGrid.gap
        return max(1, Int(floor((available + InsightsHeatmapGrid.gap) / InsightsHeatmapGrid.pitch)))
    }

    private var endWeekStart: Date {
        let current = InsightsHeatmapGrid.weekStart(for: Date(), calendar: calendar)
        return calendar.date(byAdding: .day, value: -7 * weeksBack, to: current) ?? current
    }

    private var firstVisibleWeekStart: Date {
        calendar.date(byAdding: .day, value: -7 * (visibleColumns - 1), to: endWeekStart) ?? endWeekStart
    }

    private var canGoBack: Bool {
        let first = InsightsHeatmapGrid.firstDayDate(summary.firstDay, calendar: calendar)
        let limit = calendar.date(byAdding: .day, value: -28, to: first) ?? first
        return firstVisibleWeekStart > limit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(summary.dayStreak) day streak")
                    .flowText(.h2)
                    .foregroundStyle(FlowColor.foreground)
                Spacer(minLength: 12)
                if summary.longestDayStreak > 0 {
                    Text("Longest streak | \(summary.longestDayStreak) \(summary.longestDayStreak == 1 ? "day" : "days")")
                        .flowText(.label)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                }
            }
            InsightsSeparator()

            VStack(alignment: .leading, spacing: 8) {
                monthRow
                InsightsHeatmapGrid(
                    dailyWords: summary.dailyWords,
                    firstDay: summary.firstDay,
                    dayStreak: summary.dayStreak,
                    columns: visibleColumns,
                    endWeekStart: endWeekStart,
                    details: dayDetails,
                    interactive: true
                )
                .id(weeksBack)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }

            Spacer(minLength: 16)
            InsightsHeatmapLegend()
                .padding(.top, 16)
        }
    }

    private var monthRow: some View {
        HStack(spacing: InsightsHeatmapGrid.gap) {
            chevron("chevron-left", fallback: "chevron.left", enabled: canGoBack) {
                weeksBack += 4
            }
            .frame(width: InsightsHeatmapGrid.labelColumnWidth)

            InsightsHeatmapMonthLabels(columns: visibleColumns, endWeekStart: endWeekStart)
                .frame(maxWidth: .infinity, alignment: .leading)

            chevron("chevron-right", fallback: "chevron.right", enabled: weeksBack > 0) {
                weeksBack = max(0, weeksBack - 4)
            }
        }
        .frame(height: 16)
    }

    private func chevron(_ name: String, fallback: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            InsightsIcon(name, fallback: fallback, size: 14, color: FlowColor.foregroundTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }
}

/// Month names above the first column of each month.
struct InsightsHeatmapMonthLabels: View {
    var columns: Int
    var endWeekStart: Date

    var body: some View {
        let calendar = InsightsHeatmapGrid.gridCalendar
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        var labels: [(column: Int, text: String)] = []
        var previousMonth: Int?
        for column in 0..<max(0, columns) {
            guard let start = calendar.date(byAdding: .day, value: -7 * (columns - 1 - column), to: endWeekStart) else { continue }
            let month = calendar.component(.month, from: start)
            if month != previousMonth {
                labels.append((column, formatter.string(from: start)))
                previousMonth = month
            }
        }
        // Drop a leading label that would collide with the next one.
        if labels.count > 1, labels[1].column - labels[0].column < 2 { labels.removeFirst() }

        return ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 16)
            ForEach(labels, id: \.column) { label in
                Text(label.text)
                    .font(FlowFont.sans(10))
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .fixedSize()
                    .offset(x: CGFloat(label.column) * InsightsHeatmapGrid.pitch)
            }
        }
    }
}

/// The weekday by week grid. Reused by the share card with a fixed number of columns.
struct InsightsHeatmapGrid: View {
    var dailyWords: [String: Int]
    var firstDay: String?
    var dayStreak: Int
    var columns: Int
    var endWeekStart: Date
    var details: [String: FlowStatsCalculator.DayDetail] = [:]
    var interactive: Bool = false
    var showsDayLabels: Bool = true
    /// False for static renders (share image): no entrance animation.
    var animatesIn: Bool = true
    var labelColor: Color = FlowColor.foregroundTertiary

    static let cell: CGFloat = 16
    static let gap: CGFloat = 8
    static let pitch: CGFloat = 24
    static let labelColumnWidth: CGFloat = 21

    static var gridCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 1   // rows are Sun..Sat
        return calendar
    }

    static func weekStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func firstDayDate(_ key: String?, calendar: Calendar) -> Date {
        if let key, let date = FlowStatsCalculator.date(fromDayKey: key, calendar: calendar) { return date }
        return calendar.startOfDay(for: Date())
    }

    @State private var hovered: Hover?
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isShown: Bool { appeared || reduceMotion || !animatesIn }

    private struct Hover: Equatable {
        var key: String
        var date: Date
        var column: Int
        var row: Int
    }

    var body: some View {
        let calendar = Self.gridCalendar
        let today = calendar.startOfDay(for: Date())
        let first = Self.firstDayDate(firstDay, calendar: calendar)
        let streakDays = streakKeys(calendar: calendar, today: today)

        return HStack(alignment: .top, spacing: Self.gap) {
            if showsDayLabels {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(Self.dayLabel(row, calendar: calendar))
                            .font(FlowFont.sans(10))
                            .lineSpacing(0)
                            .foregroundStyle(labelColor)
                            .frame(width: Self.labelColumnWidth, height: Self.cell, alignment: .leading)
                    }
                }
            }
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(0..<max(0, columns), id: \.self) { column in
                    let weekStart = calendar.date(byAdding: .day, value: -7 * (columns - 1 - column), to: endWeekStart) ?? endWeekStart
                    VStack(spacing: Self.gap) {
                        ForEach(0..<7, id: \.self) { row in
                            let day = calendar.date(byAdding: .day, value: row, to: weekStart) ?? weekStart
                            cellView(day: day, column: column, row: row, today: today, first: first,
                                     streakDays: streakDays, calendar: calendar)
                        }
                    }
                    .scaleEffect(isShown ? 1 : 0.45)
                    .opacity(isShown ? 1 : 0)
                    .animation(reduceMotion || !animatesIn ? nil : .easeOut(duration: 0.4).delay(Double(column) * 0.03), value: appeared)
                }
            }
            .overlay(alignment: .topLeading) { tooltip }
        }
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private func cellView(day: Date, column: Int, row: Int, today: Date, first: Date,
                          streakDays: Set<String>, calendar: Calendar) -> some View {
        let key = FlowStatsCalculator.dayKey(day, calendar: calendar)
        let isFuture = day > today
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(isFuture ? Color.clear : color(words: dailyWords[key] ?? 0, before: day < first))
            .frame(width: Self.cell, height: Self.cell)
            .overlay {
                if !isFuture && streakDays.contains(key) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(FlowColor.fathom800, lineWidth: 1)
                        .frame(width: Self.cell + 4, height: Self.cell + 4)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                guard interactive, !isFuture else { return }
                if inside {
                    hovered = Hover(key: key, date: day, column: column, row: row)
                } else if hovered?.key == key {
                    hovered = nil
                }
            }
    }

    private func color(words: Int, before: Bool) -> Color {
        if before && words == 0 { return FlowColor.heatPreAccount }
        switch words {
        case ..<1: return FlowColor.heatEmpty
        case 1..<250: return FlowColor.fathom100
        case 250..<500: return FlowColor.fathom400
        case 500..<750: return FlowColor.fathom700
        default: return FlowColor.fathom800
        }
    }

    private func streakKeys(calendar: Calendar, today: Date) -> Set<String> {
        guard dayStreak > 1 else { return [] }
        let todayKey = FlowStatsCalculator.dayKey(today, calendar: calendar)
        var anchor = today
        if (dailyWords[todayKey] ?? 0) == 0 {
            anchor = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        }
        var keys = Set<String>()
        for offset in 0..<dayStreak {
            if let day = calendar.date(byAdding: .day, value: -offset, to: anchor) {
                keys.insert(FlowStatsCalculator.dayKey(day, calendar: calendar))
            }
        }
        return keys
    }

    static func dayLabel(_ row: Int, calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols   // Sun..Sat
        return symbols.indices.contains(row) ? symbols[row] : ""
    }

    @ViewBuilder
    private var tooltip: some View {
        if let hovered {
            let detail = details[hovered.key]
            let cardWidth: CGFloat = 180
            let flip = CGFloat(hovered.column) * Self.pitch + Self.pitch + cardWidth > CGFloat(columns) * Self.pitch
            let x = flip ? CGFloat(hovered.column) * Self.pitch - cardWidth - 6 : CGFloat(hovered.column) * Self.pitch + Self.pitch
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.tooltipDate(hovered.date))
                    .font(FlowFont.sans(12, weight: 550))
                    .foregroundStyle(FlowColor.foreground)
                tooltipRow("Total words", InsightsFormat.number(detail?.words ?? 0))
                tooltipRow("Top app", detail?.topApp ?? "None")
                tooltipRow("Total apps used", InsightsFormat.number(detail?.appsUsed ?? 0))
            }
            .padding(12)
            .frame(width: cardWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FlowColor.background))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(FlowColor.border, lineWidth: 1))
            .flowShadow(.md)
            .offset(x: x, y: max(0, CGFloat(hovered.row) * Self.pitch - 12))
            .allowsHitTesting(false)
            .transition(.opacity)
            .zIndex(10)
        }
    }

    private func tooltipRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(FlowColor.foregroundTertiary)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(FlowColor.foreground).lineLimit(1)
        }
        .font(FlowFont.sans(12))
    }

    private static func tooltipDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }
}

struct InsightsHeatmapLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("More")
            ForEach(Array([FlowColor.fathom800, FlowColor.fathom700, FlowColor.fathom400, FlowColor.fathom100].enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 12, height: 12)
            }
            Text("Less")
        }
        .font(FlowFont.sans(12))
        .foregroundStyle(FlowColor.foregroundTertiary)
    }
}
