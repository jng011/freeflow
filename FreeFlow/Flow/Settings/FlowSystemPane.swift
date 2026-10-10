import AppKit
import SwiftUI

struct FlowSystemPane: View {
    @EnvironmentObject private var presenter: FlowSettingsPresenter
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @ObservedObject private var engine = ParleEngine.shared

    @AppStorage(FlowKeys.showBarAlways) private var showBarAlways = true
    @AppStorage(FlowKeys.barSnoozeUntil) private var barSnoozeUntil = 0.0
    @AppStorage(FlowKeys.notifySuggestions) private var notifySuggestions = true
    @AppStorage(FlowKeys.notifyMilestones) private var notifyMilestones = true
    @AppStorage(FlowKeys.processingDelayNotice) private var processingDelayNotice = true
    @AppStorage(AutoLearnSettings.isEnabledKey) private var autoLearn = true
    @AppStorage(FlowLegacyKeys.restoreClipboard) private var restoreClipboard = true
    @AppStorage(CursorPaster.pasteByParagraphKey) private var pasteByParagraph = true

    @State private var soundsEnabled = true
    @State private var soundPack: FlowSoundPack = .default
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if engine.isUsingPC && engine.pcStatus == .offline {
                offlineBanner
            }
            appSettings
            sound
            notifications
            extras
            data
        }
        .onAppear {
            soundsEnabled = FlowSoundSettings.isEnabled
            soundPack = FlowSoundSettings.pack
            now = Date()
            launchAtLogin.refresh()
        }
    }

    // MARK: Banner

    private var offlineBanner: some View {
        HStack(spacing: 12) {
            FlowSettingsIcon(name: "circle-alert", size: 18, stroke: 1.75, color: FlowColor.warning, fallback: "exclamationmark.circle")
            Text("The server isn't reachable. Free Flow is using this Mac for now.")
                .flowText(.smEmph)
                .foregroundStyle(FlowColor.foreground)
            Spacer(minLength: 8)
            Button("Check now") { engine.checkPCNow() }
                .flowSettingsButton(.secondary, size: .sm)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.backgroundTertiary))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(FlowColor.warning, lineWidth: 1)
        )
    }

    // MARK: App settings

    private var isSnoozed: Bool { barSnoozeUntil > now.timeIntervalSince1970 }

    private var appSettings: some View {
        FlowSettingsSection(title: "App settings") {
            FlowSettingsCard {
                FlowSettingsRow(title: "Launch app at login") {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        ))
                        .disabled(launchAtLogin.isUpdating)
                }

                FlowSettingsRow(title: "Show Flow Bar at all times") {
                    if isSnoozed {
                        HStack(spacing: 4) {
                            Text("Hidden for one hour.")
                                .flowText(.sm)
                                .foregroundStyle(FlowColor.foregroundTertiary)
                            FlowSettingsInlineLink(title: "Show now") {
                                FlowSettingsWriter.set(0.0, forKey: FlowKeys.barSnoozeUntil)
                                now = Date()
                                FlowBarController.shared.refreshVisibility()
                            }
                        }
                    }
                } control: {
                    FlowSettingsSwitch(isOn: settingBinding($showBarAlways) {
                        FlowBarController.shared.refreshVisibility()
                    })
                }

                FlowSettingsRow(title: "Show app in dock") {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { !menuBarManager.isMenuBarOnly },
                            set: { newValue in
                                menuBarManager.isMenuBarOnly = !newValue
                                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                            }
                        ))
                }
            }
        }
    }

    // MARK: Sound

    private var sound: some View {
        FlowSettingsSection(title: "Sound") {
            FlowSettingsCard {
                FlowSettingsRow(title: "Dictation and notification sounds") {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { soundsEnabled },
                            set: { newValue in
                                soundsEnabled = newValue
                                FlowSoundSettings.isEnabled = newValue
                                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                                if newValue { SoundManager.shared.preview(FlowSoundSettings.pack) }
                            }
                        ))
                }

                FlowSettingsRow(title: "Sound pack", description: soundPack.subtitle) {
                    FlowSettingsDropdown(
                        selection: Binding(
                            get: { soundPack },
                            set: { newValue in
                                soundPack = newValue
                                FlowSoundSettings.pack = newValue
                                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                                SoundManager.shared.preview(newValue)
                            }
                        ),
                        options: FlowSoundPack.allCases.map {
                            FlowSettingsOption(value: $0, title: $0.displayName, subtitle: $0.subtitle)
                        }
                    )
                    .disabled(!soundsEnabled)
                }

                FlowSettingsRow(title: "Mute all audio while dictating") {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { mediaController.isSystemMuteEnabled },
                            set: { setMute($0) }
                        ))
                }

                FlowSettingsRow(title: "Pause music while dictating") {
                    FlowSettingsSwitch(
                        isOn: Binding(
                            get: { playbackController.isPauseMediaEnabled },
                            set: { setPause($0) }
                        ))
                }
            }
        }
    }

    /// Mute and pause are exclusive, but only enforced when the person turns one on.
    private func setMute(_ on: Bool) {
        mediaController.isSystemMuteEnabled = on
        if on && playbackController.isPauseMediaEnabled {
            playbackController.isPauseMediaEnabled = false
            FlowToastCenter.shared.show("Pause music while dictating is now off. Free Flow mutes all audio instead.")
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    private func setPause(_ on: Bool) {
        playbackController.isPauseMediaEnabled = on
        if on && mediaController.isSystemMuteEnabled {
            mediaController.isSystemMuteEnabled = false
            FlowToastCenter.shared.show("Mute all audio while dictating is now off. Free Flow pauses your music instead.")
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    // MARK: Notifications

    private var notifications: some View {
        FlowSettingsSection(title: "Notifications") {
            FlowSettingsCard {
                FlowSettingsRow(
                    title: "Suggestions",
                    description: "Tips about getting set up or improving how you use Free Flow."
                ) {
                    FlowSettingsSwitch(isOn: settingBinding($notifySuggestions))
                }
                FlowSettingsRow(title: "Milestones", description: "Word-count milestones and streaks") {
                    FlowSettingsSwitch(isOn: settingBinding($notifyMilestones))
                }
                FlowSettingsRow(
                    title: "Slow processing notice",
                    description: "Tell me when a dictation takes longer than usual"
                ) {
                    FlowSettingsSwitch(isOn: settingBinding($processingDelayNotice))
                }
            }
        }
    }

    // MARK: Extras

    private var extras: some View {
        FlowSettingsSection(title: "Extras") {
            FlowSettingsCard {
                FlowSettingsRow(title: "Auto-add to dictionary", description: "Adds corrected words automatically") {
                    FlowSettingsSwitch(isOn: settingBinding($autoLearn))
                }
                FlowSettingsRow(
                    title: "Restore clipboard after pasting",
                    description: "Puts back what you had copied once Free Flow pastes."
                ) {
                    FlowSettingsSwitch(isOn: settingBinding($restoreClipboard))
                }
                FlowSettingsRow(
                    title: "Keep dictation on one line in Terminal apps",
                    description: "Line breaks become spaces in Terminal, iTerm, Warp and Ghostty."
                ) {
                    FlowSettingsSwitch(isOn: settingBinding($pasteByParagraph))
                }
                FlowSettingsRow(title: "Smart Formatting") {
                    HStack(spacing: 4) {
                        Text("Formatting now lives in AI Cleanup.")
                            .flowText(.sm)
                            .foregroundStyle(FlowColor.foregroundTertiary)
                        FlowSettingsInlineLink(title: "Open") {
                            presenter.selectPane?(.aiCleanup)
                        }
                    }
                } control: {
                    EmptyView()
                }
            }
        }
    }

    // MARK: Data

    private var data: some View {
        FlowSettingsSection(title: "Data") {
            FlowSettingsCard {
                FlowSettingsRow(
                    title: "Restart tutorial",
                    description: "Walk through the microphone, shortcut, and dictation setup steps again."
                ) {
                    FlowSettingsActionButton(title: "Restart") {
                        presenter.confirm(
                            "Restart tutorial?",
                            message:
                                "You'll walk through the setup steps again. Your dictation history and settings stay as they are.",
                            confirmTitle: "Restart",
                            destructive: false
                        ) {
                            restartTutorial()
                        }
                    }
                }
                FlowSettingsRow(
                    title: "Reset app",
                    description: "Clears cached stats and temporary files. Your history and dictionary are kept."
                ) {
                    FlowSettingsActionButton(title: "Reset & restart") {
                        presenter.confirm(
                            "Reset and restart?",
                            message:
                                "Free Flow clears its cached stats and temporary files, then restarts. Your history and dictionary are kept.",
                            confirmTitle: "Reset & restart"
                        ) {
                            resetApp()
                        }
                    }
                }
            }
        }
    }

    private func restartTutorial() {
        UserDefaults.standard.set(0, forKey: FlowSettingsPrivateKeys.onboardingPage)
        FlowSettingsWriter.set(false, forKey: OnboardingSettings.completedV2Key)
        FlowBarController.shared.refreshVisibility()
        if let close = presenter.close {
            close()
        } else {
            FlowNavigator.shared.dismissSettings()
        }
    }

    private func resetApp() {
        let snapshot = FlowPaths.file("dashboard-stats-snapshot.json")
        try? FileManager.default.removeItem(at: snapshot)
        UserDefaults.standard.set(true, forKey: FlowLegacyKeys.statsSnapshotStale)
        FlowStatsStore.shared.rebuildCaches()
        FlowAppRelauncher.relaunch()
    }

    // MARK: Helpers

    private func settingBinding(_ binding: Binding<Bool>, onChange: (() -> Void)? = nil) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                onChange?()
            }
        )
    }
}

enum FlowAppRelauncher {
    /// Starts a fresh copy of the app a moment after this one quits.
    @MainActor static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", bundlePath]
        do {
            try process.run()
        } catch {
            NSWorkspace.shared.open(URL(fileURLWithPath: bundlePath))
        }
        NSApp.terminate(nil)
    }
}
