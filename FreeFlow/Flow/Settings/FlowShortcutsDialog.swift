import AppKit
import Carbon.HIToolbox
import SwiftUI

/// True while a shortcut selector is listening for keys, so Esc does not close Settings.
@MainActor
enum FlowShortcutCaptureState {
    static var isCapturing = false
}

/// Flow's extra shortcut rules and messages on top of ShortcutValidator.
enum FlowShortcutRules {
    static let needsModifier = "Shortcut must include a modifier key or a valid mouse button"
    static let tooManyKeys = "Shortcut must contain 3 or fewer keys"
    static let inUse = "This shortcut is already in use"

    static func notAllowed(_ shortcut: Shortcut) -> String {
        "This shortcut is not allowed: \(shortcut.displayString)"
    }

    private static let blockedCommandKeys: Set<UInt16> = [
        UInt16(kVK_ANSI_C), UInt16(kVK_ANSI_V), UInt16(kVK_ANSI_X), UInt16(kVK_ANSI_Z), UInt16(kVK_ANSI_A),
        UInt16(kVK_ANSI_F), UInt16(kVK_ANSI_Q), UInt16(kVK_ANSI_W), UInt16(kVK_ANSI_Comma),
    ]

    static func preValidate(_ shortcut: Shortcut) -> String? {
        if shortcut.displayTokens.count > 3 {
            return tooManyKeys
        }
        if shortcut.kind == .key, shortcut.modifierFlags == [.command], blockedCommandKeys.contains(shortcut.keyCode) {
            return notAllowed(shortcut)
        }
        return nil
    }

    static func message(for error: ShortcutValidationError?, fallback: String, shortcut: Shortcut) -> String {
        guard let error else { return fallback }
        switch error {
        case .plainKeyRequiresModifier, .shiftTypingKeyRequiresAdditionalModifier, .unsupportedMouseButton:
            return needsModifier
        case .reservedBySystem:
            return notAllowed(shortcut)
        case .alreadyUsedBy:
            return inUse
        }
    }

    static var defaultPrimary: Shortcut {
        .modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function])
    }

    static var defaultPasteLast: Shortcut {
        .key(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.control, .command])
    }

    static var defaultCopyLast: Shortcut {
        .key(keyCode: UInt16(kVK_ANSI_C), modifierFlags: [.control, .command])
    }

    /// Display tokens with "Fn" shown the way Flow writes it.
    static func tokens(_ shortcut: Shortcut?) -> [String] {
        (shortcut?.displayTokens ?? []).map { $0 == "Fn" ? "fn" : $0 }
    }
}

/// Updates the recording shortcut manager when one exists, otherwise writes the same keys it uses.
@MainActor
enum FlowShortcutModes {
    static func primaryChanged() {
        if let manager = FlowSettingsAttention.shortcutManager {
            if manager.primaryRecordingShortcut != .custom { manager.primaryRecordingShortcut = .custom }
            if manager.primaryRecordingShortcutMode != .hybrid { manager.primaryRecordingShortcutMode = .hybrid }
            manager.updateShortcutStatus()
        } else {
            UserDefaults.standard.set("custom", forKey: "primaryRecordingShortcut")
            UserDefaults.standard.set(RecordingShortcutManager.Mode.hybrid.rawValue, forKey: FlowLegacyKeys.primaryShortcutMode)
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    static func secondaryChanged(removed: Bool) {
        if let manager = FlowSettingsAttention.shortcutManager {
            if removed {
                manager.secondaryRecordingShortcut = .none
            } else {
                if manager.secondaryRecordingShortcut != .custom { manager.secondaryRecordingShortcut = .custom }
                if manager.secondaryRecordingShortcutMode != .toggle { manager.secondaryRecordingShortcutMode = .toggle }
            }
            manager.updateShortcutStatus()
        } else {
            UserDefaults.standard.set(removed ? "none" : "custom", forKey: "secondaryRecordingShortcut")
            if !removed {
                UserDefaults.standard.set(
                    RecordingShortcutManager.Mode.toggle.rawValue, forKey: FlowLegacyKeys.secondaryShortcutMode)
            }
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    static func utilityChanged() {
        FlowSettingsAttention.shortcutManager?.updateShortcutStatus()
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }
}

struct FlowShortcutsDialog: View {
    let onClose: () -> Void

    @State private var activeRow: String?
    @State private var errors: [String: String] = [:]
    @State private var revision = 0
    @AppStorage(FinishAndSendSettings.key) private var finishAndSendKey = FinishAndSendKey.none.rawValue

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        FlowSettingsDialogFrame(
            title: "Shortcuts",
            subtitle: "Choose your preferred shortcuts for using Free Flow.",
            maxWidth: 650
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    item(
                        id: "primary",
                        title: "Push to talk",
                        detail: "Hold to say something short. Tap once to keep listening hands-free."
                    ) {
                        selector(id: "primary", action: .primaryRecording, removable: false) {
                            FlowShortcutModes.primaryChanged()
                        }
                    }

                    item(
                        id: "secondary",
                        title: "Hands-free mode",
                        detail: "Press to start and stop dictation without holding"
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            selector(id: "secondary", action: .secondaryRecording, removable: true) {
                                FlowShortcutModes.secondaryChanged(removed: ShortcutStore.shortcut(for: .secondaryRecording) == nil)
                            }
                            hintBox
                        }
                    }

                    item(
                        id: "enter",
                        title: "Press Enter",
                        detail: "Press this key after pasting to send messages faster"
                    ) {
                        FlowSettingsDropdown(
                            selection: Binding(
                                get: { FinishAndSendKey(rawValue: finishAndSendKey) ?? .none },
                                set: { newValue in
                                    finishAndSendKey = newValue.rawValue
                                    NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
                                    FlowToastCenter.shared.show("Shortcut saved", style: .success)
                                }
                            ),
                            options: FinishAndSendKey.allCases.map {
                                FlowSettingsOption(value: $0, title: $0 == .none ? "Off" : $0.displayName)
                            },
                            width: 216
                        )
                    }

                    item(id: "paste", title: "Paste last transcript", detail: "Paste the last thing you dictated") {
                        selector(id: "paste", action: .pasteLastTranscription, removable: true) {
                            FlowShortcutModes.utilityChanged()
                        }
                    }

                    item(id: "copy", title: "Copy last transcript", detail: "Copy the last thing you dictated") {
                        selector(id: "copy", action: .copyLastTranscription, removable: true) {
                            FlowShortcutModes.utilityChanged()
                        }
                    }

                    item(
                        id: "command",
                        title: "Command mode",
                        detail: "Select text, hold this and say how to change it, like \"make this shorter\""
                    ) {
                        selector(id: "command", action: .commandMode, removable: true) {
                            FlowShortcutModes.utilityChanged()
                        }
                    }

                    item(id: "cancel", title: "Cancel", detail: "Dismiss dictation and notifications") {
                        FlowShortcutBox(isRecording: false) {
                            FlowShortcutChips(tokens: ["esc"])
                        } trailing: {
                            EmptyView()
                        }
                    }
                }
                .id(revision)
            }
            .scrollIndicators(.hidden)
            .frame(width: 602)
            .frame(maxHeight: 400)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Reset to default", action: resetToDefault)
                .flowSettingsButton(.link)
            Spacer(minLength: 12)
            Button("Done", action: onClose)
                .flowSettingsButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            if let manager = FlowSettingsAttention.shortcutManager, manager.primaryRecordingShortcutMode != .hybrid {
                manager.primaryRecordingShortcutMode = .hybrid
            }
        }
        .onDisappear {
            FlowShortcutCaptureState.isCapturing = false
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            revision += 1
        }
    }

    // MARK: Pieces

    private func item<Selector: View>(
        id: String,
        title: String,
        detail: String,
        @ViewBuilder selector: () -> Selector
    ) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(FlowFont.sans(15, weight: 600))
                    .foregroundStyle(FlowColor.foreground)
                Text(detail)
                    .flowText(.xs)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .frame(maxWidth: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                selector()
                if let error = errors[id] {
                    Text(error)
                        .font(FlowFont.sans(12))
                        .foregroundStyle(FlowColor.destructive)
                        .frame(width: 216, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 264, alignment: .leading)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
    }

    private func selector(
        id: String,
        action: ShortcutAction,
        removable: Bool,
        onChange: @escaping () -> Void
    ) -> some View {
        FlowShortcutSelector(
            id: id,
            action: action,
            removable: removable,
            activeRow: $activeRow,
            onSaved: {
                errors[id] = nil
                onChange()
                FlowToastCenter.shared.show("Shortcut saved", style: .success)
            },
            onRemoved: {
                errors[id] = nil
                onChange()
            },
            onError: { message in
                errors[id] = message
            }
        )
    }

    private var hintBox: some View {
        HStack(spacing: 6) {
            Text("Or tap")
                .flowText(.xs)
                .foregroundStyle(FlowColor.foregroundTertiary)
            FlowShortcutChips(tokens: FlowShortcutRules.tokens(ShortcutStore.shortcut(for: .primaryRecording)))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(width: 216, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.background.opacity(0.6)))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(FlowColor.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
    }

    private func resetToDefault() {
        activeRow = nil
        errors = [:]
        ShortcutStore.setShortcut(FlowShortcutRules.defaultPrimary, for: .primaryRecording)
        FlowShortcutModes.primaryChanged()
        ShortcutStore.setShortcut(FlowShortcutRules.defaultPasteLast, for: .pasteLastTranscription)
        ShortcutStore.setShortcut(FlowShortcutRules.defaultCopyLast, for: .copyLastTranscription)
        FlowShortcutModes.utilityChanged()
        revision += 1
        FlowToastCenter.shared.show("Shortcut saved", style: .success)
    }
}

// MARK: - Selector

private struct FlowShortcutSelector: View {
    let id: String
    let action: ShortcutAction
    let removable: Bool
    @Binding var activeRow: String?
    let onSaved: () -> Void
    let onRemoved: () -> Void
    let onError: (String) -> Void

    @StateObject private var recorder = ShortcutRecorderModel()
    @State private var shortcut: Shortcut?

    var body: some View {
        FlowShortcutBox(isRecording: recorder.isRecording) {
            if recorder.isRecording {
                if let preview = recorder.previewShortcut {
                    FlowShortcutChips(tokens: FlowShortcutRules.tokens(preview))
                } else {
                    Text("Press key or mouse button")
                        .font(FlowFont.sans(12))
                        .foregroundStyle(FlowColor.neutral500)
                }
            } else if let shortcut {
                FlowShortcutChips(tokens: FlowShortcutRules.tokens(shortcut))
            } else {
                Text("Click to add a shortcut")
                    .font(FlowFont.sans(12))
                    .foregroundStyle(FlowColor.neutral500)
            }
        } trailing: {
            if recorder.isRecording {
                FlowShortcutBoxIcon(icon: "x", fallback: "xmark", hint: "Cancel") {
                    stop()
                }
            } else {
                FlowShortcutBoxIcon(icon: "pencil", fallback: "pencil", hint: "Edit shortcut") {
                    start()
                }
                if removable && shortcut != nil {
                    FlowShortcutBoxIcon(icon: "x", fallback: "xmark", hint: "Remove shortcut") {
                        ShortcutStore.setShortcut(nil, for: action)
                        shortcut = nil
                        onRemoved()
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !recorder.isRecording { start() }
        }
        .onAppear {
            shortcut = ShortcutStore.shortcut(for: action)
            recorder.preValidator = { FlowShortcutRules.preValidate($0) }
        }
        .onDisappear { stop() }
        .onChange(of: activeRow) { _, newValue in
            if newValue != id && recorder.isRecording { recorder.cancel() }
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            FlowShortcutCaptureState.isCapturing = isRecording
            if !isRecording && activeRow == id { activeRow = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
            guard let changed = notification.object as? ShortcutAction, changed == action else { return }
            shortcut = ShortcutStore.shortcut(for: action)
        }
    }

    private func start() {
        activeRow = id
        recorder.errorHandler = { error, fallback, captured in
            onError(FlowShortcutRules.message(for: error, fallback: fallback, shortcut: captured))
        }
        recorder.start(action: action) { newShortcut in
            shortcut = newShortcut
            onSaved()
        }
    }

    private func stop() {
        recorder.cancel()
        if activeRow == id { activeRow = nil }
    }
}

/// 216 wide, min 44 tall selector box; the border turns purple while recording.
private struct FlowShortcutBox<Content: View, Trailing: View>: View {
    let isRecording: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            content
            Spacer(minLength: 4)
            HStack(spacing: 2) { trailing }
        }
        .padding(.horizontal, 10)
        .frame(width: 216)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.background))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isRecording ? FlowSettingsPalette.recordingBorder : FlowColor.border, lineWidth: 1)
        )
    }
}

struct FlowShortcutChips: View {
    let tokens: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(FlowFont.sans(15))
                    .foregroundStyle(FlowColor.foreground)
                    .lineLimit(1)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(FlowColor.backgroundTertiary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(FlowColor.border, lineWidth: 1)
                    )
            }
        }
    }
}

private struct FlowShortcutBoxIcon: View {
    let icon: String
    let fallback: String
    let hint: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            FlowSettingsIcon(name: icon, size: 14, stroke: 1.75, color: FlowColor.neutral500, fallback: fallback)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? FlowColor.neutral200 : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(hint)
        .onHover { isHovered = $0 }
    }
}
