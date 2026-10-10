import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Home aside: quick stats, the voice profile section and "Get back into your Flow" app cards.
struct FlowHomeAside: View {
    @ObservedObject private var stats = FlowStatsStore.shared
    @ObservedObject private var navigator = FlowNavigator.shared

    static let width: CGFloat = 250

    private var summary: FlowStatsSummary { stats.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            FlowCardStack {
                FlowCardSection(action: openUsage) {
                    statsRows
                }
                FlowCardSection(action: openVoice) {
                    InsightsHomeVoiceSection()
                }
            }

            if !topApps.isEmpty {
                appsSection
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: - Stats

    private var statsRows: some View {
        VStack(alignment: .leading, spacing: 16) {
            statRow(value: Self.compact(summary.totalWords), label: "total words")
            statRow(value: summary.wpm.map { "\($0)" } ?? "--", label: "wpm")
            streakRow
        }
    }

    @ViewBuilder
    private var streakRow: some View {
        if summary.dayStreak == 0 && summary.weekStreak > 0 {
            statRow(value: "\(summary.weekStreak)", label: "week streak")
        } else {
            statRow(value: "\(summary.dayStreak)", label: "day streak")
        }
    }

    private func statRow(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if summary.isLoading {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(FlowColor.neutral200)
                    .frame(width: 48, height: 28)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 6 }
            } else {
                Text(value)
                    .flowText(.serif28)
                    .foregroundStyle(FlowColor.foreground)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(label)
                .flowText(.md)
                .foregroundStyle(FlowColor.foreground)
                .lineLimit(1)
        }
    }

    private func openUsage() {
        navigator.insightsTab = 0
        navigator.open(.insights)
    }

    private func openVoice() {
        navigator.insightsTab = 1
        navigator.open(.insights)
    }

    /// Under 1,000 plain; then one decimal with K or M ("375.5K").
    static func compact(_ value: Int) -> String {
        let number = Double(value)
        switch abs(value) {
        case ..<1000:
            return "\(value)"
        case ..<1_000_000:
            return String(format: "%.1fK", number / 1000)
        default:
            return String(format: "%.1fM", number / 1_000_000)
        }
    }

    // MARK: - Apps

    private var topApps: [FlowAppUsage] {
        Array(
            summary.topApps
                .filter { !$0.bundleID.isEmpty && $0.words > 0 }
                .sorted { $0.words > $1.words }
                .prefix(3)
        )
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            (Text("Get back into your ")
                .font(FlowFont.serif(28))
                + Text("flow").font(FlowFont.serif(28, italic: true)))
                .tracking(-1.12)
                .foregroundStyle(FlowColor.foreground)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(topApps) { app in
                    FlowHomeAppCard(app: app)
                }
            }
        }
    }
}

/// One "Get back into your Flow" card: app icon, name and an external-link glyph. Click launches the app.
private struct FlowHomeAppCard: View {
    let app: FlowAppUsage

    @State private var hovering = false

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
    }

    private var icon: NSImage {
        if let url = appURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: launch) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(app.name)
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                    .lineLimit(1)
                Spacer(minLength: 4)
                FlowIcon(.externalLink, size: 12, color: FlowColor.foregroundTertiary)
            }
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 20, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(hovering ? FlowColor.backgroundTertiary : FlowColor.shadeWhite))
            .overlay(shape.strokeBorder(FlowColor.border, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(appURL == nil)
        .onHover { inside in
            withAnimation(FlowMotion.standard) { hovering = inside }
        }
        .accessibilityLabel("Open \(app.name)")
    }

    private func launch() {
        guard let url = appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
