import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Full transcript for a finished file, with Cleaned / Original tabs, copy and export.
struct FlowFileResultSheet: View {
    let job: FlowFileJob
    var onClose: () -> Void

    @ObservedObject private var store = FlowFilesStore.shared
    @State private var tab: Tab = .cleaned
    @Namespace private var tabNamespace

    enum Tab: String, CaseIterable, Identifiable {
        case cleaned = "Cleaned"
        case original = "Original"
        var id: String { rawValue }
    }

    private var transcription: Transcription? { store.transcription(for: job) }

    private var cleanedText: String? {
        guard let enhanced = transcription?.enhancedText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !enhanced.isEmpty
        else { return nil }
        return enhanced
    }

    private var availableTabs: [Tab] { cleanedText == nil ? [.original] : [.cleaned, .original] }

    private var effectiveTab: Tab { availableTabs.contains(tab) ? tab : .original }

    private var shownText: String {
        switch effectiveTab {
        case .cleaned: return cleanedText ?? transcription?.text ?? ""
        case .original: return transcription?.text ?? ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            tabs
            textArea
            footer
        }
        .padding(24)
        .frame(width: 720, height: 560)
        .background(FlowColor.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onExitCommand(perform: onClose)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(job.filename)
                .flowText(.h4)
                .foregroundStyle(FlowColor.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(subtitle)
                .flowText(.sm)
                .foregroundStyle(FlowColor.foregroundTertiary)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        let duration = transcription?.duration ?? job.audioDuration
        if let duration, duration > 0 { parts.append(FlowFileFormat.duration(duration)) }
        let date = job.finishedAt ?? transcription?.timestamp ?? job.addedAt
        parts.append(date.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private var tabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(availableTabs) { item in
                    let selected = item == effectiveTab
                    Button {
                        withAnimation(FlowMotion.standard) { tab = item }
                    } label: {
                        Text(item.rawValue)
                            .flowText(.smStrong)
                            .foregroundStyle(selected ? FlowColor.foreground : FlowColor.neutral500)
                            .padding(12)
                            .overlay(alignment: .bottom) {
                                if selected {
                                    Rectangle()
                                        .fill(FlowColor.neutral800)
                                        .frame(height: 2)
                                        .matchedGeometryEffect(id: "underline", in: tabNamespace)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .offset(x: -12)
            Rectangle().fill(FlowColor.border).frame(height: 1)
        }
    }

    private var textArea: some View {
        ScrollView {
            Text(shownText.isEmpty ? "No text was transcribed." : shownText)
                .flowText(.sm)
                .foregroundStyle(shownText.isEmpty ? FlowColor.foregroundTertiary : FlowColor.foregroundSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowColor.backgroundTertiary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Close", action: onClose)
                .buttonStyle(FlowButtonStyle(variant: .ghost, size: .md))
                .keyboardShortcut(.cancelAction)
            Button("Copy") {
                FlowFileExporter.copy(shownText)
            }
            .buttonStyle(FlowButtonStyle(variant: .secondary, size: .md))
            .disabled(shownText.isEmpty)
            Button("Export") {
                FlowFileExporter.export(text: shownText, job: job, duration: transcription?.duration)
            }
            .buttonStyle(FlowButtonStyle(variant: .primary, size: .md))
            .disabled(shownText.isEmpty)
        }
    }
}

// MARK: - Formatting

enum FlowFileFormat {
    /// m:ss, or h:mm:ss for an hour or more.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func size(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes < 0.1 { return "<0.1 MB" }
        if megabytes < 10 { return String(format: "%.1f MB", megabytes) }
        return String(format: "%.0f MB", megabytes)
    }
}

// MARK: - Copy and export

@MainActor
enum FlowFileExporter {
    enum Format: Int, CaseIterable {
        case text = 0
        case markdown = 1

        var title: String {
            switch self {
            case .text: return "Plain text (.txt)"
            case .markdown: return "Markdown (.md)"
            }
        }

        var fileExtension: String {
            switch self {
            case .text: return "txt"
            case .markdown: return "md"
            }
        }

        var contentType: UTType {
            switch self {
            case .text: return .plainText
            case .markdown: return UTType(filenameExtension: "md") ?? .plainText
            }
        }
    }

    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        FlowToastCenter.shared.show("Copied", style: .success)
    }

    static func export(text: String, job: FlowFileJob, duration: TimeInterval?) {
        let panel = NSSavePanel()
        panel.title = "Export transcript"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let baseName = (job.filename as NSString).deletingPathExtension
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in Format.allCases { popup.addItem(withTitle: format.title) }
        popup.selectItem(at: Format.text.rawValue)

        let handler = FormatPopupHandler(panel: panel, baseName: baseName)
        popup.target = handler
        popup.action = #selector(FormatPopupHandler.formatChanged(_:))

        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        panel.accessoryView = stack

        handler.apply(.text)

        panel.begin { response in
            // Keep the handler alive for as long as the panel is up.
            withExtendedLifetime(handler) {}
            guard response == .OK, let url = panel.url else { return }
            let format = Format(rawValue: popup.indexOfSelectedItem) ?? .text
            let body: String
            switch format {
            case .text:
                body = text
            case .markdown:
                var meta: [String] = []
                if let duration, duration > 0 { meta.append("Duration \(FlowFileFormat.duration(duration))") }
                let date = job.finishedAt ?? job.addedAt
                meta.append("Transcribed \(date.formatted(date: .abbreviated, time: .shortened))")
                body = "# \(job.filename)\n\n_\(meta.joined(separator: " · "))_\n\n\(text)\n"
            }
            do {
                try body.write(to: url, atomically: true, encoding: .utf8)
                FlowToastCenter.shared.show("Exported \(url.lastPathComponent)", style: .success)
            } catch {
                FlowToastCenter.shared.show("Could not export the transcript", style: .error)
            }
        }
    }

    private final class FormatPopupHandler: NSObject {
        weak var panel: NSSavePanel?
        let baseName: String

        init(panel: NSSavePanel, baseName: String) {
            self.panel = panel
            self.baseName = baseName
        }

        @MainActor
        func apply(_ format: Format) {
            guard let panel else { return }
            panel.allowedContentTypes = [format.contentType]
            let current = panel.nameFieldStringValue.isEmpty
                ? baseName
                : (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(current).\(format.fileExtension)"
        }

        @MainActor @objc func formatChanged(_ sender: NSPopUpButton) {
            apply(Format(rawValue: sender.indexOfSelectedItem) ?? .text)
        }
    }
}
