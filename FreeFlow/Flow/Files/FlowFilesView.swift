import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Files" page: drop audio or video files, watch them transcribe, read and export results.
struct FlowFilesView: View {
    @ObservedObject private var store = FlowFilesStore.shared
    @AppStorage("FlowFilesBannerDismissed") private var bannerDismissed = false
    @State private var isPageTargeted = false
    @State private var openJob: FlowFileJob?

    private var sortedJobs: [FlowFileJob] {
        store.jobs.sorted { $0.addedAt > $1.addedAt }
    }

    private var hasFinishedJobs: Bool { store.jobs.contains(where: \.isFinished) }

    var body: some View {
        FlowPage(title: "Files", titleAccessory: { addFilesButton }) {
            VStack(alignment: .leading, spacing: 24) {
                if !bannerDismissed {
                    banner
                }

                FlowFilesDropZone(onChoose: chooseFiles, onDrop: add)

                if store.jobs.isEmpty {
                    Text("Files you transcribe show up here")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                } else {
                    queueSection
                }
            }
            .padding(.bottom, 40)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isPageTargeted) { providers in
            FlowFilesDropZone.loadURLs(from: providers, completion: add)
            return true
        }
        .sheet(item: $openJob) { job in
            FlowFileResultSheet(job: job) { openJob = nil }
        }
    }

    // MARK: - Header

    private var addFilesButton: some View {
        Button {
            chooseFiles()
        } label: {
            HStack(spacing: 8) {
                FlowFilesIcon("plus", fallback: "plus", size: 16, color: FlowColor.primaryForeground)
                Text("Add files")
            }
        }
        .buttonStyle(FlowButtonStyle(variant: .primary, size: .md))
    }

    private var banner: some View {
        FlowFilesBanner(
            title: Text("Drop a recording, get the ") + Text("words").font(FlowFont.serif(36, italic: true)) + Text("."),
            description: Text(
                "Voice memos, meetings, lectures or videos. Free Flow transcribes them and cleans them up like your dictations."
            ),
            onDismiss: {
                withAnimation(FlowMotion.standard) { bannerDismissed = true }
            }
        )
    }

    // MARK: - Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("QUEUE")
                    .flowText(.label)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                Spacer()
                if hasFinishedJobs {
                    Button("Clear finished") {
                        withAnimation(FlowMotion.standard) { store.clearFinished() }
                    }
                    .buttonStyle(FlowButtonStyle(variant: .ghost, size: .xs))
                }
            }

            let jobs = sortedJobs
            VStack(spacing: 0) {
                ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                    FlowFileJobRow(job: job) { openJob = job }
                    if index < jobs.count - 1 {
                        Rectangle()
                            .fill(FlowColor.border)
                            .frame(height: 1)
                    }
                }
            }
            .background(FlowColor.background)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(FlowColor.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Actions

    private func chooseFiles() {
        FlowFilesDropZone.presentOpenPanel(completion: add)
    }

    private func add(_ urls: [URL]) {
        store.enqueue(urls: urls, origin: .user, cleanup: true)
    }
}

// MARK: - Banner

/// Files hero banner, drawn with the shared banner recipe: dark warm gradient, soft glow,
/// serif title in lumen, frosted dismiss button.
struct FlowFilesBanner: View {
    let title: Text
    let description: Text
    var onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let lumen = FlowColor.hex(0xFFFFEB, alpha: 1)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        VStack(alignment: .leading, spacing: 8) {
            title
                .flowText(.serif36)
                .foregroundStyle(lumen)
                .frame(maxWidth: 700, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            description
                .flowText(.sm)
                .foregroundStyle(lumen)
                .frame(maxWidth: 600, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .padding(.trailing, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                ZStack {
                    LinearGradient(
                        colors: [FlowColor.hex(0x0E0D0C, alpha: 1), FlowColor.hex(0x2B2420, alpha: 1)],
                        startPoint: UnitPoint(x: 0, y: 0.41),
                        endPoint: UnitPoint(x: 1, y: 0.59)
                    )
                    RadialGradient(
                        colors: [FlowColor.hex(0xC9A46A, alpha: 0.22), FlowColor.hex(0xC9A46A, alpha: 0)],
                        center: UnitPoint(x: 0.78, y: 0.4),
                        startRadius: 0,
                        endRadius: max(1, proxy.size.width * 0.6)
                    )
                }
            }
        }
        .clipShape(shape)
        .overlay {
            if colorScheme == .dark {
                shape.strokeBorder(FlowColor.border, lineWidth: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                FlowFilesIcon("x", fallback: "xmark", size: 14, color: .white)
                    .frame(width: 24, height: 24)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Circle().fill(Color.white.opacity(0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
            .padding(16)
        }
    }
}
