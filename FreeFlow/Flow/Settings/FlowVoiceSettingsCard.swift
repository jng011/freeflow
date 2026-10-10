import SwiftData
import SwiftUI

/// Settings > General > Voice: the two voice switches and the voice sample they use.
struct FlowVoiceSettingsCard: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(FlowVoiceSettings.onlyMineKey) private var onlyMine = false
    @AppStorage(FlowVoiceSettings.filterOthersKey) private var filterOthers = false
    @State private var hasVoiceprint = FlowVoiceSettings.voiceprint != nil
    @State private var isEnrolling = false
    @State private var status: String?

    var body: some View {
        FlowSettingsSection(title: "Voice") {
            FlowSettingsCard {
                FlowSettingsRow(title: "Only my voice") {
                    Text("Don't paste a dictation that doesn't sound like you. You can still paste it anyway.")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                } control: {
                    FlowSettingsSwitch(isOn: switchBinding($onlyMine))
                }

                FlowSettingsRow(title: "Drop other voices") {
                    Text("When someone else talks while you dictate, leave their words out.")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                } control: {
                    FlowSettingsSwitch(isOn: switchBinding($filterOthers))
                }

                FlowSettingsRow(title: "Voice sample") {
                    Text(sampleDescription)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                } control: {
                    FlowSettingsActionButton(title: isEnrolling ? "Learning…" : (hasVoiceprint ? "Relearn" : "Learn my voice")) {
                        enroll()
                    }
                    .disabled(isEnrolling)
                }
            }
        }
    }

    private var sampleDescription: String {
        if let status { return status }
        guard hasVoiceprint, let date = FlowVoiceSettings.voiceprintDate else {
            return "Dictate the voice script, then press Learn my voice. Runs on this Mac only."
        }
        return "Learned \(date.formatted(date: .abbreviated, time: .shortened)) from clean stretches of your dictations."
    }

    /// Turning a switch on without a voice sample learns one first.
    private func switchBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                if newValue {
                    Task.detached(priority: .utility) { _ = await FlowVoiceModel.shared.load() }
                    if !hasVoiceprint { enroll() }
                } else if !FlowVoiceSettings.anyEnabled {
                    Task { await FlowVoiceModel.shared.unload() }
                }
            }
        )
    }

    private func enroll() {
        guard !isEnrolling else { return }
        isEnrolling = true
        status = "Listening to your recent dictations…"
        var descriptor = FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 40
        let recent = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { $0.transcriptionStatus == TranscriptionStatus.completed.rawValue && $0.duration >= 5 }
            .compactMap { row -> (URL, TimeInterval)? in
                guard let url = row.audioFileURL.flatMap(URL.init(string:)),
                    FileManager.default.fileExists(atPath: url.path)
                else { return nil }
                return (url, row.duration)
            }
        // Anchor: the longest recent dictation (the voice script, ideally), then the rest.
        guard let anchor = recent.max(by: { $0.1 < $1.1 }), anchor.1 >= 10 else {
            isEnrolling = false
            status = "Dictate the voice script (about 30 seconds) first, then press Learn my voice."
            return
        }
        let urls = [anchor.0] + recent.filter { $0.0 != anchor.0 }.prefix(10).map(\.0)
        Task {
            let used = await FlowVoiceGate.enroll(from: urls)
            isEnrolling = false
            hasVoiceprint = FlowVoiceSettings.voiceprint != nil
            status = hasVoiceprint
                ? "Learned from \(used) clean stretches of your voice."
                : "Couldn't learn your voice yet. Dictate a few longer messages, then try again."
        }
    }
}
