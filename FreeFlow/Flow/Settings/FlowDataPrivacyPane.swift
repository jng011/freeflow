import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum FlowLocalStoragePolicy: String, Hashable {
    case store, autoDelete, never
}

struct FlowDataPrivacyPane: View {
    @EnvironmentObject private var presenter: FlowSettingsPresenter
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @Environment(\.modelContext) private var modelContext

    @AppStorage(FlowKeys.contextAwareness) private var contextAwareness = true
    @AppStorage(CleanupSettingsKeys.isTranscriptionCleanupEnabled) private var transcriptCleanup = false
    @AppStorage(CleanupSettingsKeys.transcriptionRetentionMinutes) private var retentionMinutes = 1440
    @AppStorage(CleanupSettingsKeys.isAudioCleanupEnabled) private var audioCleanup = false
    @AppStorage(CleanupSettingsKeys.audioRetentionPeriod) private var audioRetentionDays = 7

    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            privacyCard
            storageCard
            exportCard
            agentsCard
        }
    }

    // MARK: AI agents

    private var agentsCard: some View {
        FlowSettingsSection(title: "AI agents", subtitle: "Let AI agents like Claude read your dictations through a local MCP connection.") {
            FlowSettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run this in Terminal to connect Claude Code. Nothing leaves your Mac unless the agent sends it.")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    FlowAgentSetupBox()
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: Privacy

    private var privacyCard: some View {
        FlowSettingsSection(title: "Privacy") {
            FlowSettingsCard {
                FlowSettingsRow(
                    title: "Context awareness",
                    description: "Lets Free Flow read a little text around your cursor so names are spelled right."
                ) {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { contextAwareness },
                            set: { newValue in
                                contextAwareness = newValue
                                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                            }
                        ))
                }
            }
        }
    }

    // MARK: Storage

    private var policy: FlowLocalStoragePolicy {
        guard transcriptCleanup else { return .store }
        return retentionMinutes == 0 ? .never : .autoDelete
    }

    private var storageCard: some View {
        FlowSettingsSection(title: "Storage") {
            FlowSettingsCard {
                FlowSettingsRow(title: "Local data storage", description: policyDescription, controlWidth: 260) {
                    FlowSettingsDropdown(
                        selection: Binding(get: { policy }, set: { requestPolicy($0) }),
                        options: [
                            FlowSettingsOption(value: FlowLocalStoragePolicy.store, title: "Store data locally"),
                            FlowSettingsOption(
                                value: FlowLocalStoragePolicy.autoDelete, title: "Auto-delete local data every 24hrs"),
                            FlowSettingsOption(value: FlowLocalStoragePolicy.never, title: "Never store data locally"),
                        ],
                        width: 260
                    )
                }

                FlowSettingsRow(
                    title: "Keep recordings",
                    description: audioCleanup
                        ? "Recordings older than the period you pick are deleted. Transcripts stay."
                        : "Keeps the audio of each dictation so you can replay or retry it."
                ) {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { !audioCleanup },
                            set: { setKeepRecordings($0) }
                        ))
                        .disabled(transcriptCleanup)
                }

                if audioCleanup && !transcriptCleanup {
                    FlowSettingsRow(title: "Delete recordings after") {
                        FlowSettingsDropdown(
                            selection: Binding(
                                get: { [1, 7, 30].contains(audioRetentionDays) ? audioRetentionDays : 7 },
                                set: { newValue in
                                    audioRetentionDays = newValue
                                    NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                                }
                            ),
                            options: [
                                FlowSettingsOption(value: 1, title: "1 day"),
                                FlowSettingsOption(value: 7, title: "7 days"),
                                FlowSettingsOption(value: 30, title: "30 days"),
                            ]
                        )
                    }
                }

                FlowSettingsRow(
                    title: "Delete all recordings",
                    description: "Removes every saved recording. Your transcripts are kept."
                ) {
                    FlowSettingsActionButton(title: "Delete", kind: .destructiveSecondary) {
                        presenter.confirm(
                            "Delete all recordings?",
                            message: "Every saved recording on this Mac is removed. Transcripts stay in your history.",
                            confirmTitle: "Delete"
                        ) {
                            deleteAllRecordings()
                        }
                    }
                }

                FlowSettingsRow(
                    title: "Delete all transcripts",
                    description: "Removes your whole dictation history from this Mac."
                ) {
                    FlowSettingsActionButton(title: "Delete", kind: .destructiveSecondary) {
                        presenter.confirm(
                            "Delete all transcripts",
                            message: "This removes your whole dictation history from this Mac. Your stats are kept.",
                            confirmTitle: "Delete"
                        ) {
                            deleteAllTranscripts()
                        }
                    }
                }
            }
        }
    }

    private var policyDescription: String {
        switch policy {
        case .store: return "Your history stays on this Mac."
        case .autoDelete: return "History older than 24 hours is deleted."
        case .never: return "Nothing is kept after it is pasted."
        }
    }

    private func requestPolicy(_ newPolicy: FlowLocalStoragePolicy) {
        guard newPolicy != policy else { return }
        switch newPolicy {
        case .store:
            applyPolicy(.store)
        case .autoDelete:
            presenter.confirm(
                "Are you sure you want to auto-delete data?",
                message: "History and recordings older than 24 hours are removed from this Mac now and every day after.",
                confirmTitle: "Auto-delete"
            ) {
                applyPolicy(.autoDelete)
            }
        case .never:
            presenter.confirm(
                "Are you sure you want to never store data?",
                message: "All of your history and recordings are removed from this Mac now, and new dictations are not kept.",
                confirmTitle: "Never store"
            ) {
                applyPolicy(.never)
            }
        }
    }

    private func applyPolicy(_ newPolicy: FlowLocalStoragePolicy) {
        switch newPolicy {
        case .store:
            transcriptCleanup = false
            if audioCleanup {
                AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
            }
        case .autoDelete:
            retentionMinutes = 1440
            transcriptCleanup = true
            AudioCleanupManager.shared.stopAutomaticCleanup()
        case .never:
            retentionMinutes = 0
            transcriptCleanup = true
            AudioCleanupManager.shared.stopAutomaticCleanup()
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        if newPolicy != .store {
            let context = modelContext
            Task { await TranscriptionAutoCleanupService.shared.runManualCleanup(modelContext: context) }
        }
    }

    private func setKeepRecordings(_ keep: Bool) {
        audioCleanup = !keep
        if keep {
            AudioCleanupManager.shared.stopAutomaticCleanup()
        } else {
            AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
            let context = modelContext
            Task { await AudioCleanupManager.shared.runAutomaticCleanupIfNeeded(modelContext: context) }
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    private func deleteAllRecordings() {
        let fileManager = FileManager.default
        let folder = FlowPaths.recordings
        if let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
        if let transcriptions = try? modelContext.fetch(FetchDescriptor<Transcription>()) {
            for transcription in transcriptions where transcription.audioFileURL != nil {
                transcription.audioFileURL = nil
            }
            try? modelContext.save()
        }
        FlowToastCenter.shared.show("Recordings deleted", style: .success)
    }

    private func deleteAllTranscripts() {
        guard let transcriptions = try? modelContext.fetch(FetchDescriptor<Transcription>()) else { return }
        for transcription in transcriptions {
            if let url = transcription.availableHistoryAudioURL {
                try? FileManager.default.removeItem(at: url)
            }
            modelContext.delete(transcription)
        }
        do {
            try modelContext.save()
        } catch {
            FlowToastCenter.shared.show("Couldn't delete your transcripts. Please try again.", style: .error)
            return
        }
        NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
        FlowToastCenter.shared.show("Transcripts deleted", style: .success)
    }

    // MARK: Export

    private var exportCard: some View {
        FlowSettingsSection(title: "Your data") {
            FlowSettingsCard {
                FlowSettingsRow(
                    title: "Download your data",
                    description: "Saves your settings, dictionary and stats to a file."
                ) {
                    FlowSettingsActionButton(title: isExporting ? "Exporting..." : "Export") {
                        exportData()
                    }
                    .disabled(isExporting)
                }
            }
        }
    }

    private func exportData() {
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            var files: [(name: String, data: Data)] = []
            do {
                let settings = try await ImportExportService.shared.makeSettingsBackupData(
                    enhancementService: enhancementService,
                    recordingShortcutManager: recordingShortcutManager,
                    menuBarManager: menuBarManager,
                    mediaController: MediaController.shared,
                    playbackController: PlaybackController.shared,
                    recorderUIManager: recorderUIManager,
                    modelContext: modelContext
                )
                files.append(("settings.json", settings))
            } catch {
                FlowToastCenter.shared.show("Couldn't export your settings.", style: .error)
            }
            if let archive = try? DictionaryImportExportService.makeArchive(modelContext: modelContext),
                let data = try? DictionaryImportExportService.encodeArchive(archive)
            {
                files.append(("dictionary.json", data))
            }
            if let stats = try? FlowStatsStore.shared.exportJSON() {
                files.append(("stats.json", stats))
            }
            guard !files.isEmpty else { return }
            await FlowDataExporter.save(files: files)
        }
    }
}

/// Writes the export as a flat .zip (no enclosing folder), or as one .json bundle if zipping fails.
@MainActor
enum FlowDataExporter {
    static func save(files: [(name: String, data: Data)]) async {
        let stamp = Date().formatted(.iso8601.year().month().day())
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.zip, UTType.json]
        panel.nameFieldStringValue = "Free Flow data \(stamp).zip"
        panel.title = "Download your data"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var destination = panel.url else { return }

        let wantsJSON = destination.pathExtension.lowercased() == "json"
        if !wantsJSON, destination.pathExtension.lowercased() != "zip" {
            destination.appendPathExtension("zip")
        }

        let succeeded: Bool
        if wantsJSON {
            succeeded = writeJSONBundle(files: files, to: destination)
        } else if await writeZip(files: files, to: destination) {
            succeeded = true
        } else {
            let fallback = destination.deletingPathExtension().appendingPathExtension("json")
            succeeded = writeJSONBundle(files: files, to: fallback)
        }

        if succeeded {
            FlowToastCenter.shared.show("Export saved", style: .success)
        } else {
            FlowToastCenter.shared.show("Couldn't save the export.", style: .error)
        }
    }

    private static func writeZip(files: [(name: String, data: Data)], to destination: URL) async -> Bool {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in files {
                try file.data.write(to: staging.appendingPathComponent(file.name), options: .atomic)
            }
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        try? FileManager.default.removeItem(at: destination)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                // Without --keepParent the files sit at the root of the archive.
                process.arguments = ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus == 0)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func writeJSONBundle(files: [(name: String, data: Data)], to destination: URL) -> Bool {
        var bundle: [String: Any] = ["exportedAt": ISO8601DateFormatter().string(from: Date())]
        for file in files {
            let key = (file.name as NSString).deletingPathExtension
            bundle[key] = (try? JSONSerialization.jsonObject(with: file.data)) ?? NSNull()
        }
        guard JSONSerialization.isValidJSONObject(bundle),
            let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        do {
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
