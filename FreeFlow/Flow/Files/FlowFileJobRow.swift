import AppKit
import SwiftUI

/// One file in the Files queue.
struct FlowFileJobRow: View {
    let job: FlowFileJob
    var onOpen: () -> Void

    @ObservedObject private var store = FlowFilesStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var preview: String?
    @State private var isHovering = false
    @State private var showMoreMenu = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            fileTile
            VStack(alignment: .leading, spacing: 4) {
                Text(job.filename)
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                metaLine
                if job.status == FlowFileJob.Status.processing || job.status == FlowFileJob.Status.pending {
                    progressBar
                        .padding(.top, 4)
                }
                if job.isFailed, let message = job.errorMessage {
                    Text(message)
                        .flowText(.xs)
                        .foregroundStyle(FlowColor.destructive)
                        .lineLimit(2)
                }
                if job.isCompleted, let preview, !preview.isEmpty {
                    Text(preview)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundSecondary)
                        .lineLimit(3)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(16)
        .background(job.isCompleted && isHovering ? FlowColor.backgroundTertiary : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(FlowMotion.standard) { isHovering = hovering }
        }
        .onTapGesture {
            if job.isCompleted { onOpen() }
        }
        .task(id: job.transcriptionID) { loadPreview() }
    }

    // MARK: - Pieces

    private var fileTile: some View {
        FlowFilesIcon("file-volume", fallback: "waveform.badge.plus", size: 20, color: FlowColor.foreground)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FlowColor.backgroundTertiary)
            )
    }

    private var metaLine: some View {
        HStack(spacing: 8) {
            Text(metaText)
                .flowText(.xs)
                .foregroundStyle(FlowColor.foregroundTertiary)
                .lineLimit(1)
            if job.origin == .mcp {
                Text("From Claude")
                    .flowText(.xsEmph)
                    .foregroundStyle(FlowColor.hex(0xA26EC1, alpha: 1))
                    .padding(.vertical, 2)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(FlowColor.hex(0xFAF1FF, alpha: 1))
                    )
            }
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if let duration = job.audioDuration, duration > 0 {
            parts.append(FlowFileFormat.duration(duration))
        }
        if let size = job.fileSize, size > 0 {
            parts.append(FlowFileFormat.size(size))
        }
        parts.append(statusText)
        return parts.joined(separator: " · ")
    }

    private var statusText: String {
        switch job.status {
        case FlowFileJob.Status.pending:
            return "Waiting..."
        case FlowFileJob.Status.processing:
            return store.phaseText[job.id] ?? "Transcribing..."
        case FlowFileJob.Status.completed:
            return "Done"
        case FlowFileJob.Status.canceled:
            return "Canceled"
        default:
            return "Failed"
        }
    }

    private var progressBar: some View {
        let value = min(1, max(0, store.progress[job.id] ?? 0))
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(colorScheme == .dark ? FlowColor.hex(0x464544, alpha: 1) : FlowColor.hex(0xC5C0B3, alpha: 1))
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(FlowColor.hex(0x1A5C5C, alpha: 1))
                    .frame(width: proxy.size.width * value)
                    .animation(.linear(duration: 0.25), value: value)
            }
        }
        .frame(height: 4)
        .frame(maxWidth: 360)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            if job.isActive {
                FlowFilesRowButton(icon: "x", fallback: "xmark", hint: "Cancel") {
                    store.cancel(jobID: job.id)
                }
            } else if job.isFailed || job.status == FlowFileJob.Status.canceled {
                FlowFilesRowButton(icon: "rotate-cw", fallback: "arrow.clockwise", hint: "Retry") {
                    store.retry(jobID: job.id)
                }
                FlowFilesRowButton(icon: "x", fallback: "xmark", hint: "Remove from list") {
                    store.remove(jobID: job.id)
                }
            } else if job.isCompleted {
                FlowFilesRowButton(icon: "copy", fallback: "doc.on.doc", hint: "Copy text") {
                    if let text = store.displayText(for: job) { FlowFileExporter.copy(text) }
                }
                FlowFilesRowButton(icon: "download", fallback: "arrow.down.to.line", hint: "Export") {
                    if let text = store.displayText(for: job) {
                        FlowFileExporter.export(
                            text: text,
                            job: job,
                            duration: store.transcription(for: job)?.duration ?? job.audioDuration
                        )
                    }
                }
                FlowFilesRowButton(icon: "ellipsis-vertical", fallback: "ellipsis", hint: "More") {
                    showMoreMenu.toggle()
                }
                .popover(isPresented: $showMoreMenu, arrowEdge: .bottom) {
                    moreMenu
                }
            }
        }
    }

    private var moreMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            FlowFilesMenuItem(title: "Show audio in Finder", isEnabled: audioLocation != nil) {
                showMoreMenu = false
                if let url = audioLocation {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Rectangle()
                .fill(FlowColor.border)
                .frame(height: 1)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            FlowFilesMenuItem(title: "Remove from list", isDestructive: true) {
                showMoreMenu = false
                store.remove(jobID: job.id)
            }
        }
        .padding(6)
        .frame(minWidth: 160)
        .background(FlowColor.background)
    }

    /// The original file when it still exists, otherwise the converted recording.
    private var audioLocation: URL? {
        if FileManager.default.fileExists(atPath: job.sourcePath) { return job.sourceURL }
        return store.audioURL(for: job)
    }

    private func loadPreview() {
        guard job.isCompleted else {
            preview = nil
            return
        }
        preview = store.displayText(for: job)?
            .replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Row action button (rowAction variant: 28 pt, radius 8, 18 pt icon, hover foreground 8%)

struct FlowFilesRowButton: View {
    let icon: String
    let fallback: String
    let hint: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            FlowFilesIcon(icon, fallback: fallback, size: 18, color: FlowColor.foreground)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering ? FlowColor.foreground.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovering ? 0.8 : 1)
        .onHover { hovering in
            withAnimation(FlowMotion.standard) { isHovering = hovering }
        }
        .help(hint)
        .accessibilityLabel(hint)
    }
}

// MARK: - Menu item (FlowMenu item metrics)

struct FlowFilesMenuItem: View {
    let title: String
    var isDestructive = false
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .flowText(.sm)
                .foregroundStyle(isDestructive ? FlowColor.hex(0xEE6A6A, alpha: 1) : FlowColor.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hoverFill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
    }

    private var hoverFill: Color {
        guard isHovering, isEnabled else { return .clear }
        return isDestructive ? FlowColor.destructive.opacity(0.1) : FlowColor.backgroundTertiary
    }
}
