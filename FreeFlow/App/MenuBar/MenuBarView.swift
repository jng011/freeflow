import AppKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @AppStorage(OnboardingSettings.completedV2Key) private var hasCompletedOnboardingV2 = false
    @AppStorage(FlowLegacyKeys.selectedLanguage) private var selectedLanguage = "en"

    @Query(MenuBarView.recentDescriptor) private var recentTranscriptions: [Transcription]

    private static var recentDescriptor: FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 20
        return descriptor
    }

    var body: some View {
        VStack {
            if hasCompletedOnboardingV2 {
                completedOnboardingMenu
            } else {
                onboardingMenu
            }
        }
    }

    private var onboardingMenu: some View {
        Group {
            Button("Open Free Flow") {
                showMainWindow()
            }

            Divider()

            Button("Quit Free Flow") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var completedOnboardingMenu: some View {
        Group {
            Button("Open Free Flow") {
                showMainWindow()
            }

            Divider()

            updateStatusItem

            Divider()

            Button("Paste last transcript") {
                // The menu is still tracking when this fires, so a paste posted now is eaten.
                // Wait for it to close and hand focus back to the app the user was in.
                let target = NSWorkspace.shared.frontmostApplication
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        target.activate()
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    await FlowDictationActions.pasteLast()
                }
            }
            .keyboardShortcut("v", modifiers: [.control, .command])
            .disabled(lastTranscription == nil)

            if let preview = lastTranscriptPreview {
                Text(preview)
                    .foregroundColor(.secondary)
            }

            Divider()

            Button("Shortcuts") {
                // Also brings the main window forward.
                FlowNavigator.shared.presentSettings(.general, dialog: .shortcuts)
            }

            microphoneMenu

            languagesMenu

            Divider()

            Button("Settings...") {
                FlowNavigator.shared.presentSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit Free Flow") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updateStatusItem: some View {
        if updaterViewModel.availableUpdate != nil {
            Button("Update ready, restart now?") {
                updaterViewModel.checkForUpdates()
            }
        } else if updaterViewModel.canCheckForUpdates {
            Button("Check for updates...") {
                updaterViewModel.checkForUpdates()
            }
        } else {
            Button("Checking for updates...") {}
                .disabled(true)
        }
    }

    // MARK: - Last transcript

    /// Latest dictation (Files transcriptions are not dictations).
    private var lastTranscription: Transcription? {
        let excluded = FlowFilesStore.shared.transcriptionIDs
        return recentTranscriptions.first { !excluded.contains($0.id) }
    }

    /// First 25 characters plus "...".
    private var lastTranscriptPreview: String? {
        guard let transcription = lastTranscription else { return nil }
        let text = transcription.preferredHistoryText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(25)) + "..."
    }

    // MARK: - Microphone

    private var microphoneMenu: some View {
        Menu("Microphone") {
            ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                Button {
                    audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
                } label: {
                    if audioDeviceManager.getCurrentDevice() == device.id {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }

            if audioDeviceManager.availableDevices.isEmpty {
                Text("No microphones found")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Languages

    private var pickedLanguages: [String] {
        FlowLanguageCatalog.storedSelection
    }

    private var languagesMenu: some View {
        Menu("Languages") {
            Button {
                setLanguage("auto")
            } label: {
                if selectedLanguage == "auto" {
                    Label("Auto-detect", systemImage: "checkmark")
                } else {
                    Text("Auto-detect")
                }
            }

            if !pickedLanguages.isEmpty {
                Divider()
            }

            ForEach(pickedLanguages, id: \.self) { code in
                Button {
                    setLanguage(code)
                } label: {
                    let name = FlowLanguageCatalog.name(for: code)
                    if selectedLanguage == code {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        }
    }

    /// Quick switch: sets the dictation language without changing the picked list in Settings.
    private func setLanguage(_ code: String) {
        guard selectedLanguage != code else { return }
        selectedLanguage = code
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    // MARK: - Window

    private func showMainWindow() {
        let existingWindow = WindowManager.shared.currentMainWindow()
        menuBarManager.activateForPresentedWindow()

        if existingWindow == nil {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            openWindow(id: AppWindowID.main)
        } else {
            openWindow(id: AppWindowID.main)
            WindowManager.shared.showMainWindow()
        }
    }
}
