import SwiftUI

/// "Your usage": WPM, fixes, total words, desktop usage and streak tiles in a 4 column grid.
struct InsightsUsageTab: View {
    @ObservedObject private var store = FlowStatsStore.shared

    var body: some View {
        let summary = store.summary
        Group {
            if summary.isLoading {
                skeleton
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if let error = store.loadError {
                        errorBanner(error)
                    }
                    InsightsSpanRow(spans: [1, 1, 2]) {
                        InsightsWPMTile(summary: summary).insightsTile()
                        InsightsFixesTile(summary: summary).insightsTile()
                        InsightsTotalWordsTile(summary: summary).insightsTile()
                    }
                    InsightsSpanRow(spans: [2, 2]) {
                        InsightsDesktopUsage(summary: summary).insightsTile()
                        InsightsHeatmap(summary: summary, dayDetails: store.dayDetails).insightsTile()
                    }
                }
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 40)
    }

    private var skeleton: some View {
        VStack(spacing: 24) {
            InsightsSpanRow(spans: [1, 1, 2]) {
                skeletonTile(height: 260)
                skeletonTile(height: 260)
                skeletonTile(height: 260)
            }
            InsightsSpanRow(spans: [2, 2]) {
                skeletonTile(height: 300)
                skeletonTile(height: 300)
            }
        }
        .accessibilityLabel("Loading insights")
    }

    private func skeletonTile(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(FlowColor.neutral200)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            InsightsIcon("circle-alert", fallback: "exclamationmark.circle", size: 18, color: FlowColor.destructive)
            Text("Your stats could not be loaded. \(message)")
                .flowText(.sm)
                .foregroundStyle(FlowColor.foreground)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Try again") { store.rebuildCaches() }
                .buttonStyle(FlowButtonStyle(variant: .primary, size: .sm))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FlowColor.neutral300, lineWidth: 1))
    }
}

// MARK: - Grid layout

/// Lays children out in a 4 column grid row: each child spans `spans[i]` columns with 24 pt gaps.
/// Column width = (W - 72) / 4. Every child gets the row's height.
struct InsightsSpanRow: Layout {
    var spans: [Int]
    var columns: Int = 4
    var spacing: CGFloat = 24

    private func widths(total: CGFloat, count: Int) -> [CGFloat] {
        let column = max(0, (total - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return (0..<count).map { index in
            let span = CGFloat(index < spans.count ? spans[index] : 1)
            return column * span + spacing * (span - 1)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 800
        let widths = widths(total: total, count: subviews.count)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil))
            height = max(height, size.height)
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(total: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: widths[index], height: bounds.height)
            )
            x += widths[index] + spacing
        }
    }
}

// MARK: - Tiles

struct InsightsWPMTile: View {
    var summary: FlowStatsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(summary.wpm.map { InsightsFormat.number($0) } ?? "0")
                .flowText(.h2)
                .foregroundStyle(FlowColor.foreground)
                .monospacedDigit()
            HStack(spacing: 4) {
                Text("Words per minute")
                    .flowText(.label)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                InsightsInfoIcon(tooltip: FlowTypingPercentile.tooltip)
            }
            InsightsSeparator()
            if let wpm = summary.wpm, let top = summary.wpmTopPercent {
                InsightsGauge(
                    percentile: FlowTypingPercentile.percentile(forWPM: wpm),
                    topPercentText: FlowTypingPercentile.displayTopPercent(top)
                )
                .frame(maxWidth: .infinity)
            } else {
                Text("Dictate a few more times to see your speed.")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            }
        }
    }
}

struct InsightsFixesTile: View {
    var summary: FlowStatsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(InsightsFormat.number(summary.wordsCorrected + summary.dictionaryFixes))
                .flowText(.h2)
                .foregroundStyle(FlowColor.foreground)
                .monospacedDigit()
            Text("Fixes made by Free Flow")
                .flowText(.label)
                .foregroundStyle(FlowColor.foregroundTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            InsightsSeparator()
            VStack(alignment: .leading, spacing: 12) {
                fixRow(count: summary.wordsCorrected, noun: "words corrected", singular: "word corrected",
                       tooltip: "Filler words and false starts removed by AI cleanup")
                fixRow(count: summary.dictionaryFixes, noun: "dictionary fixes", singular: "dictionary fix",
                       tooltip: "Words fixed by your dictionary replacements")
            }
        }
    }

    private func fixRow(count: Int, noun: String, singular: String, tooltip: String) -> some View {
        HStack(spacing: 6) {
            (Text(InsightsFormat.number(count)).font(FlowFont.sans(15, weight: 550))
                + Text(" " + (count == 1 ? singular : noun)).font(FlowFont.sans(15)))
                .foregroundStyle(FlowColor.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            InsightsInfoIcon(tooltip: tooltip)
        }
    }
}

struct InsightsTotalWordsTile: View {
    var summary: FlowStatsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(InsightsFormat.number(summary.totalWords))
                    .flowText(.h2)
                    .foregroundStyle(FlowColor.foreground)
                    .monospacedDigit()
                Spacer(minLength: 8)
                if let percent = summary.monthChangePercent {
                    monthBadge(percent: percent)
                }
            }
            Text("Total words dictated")
                .flowText(.label)
                .foregroundStyle(FlowColor.foregroundTertiary)
            InsightsSeparator()
            HStack(alignment: .top, spacing: 16) {
                HStack(alignment: .top, spacing: 8) {
                    InsightsIcon("tv-minimal", fallback: "tv", size: 16, color: FlowColor.foreground)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Desktop")
                            .flowText(.md)
                            .foregroundStyle(FlowColor.foreground)
                        Text("\(InsightsFormat.number(summary.totalWords)) words")
                            .flowText(.md)
                            .foregroundStyle(FlowColor.foregroundTertiary)
                    }
                }
                Spacer(minLength: 8)
                if let fact = summary.funFact {
                    Text(fact)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
        }
    }

    private func monthBadge(percent: Int) -> some View {
        let up = summary.monthChangeUp
        let current = InsightsFormat.number(summary.wordsThisMonth)
        let previous = InsightsFormat.number(summary.wordsSamePeriodLastMonth ?? 0)
        return HStack(spacing: 4) {
            InsightsIcon(up ? "trending-up" : "trending-down",
                         fallback: up ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis",
                         size: 12, color: up ? FlowColor.green800 : FlowColor.foregroundTertiary)
            Text("\(percent)% this month")
                .flowText(.xsEmph)
        }
        .foregroundStyle(up ? FlowColor.green800 : FlowColor.foregroundTertiary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(up ? FlowColor.green100 : FlowColor.backgroundTertiary))
        .overlay {
            if !up {
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(FlowColor.neutral300, lineWidth: 1)
            }
        }
        .flowHint("\(current) words compared to \(previous) words this time last month.")
    }
}
