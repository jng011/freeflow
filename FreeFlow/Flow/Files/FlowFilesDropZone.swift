import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Dashed drop target at the top of the Files page.
struct FlowFilesDropZone: View {
    var onChoose: () -> Void
    var onDrop: ([URL]) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        VStack(spacing: 8) {
            FlowFilesIcon("file-up", fallback: "doc.badge.arrow.up", size: 24, color: FlowColor.foregroundTertiary)
            Text("Drop audio or video files here")
                .flowText(.mdStrong)
                .foregroundStyle(FlowColor.foreground)
            Text("MP3, M4A, WAV, MP4, MOV and more")
                .flowText(.sm)
                .foregroundStyle(FlowColor.foregroundTertiary)
            Button("Choose files", action: onChoose)
                .buttonStyle(FlowButtonStyle(variant: .outline, size: .sm))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .background(shape.fill(isTargeted ? targetFill : FlowColor.background))
        .overlay {
            if isTargeted {
                shape.strokeBorder(FlowColor.hex(0xA26EC1, alpha: 1), lineWidth: 1.5)
            } else {
                shape.strokeBorder(FlowColor.chipBorder, style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
            }
        }
        .contentShape(shape)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            FlowFilesDropZone.loadURLs(from: providers, completion: onDrop)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop audio or video files here")
    }

    private var targetFill: Color {
        colorScheme == .dark ? FlowColor.hex(0x3C2947, alpha: 1) : FlowColor.hex(0xFCF7FF, alpha: 1)
    }

    /// Resolves dropped item providers to file URLs and hands them back on the main actor.
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return }

        let group = DispatchGroup()
        let lock = NSLock()
        var results: [(Int, URL)] = []

        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock()
                    results.append((index, url))
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let urls = results.sorted { $0.0 < $1.0 }.map(\.1)
            guard !urls.isEmpty else { return }
            completion(urls)
        }
    }

    /// Opens the system file picker for supported audio and video files.
    @MainActor
    static func presentOpenPanel(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose files to transcribe"
        panel.prompt = "Transcribe"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types = SupportedMedia.contentTypes
        for ext in SupportedMedia.extensions.sorted() {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        panel.allowedContentTypes = types
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            DispatchQueue.main.async { completion(urls) }
        }
    }
}

/// Lucide icon by raw name with an SF Symbol fallback, so Files does not depend on icon case names.
struct FlowFilesIcon: View {
    let name: String
    let fallback: String
    let size: CGFloat
    let stroke: CGFloat
    let color: Color?

    init(_ name: String, fallback: String, size: CGFloat = 20, stroke: CGFloat = 2, color: Color? = nil) {
        self.name = name
        self.fallback = fallback
        self.size = size
        self.stroke = stroke
        self.color = color
    }

    var body: some View {
        if let iconName = FlowIconName(rawValue: name) {
            FlowIcon(iconName, size: size, stroke: stroke, color: color)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.8))
                .foregroundStyle(color ?? .primary)
                .frame(width: size, height: size)
        }
    }
}
