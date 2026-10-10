import AppKit
import SwiftUI

// Onboarding pages after Try it: what makes Free Flow different, and how AI agents
// can read your dictations over a local MCP connection. Also holds FlowAgentSetupBox,
// shared with Settings > Data and Privacy.

// MARK: - 7. Features

struct FlowFeaturesPage: View {
    @ObservedObject var model: FlowOnboardingModel

    var body: some View {
        FlowOnboardingSplit(
            showsBack: true,
            onBack: { model.goBack() },
            ctaTitle: "Continue",
            onCTA: { model.performPrimary() }
        ) {
            FlowOnboardingTitle(
                title: "What makes Free Flow different",
                description: "A few things worth knowing before you start."
            )
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(FlowFeatureItem.all) { item in
                    FlowFeatureRow(item: item)
                }
            }
        } right: {
            FlowPromptModeIllustration()
        }
    }
}

/// Icon for a feature row: a Lucide icon or an SF Symbol.
private enum FlowFeatureGlyph {
    case icon(FlowIconName)
    case symbol(String)
}

private struct FlowFeatureItem: Identifiable {
    let id: String
    let glyph: FlowFeatureGlyph
    let title: String
    let detail: String

    static let all: [FlowFeatureItem] = [
        FlowFeatureItem(
            id: "talk",
            glyph: .icon(.keyboard),
            title: "Hold fn to talk",
            detail: "Double tap fn for hands-free."
        ),
        FlowFeatureItem(
            id: "scratch",
            glyph: .icon(.undo2),
            title: "Say \"scratch that\"",
            detail: "Takes back what you just said."
        ),
        FlowFeatureItem(
            id: "prompt",
            glyph: .symbol("wand.and.sparkles"),
            title: "Prompt mode",
            detail: "Hold Ctrl with fn and your rambling becomes a clean AI prompt."
        ),
        FlowFeatureItem(
            id: "siri",
            glyph: .icon(.siri),
            title: "Ask Siri",
            detail: "Start with \"Ask Siri\" and your words go straight to Siri."
        ),
        FlowFeatureItem(
            id: "voice",
            glyph: .icon(.users),
            title: "Only your voice",
            detail: "Free Flow can learn your voice and drop other people's. Settings > General > Voice."
        ),
    ]
}

private struct FlowFeatureGlyphView: View {
    let glyph: FlowFeatureGlyph
    var size: CGFloat = 16
    var color: Color = FlowColor.dawn800

    var body: some View {
        switch glyph {
        case .icon(let name):
            FlowIcon(name, size: size, stroke: 1.75, color: color)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.85, weight: .regular))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

private struct FlowFeatureRow: View {
    let item: FlowFeatureItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FlowFeatureGlyphView(glyph: item.glyph)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.dawn200))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .flowText(.smStrong)
                    .foregroundStyle(FlowColor.foreground)
                Text(item.detail)
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Right panel of the features page: prompt mode turning speech into a clean prompt,
/// plus small chips for the other commands.
private struct FlowPromptModeIllustration: View {
    var body: some View {
        FlowOnboardingWidgetCard {
            HStack(spacing: 12) {
                FlowFeatureGlyphView(glyph: .symbol("wand.and.sparkles"), size: 24)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.dawn200))
                Text("Prompt mode")
                    .flowText(.h4)
                    .foregroundStyle(FlowColor.foreground)
            }

            VStack(alignment: .leading, spacing: 12) {
                bubble(
                    label: "You say",
                    text: "um so can you like make the signup button bigger and maybe blue, and uh it should say get started",
                    fill: FlowColor.backgroundTertiary,
                    textColor: FlowColor.foregroundTertiary
                )
                HStack {
                    Spacer()
                    FlowIcon(.chevronDown, size: 16, stroke: 1.75, color: FlowColor.neutral500)
                    Spacer()
                }
                bubble(
                    label: "Free Flow writes",
                    text: "Make the signup button larger, change its color to blue, and set its label to \"Get started\".",
                    fill: FlowColor.dawn100,
                    textColor: FlowColor.foreground
                )
            }

            HStack(spacing: 8) {
                chip(.icon(.undo2), "Scratch that")
                chip(.icon(.siri), "Ask Siri")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func bubble(label: String, text: String, fill: Color, textColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .flowText(.label)
                .foregroundStyle(FlowColor.neutral500)
            Text(text)
                .flowText(.sm)
                .foregroundStyle(textColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
    }

    private func chip(_ glyph: FlowFeatureGlyph, _ title: String) -> some View {
        HStack(spacing: 6) {
            FlowFeatureGlyphView(glyph: glyph, size: 14, color: FlowColor.foregroundTertiary)
            Text(title)
                .flowText(.xsEmph)
                .foregroundStyle(FlowColor.foreground)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Capsule().fill(FlowColor.backgroundTertiary))
        .overlay(Capsule().strokeBorder(FlowColor.border, lineWidth: 1))
    }
}

// MARK: - 8. AI agents

struct FlowAgentsPage: View {
    @ObservedObject var model: FlowOnboardingModel

    var body: some View {
        FlowOnboardingSplit(
            showsBack: true,
            onBack: { model.goBack() },
            ctaTitle: "Finish",
            onCTA: { model.performPrimary() }
        ) {
            FlowOnboardingTitle(
                title: "Let AI agents see your dictations",
                description: FlowAgentSetup.explanation
            )
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run this in Terminal to connect Claude Code")
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                FlowAgentSetupBox()
                Text("Optional. You can find this later in Settings > Data and Privacy.")
                    .flowText(.xs)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } right: {
            FlowAgentsIllustration()
        }
    }
}

/// Right panel of the agents page: what an agent can do with the connection.
private struct FlowAgentsIllustration: View {
    var body: some View {
        FlowOnboardingWidgetCard {
            HStack(spacing: 12) {
                FlowIcon(.bot, size: 24, stroke: 1.75, color: FlowColor.dawn800)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.dawn200))
                Text("What agents can do")
                    .flowText(.h4)
                    .foregroundStyle(FlowColor.foreground)
            }
            VStack(alignment: .leading, spacing: 12) {
                row(.messageSquareText, "Read and search your dictation history")
                row(.chartColumnBig, "See your stats")
                row(.bookText, "Read your dictionary and add words")
                row(.fileVolume, "Transcribe audio files")
            }
            HStack(alignment: .top, spacing: 10) {
                FlowIcon(.lock, size: 16, stroke: 1.75, color: FlowColor.success)
                    .frame(width: 20, height: 20)
                Text("Runs on this Mac. Nothing leaves it unless the agent sends it.")
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ icon: FlowIconName, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            FlowIcon(icon, size: 16, stroke: 1.75, color: FlowColor.foregroundTertiary)
                .frame(width: 20, height: 20)
            Text(text)
                .flowText(.sm)
                .foregroundStyle(FlowColor.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared: agent setup

enum FlowAgentSetup {
    static let explanation =
        "AI agents like Claude can read your dictation history, stats and dictionary, add dictionary words and transcribe files, through a local MCP connection. Nothing leaves your Mac unless the agent sends it."

    /// Bundled MCP server script.
    static var bundledScript: URL? {
        FlowResources.url("freeflow_mcp", ext: "py", folder: "MCP")
    }

    /// Fixed copy of the script, the same path on every Mac wherever the app lives.
    static var installedScript: URL { FlowPaths.file("freeflow_mcp.py") }

    /// Same text for everyone: the shell expands $HOME when the command is run.
    static let command =
        "claude mcp add free-flow -- python3 \"$HOME/Library/Application Support/\(FlowPaths.bundleFolderName)/freeflow_mcp.py\""

    /// Copies the bundled script to its fixed path when missing or out of date.
    static func installScript() {
        guard let source = bundledScript, let data = try? Data(contentsOf: source) else { return }
        let target = installedScript
        if (try? Data(contentsOf: target)) == data { return }
        try? data.write(to: target, options: .atomic)
    }
}

/// The setup command in a selectable monospaced box with a Copy button.
struct FlowAgentSetupBox: View {
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    private let command = FlowAgentSetup.command

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(command)
                .font(FlowFont.mono(12))
                .foregroundStyle(FlowColor.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                HStack(spacing: 6) {
                    FlowIcon(copied ? .check : .copy, size: 14, stroke: 1.75)
                    Text(copied ? "Copied" : "Copy")
                }
            }
            .buttonStyle(FlowButtonStyle(variant: .outline, size: .xs))
            .fixedSize()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(FlowColor.border, lineWidth: 1))
        .onDisappear { resetTask?.cancel() }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        withAnimation(FlowMotion.standard) { copied = true }
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(FlowMotion.standard) { copied = false }
        }
    }
}
