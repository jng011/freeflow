import AppKit
import SwiftUI

/// Persona to lucide icon mapping shared by the voice tab, the home section and the share card.
enum FlowVoicePersona {
    static func icon(for persona: String?) -> (name: String, fallback: String) {
        switch (persona ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "coding":
            return ("terminal", "terminal")
        case "long writing", "reporting":
            return ("pen-line", "pencil.line")
        case "brainstorm", "idea generation", "thinking", "deep thought", "dreaming":
            return ("lightbulb", "lightbulb")
        case "collaboration", "leadership", "manage", "support":
            return ("users", "person.2")
        case "analysis", "finance":
            return ("chart-column-big", "chart.bar.xaxis")
        case "organize", "multi-tasking", "multitasking":
            return ("sparkles", "sparkles")
        case "on the go":
            return ("compass", "safari")
        case "multilingual":
            return ("languages", "character.bubble")
        default:
            return ("brain", "brain")
        }
    }
}

/// Square persona tile (dawn200 fill) with the persona icon.
struct InsightsPersonaTile: View {
    var persona: String?
    var size: CGFloat = 120
    var radius: CGFloat = 24
    var iconSize: CGFloat = 56

    var body: some View {
        let icon = FlowVoicePersona.icon(for: persona)
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(FlowColor.dawn200)
            .frame(width: size, height: size)
            .overlay {
                InsightsIcon(icon.name, fallback: icon.fallback, size: iconSize, color: FlowColor.dawn800)
            }
            .accessibilityLabel(persona ?? "Voice profile")
    }
}

/// "Your voice": locked, eligible and unlocked states of the Voice Profile.
struct InsightsVoiceTab: View {
    @ObservedObject private var store = FlowStatsStore.shared
    @ObservedObject private var service = FlowVoiceProfileService.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let summary = store.summary
        Group {
            if summary.isLoading {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(FlowColor.neutral200)
                    .frame(height: 428)
            } else if let profile = service.profile {
                unlocked(profile: profile, total: summary.totalWords)
            } else if summary.totalWords < FlowVoiceProfileService.unlockWords {
                locked(total: summary.totalWords)
            } else {
                eligible
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 40)
    }

    // MARK: Locked

    private func locked(total: Int) -> some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Text("Unlocks in \(InsightsFormat.number(max(0, FlowVoiceProfileService.unlockWords - total))) words")
                    .flowText(.serif65)
                    .foregroundStyle(FlowColor.foreground)
                    .multilineTextAlignment(.center)
                Text("Generated on this Mac from your own dictations")
                    .flowText(.lg)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)

            VStack(spacing: 24) {
                InsightsSpanRow(spans: [2, 2]) {
                    placeholderCard(lines: [0.6, 0.9, 0.4])
                    placeholderCard(lines: [0.5, 0.8, 0.7])
                }
                InsightsSpanRow(spans: [2, 2]) {
                    placeholderCard(lines: [0.7, 0.5, 0.9])
                    placeholderCard(lines: [0.4, 0.85, 0.6])
                }
            }
            .blur(radius: 4)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func placeholderCard(lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, fraction in
                GeometryReader { geo in
                    Capsule()
                        .fill(FlowColor.neutral200)
                        .frame(width: geo.size.width * fraction, height: index == 0 ? 22 : 12)
                }
                .frame(height: index == 0 ? 22 : 12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
    }

    // MARK: Eligible

    private var eligible: some View {
        ZStack {
            FlowLogoMark(height: 305, color: FlowColor.logoFill)
                .rotationEffect(.degrees(16))
                .opacity(0.06)
                .offset(x: 220, y: 60)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 24) {
                Text("Your Voice Profile is ready!")
                    .flowText(.serif48)
                    .foregroundStyle(FlowColor.foreground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
                generateControls(title: "Generate profile")
                Text("Your recent dictations are analyzed by your AI cleanup model. Nothing else leaves this Mac.")
                    .font(FlowFont.sans(12).italic())
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, minHeight: 428)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func generateControls(title: String) -> some View {
        VStack(spacing: 12) {
            if !FlowStatsStore.storesRemovedTokens {
                Text(FlowVoiceProfileService.noHistoryMessage)
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .multilineTextAlignment(.center)
            } else if service.state == .generating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building your Voice Profile")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                }
            } else {
                Button(title) { Task { await service.generate() } }
                    .buttonStyle(FlowButtonStyle(variant: .primary, size: .sm))
            }
            if case .failed(let message) = service.state {
                HStack(spacing: 8) {
                    InsightsIcon("circle-alert", fallback: "exclamationmark.circle", size: 14, color: FlowColor.destructive)
                    Text(message)
                        .flowText(.xs)
                        .foregroundStyle(FlowColor.destructive)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: 460)
            }
        }
    }

    // MARK: Unlocked

    private func unlocked(profile: FlowVoiceProfile, total: Int) -> some View {
        let progress = FlowVoiceProfileService.progress(totalWords: total, profile: profile)
        return VStack(alignment: .leading, spacing: 24) {
            progressHeader(profile: profile, progress: progress)
            heroCard(profile)
            InsightsSpanRow(spans: [2, 2]) {
                VStack(spacing: 24) {
                    if !profile.catchPhrase.isEmpty {
                        quoteCard(profile.catchPhrase, label: "Catchphrase", description: profile.catchPhraseDescription)
                    }
                    if let word = profile.mostUsedWord, !word.isEmpty {
                        quoteCard(word, label: "Most used word", description: nil)
                    }
                    if let word = profile.mostCorrectedWord, !word.isEmpty {
                        quoteCard(word, label: "Most corrected word", description: nil)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                peakCard(profile)
            }
        }
    }

    private func progressHeader(profile: FlowVoiceProfile, progress: FlowVoiceProfileService.Progress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark ? FlowColor.vast800 : FlowColor.vast100)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(FlowColor.dawn700)
                        .frame(width: max(8, geo.size.width * progress.fraction))
                }
            }
            .frame(height: 8)

            HStack(spacing: 8) {
                Text("Created \(InsightsFormat.longDate(profile.createdAt))")
                Spacer(minLength: 8)
                if progress.isUpdateReady {
                    Text("Update ready!")
                    if service.state == .generating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Regenerate profile") { Task { await service.generate() } }
                            .buttonStyle(.plain)
                            .underline()
                            .foregroundStyle(FlowColor.dawn700)
                    }
                } else {
                    Text("Next update in \(InsightsFormat.number(progress.remaining)) more words")
                    InsightsInfoIcon(tooltip: "Your profile refreshes as you dictate more")
                }
            }
            .font(FlowFont.sans(12, weight: 550))
            .foregroundStyle(FlowColor.foregroundTertiary)

            if case .failed(let message) = service.state {
                Text(message)
                    .flowText(.xs)
                    .foregroundStyle(FlowColor.destructive)
            }
        }
    }

    private func heroCard(_ profile: FlowVoiceProfile) -> some View {
        HStack(alignment: .center, spacing: 90) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    Text(profile.superpowerTitle)
                        .flowText(.serif36)
                        .lineLimit(1)
                        .fixedSize()
                    Text(profile.superpowerTitle)
                        .flowText(.serif28)
                }
                .foregroundStyle(FlowColor.foreground)
                Text("Voice profile")
                    .flowText(.label)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                Text(profile.superpowerDescription)
                    .flowText(.lg)
                    .foregroundStyle(FlowColor.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            InsightsPersonaTile(persona: profile.persona)
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
    }

    private func quoteCard(_ quote: String, label: String, description: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\u{201C}\(quote)\u{201D}")
                .font(FlowFont.serif(28, italic: true))
                .tracking(-1.12)
                .foregroundStyle(FlowColor.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(label)
                .flowText(.label)
                .foregroundStyle(FlowColor.foregroundTertiary)
            if let description, !description.isEmpty {
                Text(description)
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
    }

    private func peakCard(_ profile: FlowVoiceProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            InsightsAppIcon(bundleID: profile.peakAppBundleID, size: 40)
                .padding(.bottom, 8)
            Text(profile.peakTimeTitle)
                .flowText(.serif28)
                .foregroundStyle(FlowColor.foreground)
            Text("Your peak time & place")
                .flowText(.label)
                .foregroundStyle(FlowColor.foregroundTertiary)
            Text(profile.peakTimeDescription)
                .flowText(.lg)
                .foregroundStyle(FlowColor.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
    }
}

/// App icon from a bundle id, or a neutral monitor glyph.
struct InsightsAppIcon: View {
    var bundleID: String?
    var size: CGFloat = 40

    var body: some View {
        if let image = Self.icon(for: bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(FlowColor.neutral200)
                .frame(width: size, height: size)
                .overlay(InsightsIcon("monitor", fallback: "desktopcomputer", size: size * 0.5, color: FlowColor.foregroundTertiary))
        }
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
