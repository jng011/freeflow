import SwiftUI

/// "Desktop usage": share of words per app category, as animated fathom bars.
struct InsightsDesktopUsage: View {
    var summary: FlowStatsSummary

    @State private var innerWidth: CGFloat = 0
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [FlowCategoryUsage] {
        summary.categories.filter { $0.words > 0 }.sorted { $0.words > $1.words }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Desktop usage")
                    .flowText(.h2)
                    .foregroundStyle(FlowColor.foreground)
                Spacer(minLength: 12)
                Text("Total apps used | \(InsightsFormat.number(summary.appsUsed))")
                    .flowText(.label)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            }
            InsightsSeparator()

            if rows.isEmpty {
                Text("Dictate in any app to see where you use Free Flow.")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(rows.enumerated()), id: \.element.category) { index, usage in
                        row(usage, index: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { innerWidth = $0 }
        .onAppear {
            if reduceMotion { revealed = true } else { DispatchQueue.main.async { revealed = true } }
        }
    }

    private func row(_ usage: FlowCategoryUsage, index: Int) -> some View {
        let total = max(1, rows.reduce(0) { $0 + $1.words })
        let maxShare = Double(rows.first?.words ?? 1) / Double(total)
        let share = Double(usage.words) / Double(total)
        let target = max(35, 0.55 * innerWidth * CGFloat(share / max(maxShare, 0.0001)))

        return HStack(spacing: 14) {
            InsightsIcon(Self.iconName(usage.category), fallback: Self.iconFallback(usage.category), size: 24,
                         color: FlowColor.foreground)
                .frame(width: 24, height: 24)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Self.barColor(index: index))
                Text("\(Int((share * 100).rounded()))%")
                    .font(FlowFont.sans(12, weight: 600))
                    .foregroundStyle(FlowColor.sand50)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .opacity(revealed ? 1 : 0)
            }
            .frame(width: revealed ? target : 0, height: 28, alignment: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.6).delay(Double(index) * 0.025), value: revealed)

            Text(Self.label(for: usage))
                .flowText(.label)
                .foregroundStyle(FlowColor.foregroundTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .flowHint(Self.level(words: usage.words))
    }

    static func barColor(index: Int) -> Color {
        switch index {
        case 0: return FlowColor.fathom900
        case 1: return FlowColor.fathom700
        default: return FlowColor.fathom500
        }
    }

    static func level(words: Int) -> String {
        if words >= 10_000 { return "Power user" }
        if words >= 1_000 { return "Moderate use" }
        return "Light use"
    }

    static func label(for usage: FlowCategoryUsage) -> String {
        let n = usage.dictations
        func ceilDiv(_ value: Int, _ divisor: Int) -> Int { (value + divisor - 1) / divisor }
        switch usage.category {
        case .other: return "\(InsightsFormat.number(n)) other tasks"
        case .ai: return "\(InsightsFormat.number(n)) AI prompts"
        case .document: return "\(InsightsFormat.number(ceilDiv(n, 5))) documents"
        case .email: return "\(InsightsFormat.number(ceilDiv(n, 2))) emails"
        case .personal: return "\(InsightsFormat.number(n)) personal messages"
        case .work: return "\(InsightsFormat.number(n)) work messages"
        }
    }

    static func iconName(_ category: FlowAppCategory) -> String {
        switch category {
        case .other: return "infinity"
        case .ai: return "bot"
        case .document: return "file-text"
        case .email: return "mail"
        case .personal: return "message-circle-more"
        case .work: return "message-square-text"
        }
    }

    static func iconFallback(_ category: FlowAppCategory) -> String {
        switch category {
        case .other: return "infinity"
        case .ai: return "cpu"
        case .document: return "doc.text"
        case .email: return "envelope"
        case .personal: return "bubble.left"
        case .work: return "text.bubble"
        }
    }
}
