import SwiftUI

/// The Insights page: "Your usage" and "Your voice" tabs, with a share button in the title row.
struct InsightsView: View {
    @ObservedObject private var navigator = FlowNavigator.shared
    @ObservedObject private var store = FlowStatsStore.shared
    @State private var isSharing = false

    var body: some View {
        FlowPage(title: "Insights", titleAccessory: {
            InsightsShareButton(tab: navigator.insightsTab) { isSharing = true }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                FlowTabs(items: ["Your usage", "Your voice"], selection: $navigator.insightsTab)
                    .padding(.bottom, 24)

                if navigator.insightsTab == 1 {
                    InsightsVoiceTab()
                } else {
                    InsightsUsageTab()
                }
            }
        }
        .sheet(isPresented: $isSharing) {
            InsightsShareSheet(initialTab: navigator.insightsTab) { isSharing = false }
        }
    }
}

// MARK: - Shared helpers

/// Lucide icon by name with an SF Symbol fallback.
struct InsightsIcon: View {
    var name: String
    var fallback: String
    var size: CGFloat
    var stroke: CGFloat
    var color: Color?

    init(_ name: String, fallback: String, size: CGFloat = 20, stroke: CGFloat = 2, color: Color? = nil) {
        self.name = name
        self.fallback = fallback
        self.size = size
        self.stroke = stroke
        self.color = color
    }

    var body: some View {
        if let icon = FlowIconName(rawValue: name) {
            FlowIcon(icon, size: size, stroke: stroke, color: color)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.8))
                .foregroundStyle(color ?? .primary)
                .frame(width: size, height: size)
        }
    }
}

/// 14 pt info icon with a dark hover hint.
struct InsightsInfoIcon: View {
    var tooltip: String

    var body: some View {
        InsightsIcon("info", fallback: "info.circle", size: 14, color: FlowColor.foregroundTertiary)
            .contentShape(Rectangle())
            .flowHint(tooltip)
            .accessibilityLabel(tooltip)
    }
}

/// 1 pt sand700 (dark vast800) rule with 16 pt vertical margins.
struct InsightsSeparator: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(colorScheme == .dark ? FlowColor.vast800 : FlowColor.sand700)
            .frame(height: 1)
            .padding(.vertical, 16)
    }
}

extension View {
    /// Insights tile: backgroundTertiary fill, 1 pt neutral300 border, radius 8, padding 16.
    func insightsTile() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(FlowColor.neutral300, lineWidth: 1))
    }
}

enum InsightsFormat {
    static func number(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    /// "MMM d, yyyy"
    static func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}
