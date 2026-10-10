import SwiftUI

struct FlowGeneralPane: View {
    @EnvironmentObject private var presenter: FlowSettingsPresenter
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var appLanguage = AppLanguagePreference.systemValue
    @AppStorage(FlowLegacyKeys.selectedLanguage) private var selectedLanguage = "en"
    @State private var shortcutRevision = 0
    @State private var languageRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            generalCard
            FlowVoiceSettingsCard()
        }
    }

    private var generalCard: some View {
        FlowSettingsCard {
            FlowSettingsRow(title: "Shortcuts", anchor: FlowSettingsDialog.shortcuts.rowAnchor) {
                shortcutDescription
            } control: {
                FlowSettingsActionButton(title: "Change") { presenter.open(.shortcuts) }
            }

            FlowSettingsRow(
                title: "Microphone",
                description: FlowMicrophoneNaming.currentDescription(audioDeviceManager),
                anchor: FlowSettingsDialog.microphone.rowAnchor
            ) {
                FlowSettingsActionButton(title: "Change") { presenter.open(.microphone) }
            }

            if FlowSettingsFeatures.multiLanguage {
                FlowSettingsRow(
                    title: "Dictation Languages",
                    description: languageSummary,
                    anchor: FlowSettingsDialog.languages.rowAnchor
                ) {
                    FlowSettingsActionButton(title: "Change") { presenter.open(.languages) }
                }
            } else {
                FlowSettingsRow(
                    title: "Dictation Language",
                    description: FlowLanguageCatalog.name(for: selectedLanguage == "auto" ? "en" : selectedLanguage),
                    anchor: FlowSettingsDialog.languages.rowAnchor
                ) {
                    EmptyView()
                }
            }

            if FlowSettingsFeatures.appLanguageRow {
                FlowSettingsRow(title: "App Language", description: "Select your preferred Free Flow language") {
                    FlowSettingsDropdown(
                        selection: appLanguageBinding,
                        options: [
                            FlowSettingsOption(value: AppLanguagePreference.systemValue, title: "System Default"),
                            FlowSettingsOption(value: "en", title: "English"),
                        ]
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            shortcutRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .languageDidChange)) { _ in
            languageRevision += 1
        }
    }

    private var languageSummary: String {
        _ = languageRevision
        _ = selectedLanguage
        return FlowLanguageCatalog.summary()
    }

    private var shortcutDescription: some View {
        let keys = ShortcutStore.shortcut(for: .primaryRecording)?.displayTokens ?? []
        return HStack(spacing: 4) {
            if keys.isEmpty {
                Text("No dictation shortcut set.")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.destructive)
            } else {
                Text("Hold")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                FlowSettingsInlineKeys(keys: keys)
                Text("and speak.")
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
            }
            FlowSettingsInlineLink(title: "Learn more \u{2192}") {
                presenter.sheet = .tryIt
            }
        }
        .id(shortcutRevision)
    }

    private var appLanguageBinding: Binding<String> {
        Binding(
            get: { appLanguage == "en" ? "en" : AppLanguagePreference.systemValue },
            set: { newValue in
                guard newValue != appLanguage else { return }
                AppLanguagePreference.apply(rawValue: newValue)
                appLanguage = newValue
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                FlowToastCenter.shared.show("Restart Free Flow to finish changing the app language.")
            }
        )
    }
}

/// Names shown for microphones in General and the Microphone dialog.
enum FlowMicrophoneNaming {
    static let builtInTitle = "Built-in mic (recommended)"
    static let systemTitle = "From computer settings"

    static func currentDescription(_ manager: AudioDeviceManager) -> String {
        switch manager.inputMode {
        case .systemDefault:
            return systemTitle
        case .prioritized:
            let name =
                manager.selectedDeviceID.flatMap { id in manager.availableDevices.first { $0.id == id }?.name }
            return name.map { "\($0) (ranked)" } ?? "Ranked microphones"
        case .custom:
            guard let id = manager.selectedDeviceID,
                let device = manager.availableDevices.first(where: { $0.id == id })
            else { return systemTitle }
            return manager.isInternalMicrophone(device.id) ? builtInTitle : device.name
        }
    }
}
