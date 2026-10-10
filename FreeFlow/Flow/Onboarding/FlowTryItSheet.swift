import SwiftUI

// "Try it" practice: a mock chat with a focused text box that the person dictates
// into. Used as the last onboarding page, from Settings ("Learn more") and the home banner.

/// Keys of the push-to-talk shortcut, written the way Flow shows them ("fn").
enum FlowTryItKeys {
    static var primary: [String] {
        let tokens = FlowShortcutRules.tokens(ShortcutStore.shortcut(for: .primaryRecording))
        return tokens.isEmpty ? ["fn"] : tokens
    }
}

/// "Flow starts listening when you hold [fn]" plus the description.
struct FlowTryItHeadline: View {
    var titleSize: CGFloat = 32
    @State private var keys = FlowTryItKeys.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("Free Flow starts listening when you hold")
                    .font(FlowFont.sans(titleSize, weight: 600))
                    .foregroundStyle(FlowColor.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                FlowKeycap(keys: keys, inline: true, fontSize: titleSize * 0.6)
                    .fixedSize()
            }
            Text("It'll paste what you said when you let go.")
                .flowText(titleSize >= 32 ? .lgEmph : .mdEmph)
                .foregroundStyle(FlowColor.foregroundTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            keys = FlowTryItKeys.primary
        }
    }
}

/// Mock chat card with a focused composer. `didSucceed` flips once dictated text arrives.
struct FlowTryItPracticeCard: View {
    @Binding var text: String
    @Binding var didSucceed: Bool

    @ObservedObject private var dictation = FlowDictationState.shared
    @FocusState private var isFocused: Bool
    @State private var showsCoaching = false
    @State private var coachingTask: Task<Void, Never>?
    @State private var keys = FlowTryItKeys.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(FlowColor.border).frame(height: 1)
            messages
            composer
        }
        .frame(maxWidth: 380)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.background))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(FlowColor.border, lineWidth: 1))
        .flowShadow(.lg)
        .overlay(alignment: .topTrailing) {
            if didSucceed {
                FlowWellDoneSticker()
                    .offset(x: 18, y: -18)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.3), value: didSucceed)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isFocused = true }
        }
        .onDisappear {
            coachingTask?.cancel()
        }
        .onChange(of: text) { _, newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showsCoaching = false
                if !didSucceed { didSucceed = true }
            }
        }
        .onChange(of: dictation.phase) { oldValue, newValue in
            guard newValue == .idle, oldValue != .idle else {
                if newValue != .idle { showsCoaching = false }
                return
            }
            coachingTask?.cancel()
            coachingTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    withAnimation(FlowMotion.standard) { showsCoaching = true }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            keys = FlowTryItKeys.primary
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(FlowColor.dawn500)
                .frame(width: 28, height: 28)
                .overlay(
                    Text("J")
                        .font(FlowFont.sans(13, weight: 600))
                        .foregroundStyle(FlowColor.vast950)
                )
            VStack(alignment: .leading, spacing: 0) {
                Text("Sam")
                    .flowText(.smStrong)
                    .foregroundStyle(FlowColor.foreground)
                Text("Practice chat")
                    .flowText(.xs)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hey! What are you up to this weekend?")
                .flowText(.sm)
                .foregroundStyle(FlowColor.foreground)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.backgroundTertiary))
                .fixedSize(horizontal: false, vertical: true)

            if showsCoaching {
                HStack(alignment: .top, spacing: 8) {
                    FlowIcon(.lightbulb, size: 14, stroke: 1.75, color: FlowColor.dawn800)
                    Text("Tap once to keep listening, tap again to finish. Or hold while you talk.")
                        .flowText(.xs)
                        .foregroundStyle(FlowColor.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.chipActiveFill))
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
    }

    private var composer: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(FlowFont.sans(15))
                .foregroundStyle(FlowColor.foreground)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
            if text.isEmpty {
                Text("Hold down \(keys.joined(separator: " + ")), say something, then release.")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 96)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.background))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? FlowColor.neutral500 : FlowColor.neutral300, lineWidth: isFocused ? 2 : 1)
        )
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}

/// Rotated dawn500 capsule with "Well done!".
struct FlowWellDoneSticker: View {
    var body: some View {
        Text("Well done!")
            .font(FlowFont.sans(15, weight: 600))
            .foregroundStyle(FlowColor.vast950)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Capsule().fill(FlowColor.dawn500))
            .overlay(Capsule().strokeBorder(FlowColor.dawn700, lineWidth: 1))
            .rotationEffect(.degrees(-8))
            .flowShadow(.md)
    }
}

/// 720x480 practice sheet with a Done button (Settings "Learn more" and the home banner).
struct FlowTryItSheet: View {
    var onDone: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var didSucceed = false

    init(onDone: (() -> Void)? = nil) {
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 32) {
                FlowTryItHeadline(titleSize: 24)
                    .frame(maxWidth: 260, alignment: .leading)
                FlowTryItPracticeCard(text: $text, didSucceed: $didSucceed)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button("Done") { close() }
                    .buttonStyle(FlowButtonStyle(variant: .primary, size: .md))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
        }
        .frame(width: 720, height: 480)
        .background(FlowColor.backgroundTertiary)
    }

    private func close() {
        if let onDone {
            onDone()
        } else {
            dismiss()
        }
    }
}
