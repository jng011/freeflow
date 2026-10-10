import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One history row: time, text and hover actions (play, copy, more).
struct FlowHistoryRow: View {
    let transcription: Transcription
    @ObservedObject var model: FlowHistoryModel
    let onSelect: () -> Void

    @ObservedObject private var player = FlowRowAudioPlayer.shared
    @State private var hovering = false
    @State private var confirmDelete = false

    private var isSelected: Bool { model.selectedID == transcription.id }

    private var status: TranscriptionStatus {
        transcription.transcriptionStatus.flatMap(TranscriptionStatus.init(rawValue:)) ?? .completed
    }

    private var audioURL: URL? { transcription.availableHistoryAudioURL }

    private var canPlay: Bool {
        audioURL != nil && Date().timeIntervalSince(transcription.timestamp) < FlowRowAudioPlayer.playableAge
    }

    private var displayText: String { model.displayText(for: transcription) }

    private var isCopyable: Bool {
        status == .completed && !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(Self.timeString(transcription.timestamp))
                .flowText(.time)
                .foregroundStyle(FlowColor.foregroundTertiary)
                .padding(16)
                .frame(width: 98, alignment: .leading)

            textCell
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)

            actions
                .padding(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 0))
                .padding(.trailing, 8)
                .opacity(hovering || isSelected ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: hovering || isSelected)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Clicks that reach the background (not the selectable text) select the row.
            (hovering || isSelected ? FlowColor.backgroundTertiary : FlowColor.background)
                .contentShape(Rectangle())
                .onTapGesture { onSelect() }
        )
        .onHover { inside in
            withAnimation(FlowMotion.standard) { hovering = inside }
        }
        .flowDialog(isPresented: $confirmDelete, primaryAction: performDelete) {
            FlowDialog(
                title: "Are you sure you want to delete this transcript?",
                subtitle: "Once deleted it cannot be recovered"
            ) {
                Button("Cancel") { confirmDelete = false }
                    .buttonStyle(FlowButtonStyle(variant: .secondary))
                Button("Yes, delete it") { performDelete() }
                    .buttonStyle(FlowButtonStyle(variant: .destructive))
            }
        }
    }

    // MARK: - Text cell

    @ViewBuilder
    private var textCell: some View {
        switch status {
        case .pending:
            VStack(alignment: .leading, spacing: 8) {
                FlowSkeletonBar(width: 308, height: 20)
                Text("Transcribing...")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            }
        case .canceled:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                FlowIcon(.info, size: 14, color: FlowColor.foregroundTertiary)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 3 }
                HStack(spacing: 0) {
                    Text("This transcription was dismissed. ")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                    if audioURL != nil {
                        inlineLink("Recover", color: FlowColor.foregroundTertiary, action: retry)
                    }
                }
            }
        case .failed:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                FlowIcon(.circleAlert, size: 14, color: FlowColor.destructive)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 3 }
                HStack(spacing: 0) {
                    Text("Your transcription was interrupted. ")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.destructive)
                    if audioURL != nil {
                        inlineLink("Retry", color: FlowColor.foregroundTertiary, action: retry)
                    }
                }
            }
        case .completed:
            if displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Audio is silent.")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            } else {
                Text(displayText)
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foreground)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func inlineLink(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .flowText(.sm)
                .underline()
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 6) {
            if canPlay, let audioURL {
                FlowIconButton(
                    icon: player.isPlaying(transcription.id) ? .pause : .play,
                    size: .md,
                    variant: .rowAction,
                    help: player.isPlaying(transcription.id) ? "Pause" : "Play"
                ) {
                    player.toggle(id: transcription.id, url: audioURL)
                }
            }
            FlowIconButton(icon: .copy, size: .md, variant: .rowAction, help: "Copy") {
                model.copy(transcription)
            }
            .disabled(!isCopyable)
            FlowMenuButton(icon: .ellipsisVertical, size: .md, variant: .rowAction, alignment: .trailing) {
                menuItems()
            }
            .flowHint("More")
        }
    }

    private func menuItems() -> [FlowMenuItem] {
        var items: [FlowMenuItem] = []
        if transcription.hasEnhancedHistoryText {
            let raw = model.isRaw(transcription)
            items.append(
                .button(raw ? "Redo AI edit" : "Undo AI edit", icon: .undo2) {
                    model.toggleRaw(transcription)
                })
        }
        if audioURL != nil {
            items.append(.button("Retry transcript", icon: .rotateCw) { retry() })
            items.append(.button("Extract audio", icon: .download) { extractAudio() })
        }
        if !items.isEmpty {
            items.append(.divider)
        }
        items.append(
            .button("Delete transcript", icon: .trash, destructive: true) {
                confirmDelete = true
            })
        return items
    }

    private func retry() {
        let id = transcription.id
        Task { await FlowDictationActions.retry(transcriptionID: id) }
    }

    private func performDelete() {
        confirmDelete = false
        model.delete(transcription)
    }

    private func extractAudio() {
        guard let source = audioURL else { return }
        let panel = NSSavePanel()
        let ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension
        panel.nameFieldStringValue = "Free Flow dictation \(Self.fileStamp(transcription.timestamp)).\(ext)"
        if let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                FlowToastCenter.shared.show("The audio could not be saved.", style: .error)
            }
        }
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()

    static func timeString(_ date: Date) -> String {
        timeFormatter.string(from: date).lowercased()
    }

    static func fileStamp(_ date: Date) -> String {
        fileStampFormatter.string(from: date)
    }
}

/// Pulsing neutral placeholder bar.
struct FlowSkeletonBar: View {
    let width: CGFloat?
    let height: CGFloat

    @State private var dim = false

    init(width: CGFloat? = nil, height: CGFloat) {
        self.width = width
        self.height = height
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(FlowColor.neutral200)
            .frame(width: width, height: height)
            .opacity(dim ? 0.5 : 1)
            .onAppear {
                guard !FlowMotion.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
