import SwiftUI

struct FlowServerPane: View {
    @EnvironmentObject private var presenter: FlowSettingsPresenter
    @ObservedObject private var engine = ParleEngine.shared

    @AppStorage(FlowLegacyKeys.displayName) private var displayName = ""
    @AppStorage(FlowLegacyKeys.vadEnabled) private var vadEnabled = true
    @AppStorage(FlowLegacyKeys.prewarmOnWake) private var prewarmOnWake = true
    @AppStorage(CloudTranscriptionSettings.timeoutKey) private var serverTimeout = CloudTranscriptionSettings
        .defaultTimeout
    @AppStorage(FlowLegacyKeys.transcriptionPrompt) private var vocabularyPrompt = ""

    @State private var nameDraft = ""
    @State private var panel: ParleEngine.Source = ParleEngine.shared.isUsingPC ? .pc : .thisMac
    @State private var isWorking = false

    private static let nameLimit = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            youCard
            transcriptionCard
            if panel == .thisMac || !engine.hasPass {
                onThisMacCard
            }
            advanced
        }
        .onAppear {
            nameDraft = displayName
            panel = engine.isUsingPC ? .pc : (engine.source == .pc ? .pc : .thisMac)
            Task { await engine.refreshAccess() }
        }
    }

    // MARK: You

    private var youCard: some View {
        FlowSettingsSection(title: "You") {
            FlowSettingsCard {
                FlowSettingsRow(title: "Name", description: "Used for your greeting and your access request.", controlWidth: 260) {
                    HStack(spacing: 8) {
                        FlowSettingsTextField(
                            placeholder: "Your name",
                            text: Binding(
                                get: { nameDraft },
                                set: { nameDraft = String($0.prefix(Self.nameLimit)) }
                            ),
                            onSubmit: saveName
                        )
                        Button("Save", action: saveName)
                            .flowSettingsButton(.secondary)
                            .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == displayName)
                    }
                }
            }
        }
    }

    private func saveName() {
        let trimmed = String(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.nameLimit))
        nameDraft = trimmed
        displayName = trimmed
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        FlowToastCenter.shared.show("Name saved", style: .success)
    }

    private var requesterName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ParleAccessClient.defaultRequesterName : trimmed
    }

    // MARK: Transcription

    private var transcriptionCard: some View {
        FlowSettingsSection(title: "Engine") {
            FlowSettingsCard {
                FlowSettingsRow(title: "Runs on", controlWidth: 280) {
                    Text(panel == .pc ? "Faster and more accurate" : engine.localEngineName)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                } control: {
                    HStack(spacing: 8) {
                        FlowSettingsChip(title: engine.serverName, isSelected: panel == .pc) { selectPanel(.pc) }
                        FlowSettingsChip(title: "This Mac", isSelected: panel == .thisMac) { selectPanel(.thisMac) }
                    }
                }

                FlowSettingsRow(title: "Status") {
                    HStack(spacing: 8) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                            .flowText(.sm)
                            .foregroundStyle(FlowColor.foregroundTertiary)
                    }
                } control: {
                    FlowSettingsActionButton(title: "Check now") { engine.checkPCNow() }
                        .disabled(!engine.hasPass)
                }

                if panel == .pc || !engine.hasPass {
                    accessRows
                }
            }
        }
    }

    private func selectPanel(_ newValue: ParleEngine.Source) {
        panel = newValue
        if newValue == .thisMac || engine.hasPass {
            engine.source = newValue
            NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
        }
    }

    @ViewBuilder
    private var accessRows: some View {
        if engine.hasPass {
            FlowSettingsRow(title: "Access") {
                passDetails
            } control: {
                FlowSettingsActionButton(title: "Refresh") {
                    run {
                        await engine.refreshAccess()
                        await engine.pingPC()
                    }
                }
                .disabled(isWorking)
            }

            FlowSettingsRow(title: "Stop using \(engine.serverName)") {
                FlowSettingsActionButton(title: "Stop using", kind: .destructiveSecondary) {
                    presenter.confirm(
                        "Stop using \(engine.serverName)?",
                        message: "Free Flow will transcribe on this Mac until you request access again.",
                        confirmTitle: "Stop using"
                    ) {
                        engine.removePass()
                        panel = .thisMac
                    }
                }
            }
        } else {
            FlowSettingsRow(title: "Access") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(requestStatusText)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = engine.accessError {
                        Text(error)
                            .flowText(.sm)
                            .foregroundStyle(FlowColor.destructive)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } control: {
                requestButton
            }
        }
    }

    @ViewBuilder
    private var requestButton: some View {
        switch engine.requestStatus {
        case .none, .approved:
            FlowSettingsActionButton(title: "Request access") {
                run { await engine.requestAccess(name: requesterName) }
            }
            .disabled(isWorking)
        case .pending:
            FlowSettingsActionButton(title: "Refresh") {
                run { await engine.refreshAccess() }
            }
            .disabled(isWorking)
        case .denied:
            FlowSettingsActionButton(title: "Request again") {
                run { await engine.requestAccess(name: requesterName) }
            }
            .disabled(isWorking)
        }
    }

    private var requestStatusText: String {
        switch engine.requestStatus {
        case .none, .approved:
            return "Send a request to use \(engine.serverName) as \(requesterName)."
        case .pending:
            return "Waiting for approval."
        case .denied:
            return "Not approved, or your access ended."
        }
    }

    private var passDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                FlowSettingsIcon(name: "circle-check", size: 14, stroke: 2, color: FlowColor.success, fallback: "checkmark.circle")
                Text("Approved")
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
            }
            if let limit = engine.passInfo?.wordsLimit {
                let used = engine.passInfo?.wordsUsed ?? 0
                Text("\(max(0, limit - used).formatted()) of \(limit.formatted()) words left")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                FlowSettingsProgressBar(value: Double(min(used, limit)) / Double(max(limit, 1)))
                    .frame(maxWidth: 240)
            }
            if let exp = engine.passInfo?.exp ?? ParlePassStore.current?.payload.exp {
                Text("Until \(Date(timeIntervalSince1970: TimeInterval(exp)).formatted(date: .abbreviated, time: .omitted))")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            }
        }
    }

    private var statusColor: Color {
        switch engine.pcStatus {
        case .online: return FlowColor.success
        case .checking: return FlowColor.warning
        case .offline: return FlowColor.destructive
        case .noPass: return FlowColor.foregroundTertiary
        }
    }

    private var statusText: String {
        switch engine.pcStatus {
        case .online(let ms): return "Online · \(ms) ms"
        case .checking: return "Checking..."
        case .offline: return "Offline, using this Mac"
        case .noPass: return "No access yet"
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }

    // MARK: On this Mac

    private var onThisMacCard: some View {
        FlowSettingsSection(
            title: "On this Mac",
            subtitle: "This Mac: \(ParleDeviceProfile.chipName), \(ParleDeviceProfile.memoryGB) GB memory"
        ) {
            FlowSettingsCard {
                FlowLocalModelRow(option: ParleLocalCatalog.recommended, isRecommended: true)
                ForEach(ParleLocalCatalog.others) { option in
                    FlowLocalModelRow(option: option, isRecommended: false)
                }
                if ParleLocalCatalog.compatible.count < ParleLocalCatalog.all.count {
                    Text("Larger models are hidden because they need more memory than this Mac has.")
                        .flowText(.xs)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowSettingsHeading(title: "Advanced")
            FlowSettingsCard {
                FlowSettingsRow(title: "Voice detection", description: "Skips silence before sending audio") {
                    FlowSettingsSwitch(isOn: notifying($vadEnabled))
                }
                FlowSettingsRow(title: "Prepare model on wake", description: "Gets this Mac's model ready after sleep") {
                    FlowSettingsSwitch(isOn: notifying($prewarmOnWake))
                }
                FlowSettingsRow(title: "Server timeout", controlWidth: 220) {
                    FlowSettingsStepper(
                        value: notifying($serverTimeout),
                        range: 10...120,
                        step: 5,
                        label: { "\($0) s" }
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Vocabulary prompt")
                        .flowText(.smEmph)
                        .foregroundStyle(FlowColor.foreground)
                    Text("Words and names sent to the transcriber as a hint.")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                    FlowSettingsTextArea(
                        placeholder: "Example: names, brands, jargon",
                        text: notifying($vocabularyPrompt),
                        height: 96
                    )
                }
                .padding(.vertical, 8)
                FlowSettingsRow(title: "Diagnostics", description: "Export logs to share when something goes wrong") {
                    FlowSettingsActionButton(title: "Open") { presenter.sheet = .diagnostics }
                }
            }
        }
    }

    private func notifying<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            }
        )
    }
}

struct FlowSettingsProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(FlowColor.neutral200)
                Capsule()
                    .fill(FlowSettingsPalette.fathom900)
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

/// One on-device model, restyled from ParleLocalModelsSection's card (same managers and actions).
private struct FlowLocalModelRow: View {
    @ObservedObject private var engine = ParleEngine.shared
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var fluidAudioModelManager: FluidAudioModelManager
    let option: ParleLocalOption
    let isRecommended: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(option.title)
                        .flowText(.smEmph)
                        .foregroundStyle(FlowColor.foreground)
                    if isRecommended {
                        FlowSettingsPillBadge(
                            title: "Recommended for this Mac",
                            fill: FlowSettingsPalette.dynamic(light: 0xD1FAE5, dark: 0x065F46),
                            foreground: FlowSettingsPalette.dynamic(light: 0x065F46, dark: 0xD1FAE5)
                        )
                    }
                }
                Text(detail)
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                if let progress {
                    FlowSettingsProgressBar(value: progress)
                        .frame(maxWidth: 220)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
                .frame(width: flowSettingsControlWidth, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    private var detail: String {
        var parts = [option.note]
        if let size = option.size { parts.append(size) }
        if option.ramGB > 0 { parts.append(String(format: "%.1f GB RAM", option.ramGB)) }
        return parts.joined(separator: " · ")
    }

    private var isSelected: Bool { engine.localModelKey == option.key }

    private var whisperModel: WhisperModel? {
        TranscriptionModelRegistry.models.first { $0.name == option.key } as? WhisperModel
    }

    private var parakeetModel: FluidAudioModel? {
        TranscriptionModelRegistry.models.first { $0.name == option.key } as? FluidAudioModel
    }

    private var isDownloaded: Bool {
        switch option.kind {
        case .apple: return true
        case .whisper: return whisperModelManager.availableModels.contains { $0.name == option.key }
        case .parakeet: return parakeetModel.map { fluidAudioModelManager.isFluidAudioModelDownloaded($0) } ?? false
        }
    }

    private var progress: Double? {
        switch option.kind {
        case .apple: return nil
        case .whisper: return isDownloaded ? nil : whisperModelManager.downloadProgress[option.key]
        case .parakeet:
            guard let model = parakeetModel, fluidAudioModelManager.isFluidAudioModelDownloading(model) else {
                return nil
            }
            return fluidAudioModelManager.downloadStatus(for: model)?.fractionCompleted ?? 0
        }
    }

    @ViewBuilder
    private var action: some View {
        if isSelected && isDownloaded {
            HStack(spacing: 6) {
                FlowSettingsIcon(name: "circle-check", size: 16, stroke: 2, color: FlowColor.success, fallback: "checkmark.circle.fill")
                Text("In use")
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.success)
            }
        } else if isDownloaded {
            FlowSettingsActionButton(title: "Use") {
                engine.localModelKey = option.key
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
            }
        } else if progress != nil {
            FlowSettingsActionButton(title: "Cancel") { cancel() }
        } else {
            FlowSettingsActionButton(title: "Download", kind: isRecommended ? .primary : .secondary) { download() }
        }
    }

    private func download() {
        switch option.kind {
        case .apple: break
        case .whisper: if let model = whisperModel { whisperModelManager.startDownload(model) }
        case .parakeet: if let model = parakeetModel { fluidAudioModelManager.startDownload(model) }
        }
        ParleLocalAutoSelect.watch(option.key)
    }

    private func cancel() {
        switch option.kind {
        case .apple: break
        case .whisper: if let model = whisperModel { whisperModelManager.cancelDownload(model) }
        case .parakeet: if let model = parakeetModel { fluidAudioModelManager.cancelDownload(model) }
        }
    }
}
