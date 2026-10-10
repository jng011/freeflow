import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Carousel of shareable stat cards with "Copy image" and "Download".
struct InsightsShareSheet: View {
    var initialTab: Int = 0
    var onClose: () -> Void

    @ObservedObject private var store = FlowStatsStore.shared
    @ObservedObject private var service = FlowVoiceProfileService.shared
    @State private var index = 0

    private var cards: [InsightsShareCardKind] {
        var kinds: [InsightsShareCardKind] = [.highlights, .totalWords, .streak, .speed, .heatmap, .categories]
        if service.profile != nil { kinds.append(.voice) }
        return kinds
    }

    var body: some View {
        let kinds = cards
        let current = kinds[min(index, kinds.count - 1)]
        VStack(spacing: 24) {
            HStack {
                Text("Share your insights")
                    .flowText(.h4)
                    .foregroundStyle(FlowColor.foreground)
                Spacer()
                Text("\(min(index, kinds.count - 1) + 1) of \(kinds.count)")
                    .flowText(.xs)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            }

            HStack(spacing: 12) {
                navButton("chevron-left", fallback: "chevron.left", enabled: index > 0) { index -= 1 }
                card(current)
                    .id(current)
                    .transition(.opacity)
                navButton("chevron-right", fallback: "chevron.right", enabled: index < kinds.count - 1) { index += 1 }
            }
            .animation(FlowMotion.standard, value: index)

            HStack(spacing: 6) {
                ForEach(kinds.indices, id: \.self) { dot in
                    Circle()
                        .fill(dot == index ? FlowColor.foreground : FlowColor.neutral300)
                        .frame(width: 6, height: 6)
                }
            }

            HStack(spacing: 12) {
                Button("Close", action: onClose)
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .md))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    copyImage(current)
                } label: {
                    HStack(spacing: 8) {
                        InsightsIcon("copy", fallback: "doc.on.doc", size: 16)
                        Text("Copy image")
                    }
                }
                .buttonStyle(FlowButtonStyle(variant: .outline, size: .md))
                Button {
                    download(current)
                } label: {
                    HStack(spacing: 8) {
                        InsightsIcon("download", fallback: "arrow.down.to.line", size: 16, color: FlowColor.primaryForeground)
                        Text("Download")
                    }
                }
                .buttonStyle(FlowButtonStyle(variant: .primary, size: .md))
            }
        }
        .padding(24)
        .frame(width: 691 + 2 * 44 + 48)
        .background(FlowColor.background)
        .onAppear {
            if initialTab == 1, let voice = kinds.firstIndex(of: .voice) { index = voice }
        }
    }

    private func navButton(_ name: String, fallback: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            InsightsIcon(name, fallback: fallback, size: 18, color: FlowColor.foreground)
                .frame(width: 32, height: 32)
                .background(Circle().fill(FlowColor.backgroundTertiary))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    private func card(_ kind: InsightsShareCardKind) -> some View {
        InsightsShareCard(kind: kind, summary: store.summary, profile: service.profile, animated: true)
    }

    // MARK: Export

    @MainActor
    private func renderPNG(_ kind: InsightsShareCardKind) -> Data? {
        let content = InsightsShareCard(kind: kind, summary: store.summary, profile: service.profile, animated: false)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func copyImage(_ kind: InsightsShareCardKind) {
        guard let png = renderPNG(kind) else {
            FlowToastCenter.shared.show("The image could not be created", style: .error)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        FlowToastCenter.shared.show("Image copied", style: .success)
    }

    private func download(_ kind: InsightsShareCardKind) {
        guard let png = renderPNG(kind) else {
            FlowToastCenter.shared.show("The image could not be created", style: .error)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Free Flow insights.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                Task { @MainActor in
                    FlowToastCenter.shared.show(error.localizedDescription, title: "Could not save image", style: .error)
                }
            }
        }
    }
}

enum InsightsShareCardKind: Hashable {
    case highlights, totalWords, streak, speed, heatmap, categories, voice
}

/// One 691 pt share card. Colors are fixed (not appearance dependent) so exports look the same everywhere.
struct InsightsShareCard: View {
    var kind: InsightsShareCardKind
    var summary: FlowStatsSummary
    var profile: FlowVoiceProfile?
    var animated: Bool

    private var background: Color {
        switch kind {
        case .highlights: return FlowColor.dawn500
        case .totalWords: return FlowColor.chord600
        case .streak: return FlowColor.glow300
        case .speed: return FlowColor.vast950
        case .heatmap: return FlowColor.fathom900
        case .categories: return FlowColor.flare400
        case .voice: return FlowColor.fathom950
        }
    }

    private var isDark: Bool {
        switch kind {
        case .totalWords, .speed, .heatmap, .voice: return true
        case .highlights, .streak, .categories: return false
        }
    }

    private var ink: Color { isDark ? FlowColor.lumen : FlowColor.vast950 }
    private var mutedInk: Color { ink.opacity(0.72) }

    private var title: String {
        switch kind {
        case .highlights: return "My Free Flow highlights"
        case .totalWords: return "Words I've dictated"
        case .streak: return "My dictation streak"
        case .speed: return "How fast I speak"
        case .heatmap: return "My last 12 weeks"
        case .categories: return "Where I Flow"
        case .voice: return "My voice profile"
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(background)

            FlowLogoMark(height: 286, color: ink)
                .rotationEffect(.degrees(16))
                .opacity(0.08)
                .offset(x: 440, y: 230)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 24) {
                Text(title)
                    .font(FlowFont.sans(32, weight: 600))
                    .foregroundStyle(ink)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 8) {
                    FlowLogoMark(height: 20, color: ink)
                    Text("Free Flow")
                        .font(FlowFont.sans(22, weight: 650))
                        .tracking(-0.4)
                }
                .foregroundStyle(ink)
            }
            .padding(40)
        }
        .foregroundStyle(ink)
        .environment(\.colorScheme, isDark ? .dark : .light)
        .frame(width: 691)
        .frame(minHeight: 468)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .highlights:
            Grid(horizontalSpacing: 24, verticalSpacing: 24) {
                GridRow {
                    stat("\(InsightsFormat.number(summary.dayStreak))", "day streak")
                    stat(InsightsFormat.number(summary.totalWords), "total words")
                }
                GridRow {
                    stat(summary.wpm.map { InsightsFormat.number($0) } ?? "0", "words per minute")
                    stat(InsightsFormat.number(summary.appsUsed), "apps used")
                }
            }
        case .totalWords:
            VStack(spacing: 12) {
                Text(InsightsFormat.number(summary.totalWords))
                    .flowText(.serif72)
                Text("words dictated with Free Flow")
                    .flowText(.lg)
                    .foregroundStyle(mutedInk)
                if let fact = summary.funFact {
                    Text(fact).flowText(.md).foregroundStyle(mutedInk)
                }
            }
        case .streak:
            VStack(spacing: 12) {
                Text(InsightsFormat.number(summary.dayStreak))
                    .flowText(.serif72)
                Text(summary.dayStreak == 1 ? "day streak" : "day streak, and counting")
                    .flowText(.lg)
                if summary.longestDayStreak > 0 {
                    Text("Longest streak: \(summary.longestDayStreak) \(summary.longestDayStreak == 1 ? "day" : "days")")
                        .flowText(.md)
                        .foregroundStyle(mutedInk)
                }
            }
        case .speed:
            VStack(spacing: 16) {
                Text("\(summary.wpm.map { InsightsFormat.number($0) } ?? "0") words per minute")
                    .flowText(.serif48)
                if let wpm = summary.wpm, let top = summary.wpmTopPercent {
                    InsightsGauge(
                        percentile: FlowTypingPercentile.percentile(forWPM: wpm),
                        topPercentText: FlowTypingPercentile.displayTopPercent(top),
                        animated: animated,
                        trackColor: FlowColor.vast800,
                        fillColor: FlowColor.fathom400,
                        labelColor: FlowColor.lumen,
                        secondaryLabelColor: FlowColor.lumen.opacity(0.72)
                    )
                    .scaleEffect(1.4)
                    .frame(width: 220, height: 124)
                    Text(FlowTypingPercentile.tooltip)
                        .flowText(.sm)
                        .foregroundStyle(mutedInk)
                }
            }
        case .heatmap:
            VStack(alignment: .leading, spacing: 16) {
                InsightsHeatmapGrid(
                    dailyWords: summary.dailyWords,
                    firstDay: summary.firstDay,
                    dayStreak: summary.dayStreak,
                    columns: 12,
                    endWeekStart: InsightsHeatmapGrid.weekStart(for: Date(), calendar: InsightsHeatmapGrid.gridCalendar),
                    animatesIn: animated,
                    labelColor: mutedInk
                )
                Text("\(summary.dayStreak) day streak  |  \(InsightsFormat.number(summary.totalWords)) words")
                    .flowText(.md)
                    .foregroundStyle(mutedInk)
            }
        case .categories:
            categories
        case .voice:
            if let profile {
                HStack(alignment: .center, spacing: 40) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(profile.superpowerTitle).flowText(.serif48)
                        Text(profile.superpowerDescription)
                            .flowText(.lg)
                            .foregroundStyle(mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    InsightsPersonaTile(persona: profile.persona)
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(FlowFont.sans(44, weight: 600))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .flowText(.label)
                .foregroundStyle(mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categories: some View {
        let rows = summary.categories.filter { $0.words > 0 }.sorted { $0.words > $1.words }.prefix(5)
        let total = max(1, rows.reduce(0) { $0 + $1.words })
        let maxWords = max(1, rows.first?.words ?? 1)
        return VStack(alignment: .leading, spacing: 14) {
            if rows.isEmpty {
                Text("Dictate in a few apps to see where you Flow.")
                    .flowText(.lg)
            }
            ForEach(Array(rows), id: \.category) { usage in
                HStack(spacing: 14) {
                    InsightsIcon(InsightsDesktopUsage.iconName(usage.category),
                                 fallback: InsightsDesktopUsage.iconFallback(usage.category), size: 24, color: ink)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(FlowColor.vast950)
                        .frame(width: max(44, 300 * CGFloat(usage.words) / CGFloat(maxWords)), height: 28)
                        .overlay(alignment: .leading) {
                            Text("\(Int((Double(usage.words) / Double(total) * 100).rounded()))%")
                                .font(FlowFont.sans(12, weight: 600))
                                .foregroundStyle(FlowColor.sand50)
                                .padding(.horizontal, 8)
                        }
                    Text(InsightsDesktopUsage.label(for: usage))
                        .flowText(.label)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
