import SwiftUI

/// On-device transcription models Parle offers, filtered to what this Mac can
/// run comfortably and ranked so the best fit is recommended. Hardware is read
/// silently; people only see the result.
struct ParleLocalOption: Identifiable, Equatable {
    enum Kind: Equatable { case apple, whisper, parakeet }

    let key: String
    let title: String
    let note: String
    let size: String?
    let ramGB: Double
    let kind: Kind
    var id: String { key }
}

enum ParleLocalCatalog {
    /// Curated list (superseded and niche models from the original app are left out).
    static let all: [ParleLocalOption] = [
        .init(key: "parakeet-ultra", title: "Parakeet Ultra", note: "Fast and very accurate", size: "640 MB", ramGB: 0.8, kind: .parakeet),
        .init(key: "ggml-large-v3-turbo", title: "Whisper Large v3 Turbo", note: "Most accurate, many languages", size: "1.5 GB", ramGB: 1.8, kind: .whisper),
        .init(key: "parakeet-tdt-0.6b-v3", title: "Parakeet V3", note: "Fast, English and European languages", size: "494 MB", ramGB: 0.8, kind: .parakeet),
        .init(key: "ggml-large-v3-turbo-q5_0", title: "Whisper Turbo Compact", note: "Accurate, smaller download", size: "547 MB", ramGB: 1.0, kind: .whisper),
        .init(key: "ggml-large-v3", title: "Whisper Large v3", note: "Highest accuracy, slower", size: "2.9 GB", ramGB: 3.9, kind: .whisper),
        .init(key: "ggml-base", title: "Whisper Base", note: "Tiny and quick", size: "142 MB", ramGB: 0.5, kind: .whisper),
        .init(key: "apple-speech", title: "Apple Speech", note: "Built in, nothing to download", size: nil, ramGB: 0, kind: .apple),
    ]

    static func option(forKey key: String) -> ParleLocalOption? { all.first { $0.key == key } }

    /// Models that run comfortably here: leave most memory for the system and apps.
    static var compatible: [ParleLocalOption] {
        let budget = Double(ParleDeviceProfile.memoryGB) * 0.3
        return all.filter { $0.ramGB <= budget }
    }

    static var recommended: ParleLocalOption {
        let key = ParleDeviceProfile.memoryGB >= 32 ? "ggml-large-v3-turbo" : "parakeet-ultra"
        return compatible.first { $0.key == key } ?? compatible.first ?? all.last!
    }

    static var others: [ParleLocalOption] {
        compatible.filter { $0.key != recommended.key }
    }
}

/// "On this Mac" section of the Engine page.
struct ParleLocalModelsSection: View {
    @ObservedObject private var engine = ParleEngine.shared
    @EnvironmentObject private var whisperModelManager: WhisperModelManager
    @EnvironmentObject private var fluidAudioModelManager: FluidAudioModelManager

    var body: some View {
        Section {
            ModelCard(option: ParleLocalCatalog.recommended, isRecommended: true)
            ForEach(ParleLocalCatalog.others) { option in
                ModelCard(option: option, isRecommended: false)
            }
        } header: {
            Text("On this Mac")
        }
    }

    private struct ModelCard: View {
        @ObservedObject private var engine = ParleEngine.shared
        @EnvironmentObject private var whisperModelManager: WhisperModelManager
        @EnvironmentObject private var fluidAudioModelManager: FluidAudioModelManager
        let option: ParleLocalOption
        let isRecommended: Bool

        var body: some View {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: isRecommended ? 24 : 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isRecommended ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: isRecommended ? 34 : 26)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(option.title)
                            .font(isRecommended ? .headline : .body)
                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                .foregroundStyle(.tint)
                        }
                    }
                    Text([option.note, option.size].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let progress {
                        ProgressView(value: progress)
                            .frame(maxWidth: 220)
                    }
                }

                Spacer(minLength: 8)
                action
            }
            .padding(.vertical, isRecommended ? 10 : 4)
            .padding(.horizontal, isRecommended ? 10 : 0)
            .background {
                if isRecommended {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                }
            }
        }

        private var icon: String {
            switch option.kind {
            case .apple: return "apple.logo"
            case .whisper: return "waveform"
            case .parakeet: return "bolt"
            }
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
                guard let model = parakeetModel, fluidAudioModelManager.isFluidAudioModelDownloading(model) else { return nil }
                return fluidAudioModelManager.downloadStatus(for: model)?.fractionCompleted ?? 0
            }
        }

        @ViewBuilder
        private var action: some View {
            if isSelected && isDownloaded {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(.green)
            } else if isDownloaded {
                Button("Use") { engine.localModelKey = option.key }
                    .appGlassButtonStyle()
            } else if progress != nil {
                Button("Cancel") { cancel() }
            } else {
                Button {
                    download()
                } label: {
                    Label("Get", systemImage: "arrow.down.circle")
                }
                .modifier(RecommendedButton(isRecommended: isRecommended))
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

    private struct RecommendedButton: ViewModifier {
        let isRecommended: Bool
        func body(content: Content) -> some View {
            if isRecommended { content.appGlassProminentButtonStyle() } else { content.appGlassButtonStyle() }
        }
    }
}

/// Switches to a model automatically once its download finishes.
@MainActor
enum ParleLocalAutoSelect {
    private static var pending: String?

    static func watch(_ key: String) { pending = key }

    static func modelsChanged(downloaded keys: Set<String>) {
        guard let key = pending, keys.contains(key) else { return }
        ParleEngine.shared.localModelKey = key
        pending = nil
    }
}
