import AVFoundation
import AppKit
import SwiftUI

// The onboarding pages. Each page is a FlowOnboardingSplit: text and the primary
// action on the left, a live demo on the right. Navigation and state live in
// FlowOnboardingModel (FlowOnboardingView.swift).

// MARK: - 1. Welcome

struct FlowWelcomePage: View {
    @ObservedObject var model: FlowOnboardingModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        FlowOnboardingSplit(
            showsBack: false,
            onBack: {},
            ctaTitle: "Continue",
            onCTA: { model.performPrimary() },
            rightFill: FlowColor.lumen
        ) {
            FlowOnboardingTitle(
                title: "Welcome to Free Flow",
                description: "Accurate voice to text, everywhere you work."
            )
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("What should we call you?")
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                TextField(
                    "",
                    text: Binding(
                        get: { model.name },
                        set: { model.name = String($0.prefix(32)) }
                    ),
                    prompt: Text("Your first name").foregroundStyle(FlowColor.foregroundTertiary)
                )
                .textFieldStyle(.plain)
                .font(FlowFont.sans(15))
                .foregroundStyle(FlowColor.foreground)
                .focused($nameFocused)
                .onSubmit { model.performPrimary() }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.background))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            nameFocused ? FlowColor.neutral500 : FlowColor.neutral300,
                            lineWidth: nameFocused ? 2 : 1
                        )
                )
            }
        } right: {
            VStack(spacing: 20) {
                FlowLogoMark(height: 120)
                FlowWordmark()
                    .scaleEffect(1.6)
            }
            .accessibilityElement(children: .combine)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { nameFocused = true }
        }
    }
}

// MARK: - 2. Permissions

struct FlowPermissionsPage: View {
    @ObservedObject var model: FlowOnboardingModel
    @ObservedObject var coordinator: FlowPermissions

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        FlowOnboardingSplit(
            showsBack: true,
            onBack: { model.goBack() },
            ctaTitle: allGranted ? "Continue" : nil,
            onCTA: { model.performPrimary() }
        ) {
            FlowOnboardingTitle(
                title: allGranted
                    ? "Thanks for trusting us, we value your privacy"
                    : "Give Free Flow permissions on your computer"
            )
            .animation(FlowMotion.standard, value: allGranted)
        } content: {
            VStack(alignment: .leading, spacing: 24) {
                FlowPermissionCard(
                    title: "Allow Free Flow to use your microphone",
                    detail: "Free Flow only uses the mic while you are dictating",
                    actionTitle: actionTitle(for: .microphone),
                    isGranted: isGranted(.microphone),
                    isActive: active == .microphone,
                    onSelect: { coordinator.select(.microphone) },
                    onAction: { model.requestPermission(.microphone, coordinator: coordinator) }
                )
                FlowPermissionCard(
                    title: "Allow Free Flow to insert spoken words",
                    detail: "This lets Free Flow put your words in the right text box",
                    actionTitle: actionTitle(for: .accessibility),
                    isGranted: isGranted(.accessibility),
                    isActive: active == .accessibility,
                    onSelect: { coordinator.select(.accessibility) },
                    onAction: { model.requestPermission(.accessibility, coordinator: coordinator) }
                )
            }
        } right: {
            FlowPrivacyIllustration(allGranted: allGranted)
        }
        .onAppear { model.refreshPermissions(coordinator) }
        .onReceive(poll) { _ in model.refreshPermissions(coordinator) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions(coordinator)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshPermissions(coordinator)
        }
    }

    private var allGranted: Bool { coordinator.allGranted }

    /// The first permission still missing, or the one the person clicked.
    private var active: FlowPermission? {
        let selected = coordinator.activePermission
        if FlowPermission.required.contains(selected), !isGranted(selected),
            !coordinator.isLocked(selected)
        {
            return selected
        }
        return FlowPermission.required.first { !isGranted($0) }
    }

    private func isGranted(_ kind: FlowPermission) -> Bool {
        coordinator.status(for: kind).isGranted
    }

    private func actionTitle(for kind: FlowPermission) -> String {
        let status = coordinator.status(for: kind)
        if kind == .microphone && status.requiresSettings { return "Open Settings" }
        return "Allow"
    }
}

/// Permission card: collapsed 68 tall, the active one expands to 172 with its description and Allow.
struct FlowPermissionCard: View {
    let title: String
    let detail: String
    let actionTitle: String
    let isGranted: Bool
    let isActive: Bool
    let onSelect: () -> Void
    let onAction: () -> Void

    @State private var showsCheck = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text(title)
                    .flowText(.mdStrong)
                    .foregroundStyle(FlowColor.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if showsCheck {
                    FlowIcon(.circleCheck, size: 20, stroke: 2, color: FlowColor.success)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            if isActive && !isGranted {
                Text(detail)
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(actionTitle, action: onAction)
                    .buttonStyle(FlowButtonStyle(variant: .primary, size: .xs))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: isActive && !isGranted ? 172 : 68, alignment: .topLeading)
        .background(shape.fill(FlowColor.background))
        .overlay(shape.strokeBorder(FlowColor.sand700, lineWidth: 1))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture {
            if !isGranted { onSelect() }
        }
        .animation(FlowOnboardingMotion.expand, value: isActive)
        .animation(FlowOnboardingMotion.expand, value: isGranted)
        .onAppear { showsCheck = isGranted }
        .onChange(of: isGranted) { _, granted in
            if granted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.spring(duration: 0.3, bounce: 0.2)) { showsCheck = true }
                }
            } else {
                showsCheck = false
            }
        }
    }
}

/// Right panel of the permissions page: a calm card about what Flow can see.
private struct FlowPrivacyIllustration: View {
    let allGranted: Bool

    var body: some View {
        FlowOnboardingWidgetCard {
            HStack(spacing: 12) {
                FlowIcon(allGranted ? .shieldCheck : .lock, size: 24, stroke: 1.75, color: FlowColor.dawn800)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.dawn200))
                Text(allGranted ? "You're all set" : "Your words stay yours")
                    .flowText(.h4)
                    .foregroundStyle(FlowColor.foreground)
            }
            VStack(alignment: .leading, spacing: 12) {
                row(.mic, "The mic is only on while you hold the shortcut or after you tap it.")
                row(.keyboard, "Free Flow types into the box you are in, nothing else.")
                row(.server, "Your audio is only used to turn what you say into text.")
            }
        }
    }

    private func row(_ icon: FlowIconName, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            FlowIcon(icon, size: 16, stroke: 1.75, color: FlowColor.foregroundTertiary)
                .frame(width: 20, height: 20)
            Text(text)
                .flowText(.sm)
                .foregroundStyle(FlowColor.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 3. Mic test

struct FlowMicTestPage: View {
    @ObservedObject var model: FlowOnboardingModel
    @ObservedObject var meter: FlowMicTestMeter
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared

    var body: some View {
        FlowOnboardingSplit(
            showsBack: true,
            onBack: { model.goBack() },
            ctaTitle: nil,
            onCTA: { model.performPrimary() }
        ) {
            FlowOnboardingTitle(
                title: "Test your microphone",
                description: "Your computer's built-in mic gives the best results."
            )
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    FlowIcon(.mic, size: 16, stroke: 1.75, color: FlowColor.foregroundTertiary)
                    Text(FlowMicrophoneNaming.currentDescription(audioDeviceManager))
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .lineLimit(1)
                }
                FlowQuickTipCard(text: "A wired headset or desk mic also works well for whispering.")
            }
        } right: {
            FlowMicTestWidget(
                meter: meter,
                onChangeMicrophone: { model.presenter.open(.microphone) },
                onYes: { model.performPrimary() }
            )
        }
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
        .onChange(of: audioDeviceManager.selectedDeviceID) { _, _ in meter.restart() }
        .onChange(of: audioDeviceManager.inputMode) { _, _ in meter.restart() }
    }
}

// MARK: - 4. Shortcut test

struct FlowShortcutTestPage: View {
    @ObservedObject var model: FlowOnboardingModel
    @ObservedObject var monitor: FlowShortcutTestMonitor
    @ObservedObject var presenter: FlowSettingsPresenter
    @State private var showsHelp = false

    var body: some View {
        FlowOnboardingSplit(
            showsBack: true,
            onBack: { model.goBack() },
            ctaTitle: nil,
            onCTA: { model.performPrimary() }
        ) {
            FlowOnboardingTitle(
                title: "Press the keyboard shortcut to test it out",
                description: "We recommend the fn key at the bottom left of the keyboard."
            )
        } content: {
            if showsHelp {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Try another key")
                        .flowText(.smStrong)
                        .foregroundStyle(FlowColor.foreground)
                    Text(
                        "Some keyboards send fn to the system first. Pick a different key, like the right option key, with Edit shortcut."
                    )
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.backgroundTertiary))
                .transition(.opacity)
            }
        } right: {
            FlowShortcutTestWidget(
                monitor: monitor,
                onEdit: { presenter.open(.shortcuts) },
                onNo: {
                    withAnimation(FlowMotion.standard) { showsHelp = true }
                    presenter.open(.shortcuts)
                },
                onYes: { model.performPrimary() }
            )
        }
        .onAppear { startMonitor() }
        .onDisappear { monitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            startMonitor()
        }
        .onChange(of: presenter.dialog) { _, dialog in
            // The shortcut recorder needs the keys while the dialog is open.
            if dialog == nil { startMonitor() } else { monitor.stop() }
        }
    }

    private func startMonitor() {
        guard presenter.dialog == nil else { return }
        monitor.start(keys: FlowTestKey.keys(for: ShortcutStore.shortcut(for: .primaryRecording)))
    }
}

// MARK: - 5. Language

struct FlowLanguagePage: View {
    @ObservedObject var model: FlowOnboardingModel

    var body: some View {
        FlowOnboardingSplit(
            showsBack: true,
            onBack: { model.goBack() },
            ctaTitle: "Continue",
            onCTA: { model.performPrimary() }
        ) {
            FlowOnboardingTitle(
                title: "Set the language(s) you speak",
                description: "Select all the languages you speak or let Free Flow detect them automatically."
            )
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                FlowAutoDetectSwitch(isOn: $model.autoDetect)
                if let error = model.languageError {
                    Text(error)
                        .font(FlowFont.sans(12))
                        .foregroundStyle(FlowColor.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !model.autoDetect && !model.languages.isEmpty {
                    Text(model.languages.map(FlowLanguageCatalog.name(for:)).joined(separator: " · "))
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } right: {
            FlowLanguagePicker(
                selection: $model.languages,
                autoDetect: model.autoDetect,
                gridHeight: 413,
                showsSelectedList: false,
                gridWidth: 320,
                columnCount: 2
            )
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.background))
        }
    }
}

// MARK: - 6. Try it

struct FlowTryItPage: View {
    @ObservedObject var model: FlowOnboardingModel

    var body: some View {
        FlowOnboardingSplit(
            showsBack: true,
            onBack: { model.goBack() },
            ctaTitle: "Continue",
            ctaEnabled: model.practiceSucceeded,
            onCTA: { model.performPrimary() }
        ) {
            FlowTryItHeadline()
        } content: {
            if !model.practiceSucceeded {
                Button("Skip for now") { model.goNext() }
                    .buttonStyle(FlowButtonStyle(variant: .ghost, size: .sm))
            }
        } right: {
            FlowTryItPracticeCard(text: $model.practiceText, didSucceed: $model.practiceSucceeded)
        }
    }
}
