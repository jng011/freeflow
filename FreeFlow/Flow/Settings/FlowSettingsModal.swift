import AppKit
import Carbon.HIToolbox
import SwiftUI

enum FlowSettingsPane: String, CaseIterable, Identifiable {
    case general, system, aiCleanup, server, dataPrivacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .system: return "System"
        case .aiCleanup: return "AI Cleanup"
        case .server: return "Server"
        case .dataPrivacy: return "Data and Privacy"
        }
    }

    var iconName: String {
        switch self {
        case .general: return "sliders-horizontal"
        case .system: return "laptop"
        case .aiCleanup: return "sparkles"
        case .server: return "server"
        case .dataPrivacy: return "shield-check"
        }
    }

    var sfFallback: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .system: return "laptopcomputer"
        case .aiCleanup: return "sparkles"
        case .server: return "macstudio"
        case .dataPrivacy: return "checkmark.shield"
        }
    }

    var isAccountSection: Bool {
        self == .server || self == .dataPrivacy
    }
}

enum FlowSettingsDialog: String, Identifiable {
    case shortcuts, microphone, languages
    var id: String { rawValue }

    /// Row that pulses when the dialog is deep-linked.
    var rowAnchor: String {
        switch self {
        case .shortcuts: return "general.shortcuts"
        case .microphone: return "general.microphone"
        case .languages: return "general.languages"
        }
    }
}

/// The 960x640 Settings modal. Shell presents it over a scrim.
struct FlowSettingsModal: View {
    @Binding var pane: FlowSettingsPane
    @Binding var dialog: FlowSettingsDialog?
    let onClose: () -> Void

    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @StateObject private var presenter = FlowSettingsPresenter()
    @StateObject private var keyMonitor = FlowSettingsKeyMonitor()

    init(pane: Binding<FlowSettingsPane>, dialog: Binding<FlowSettingsDialog?>, onClose: @escaping () -> Void) {
        _pane = pane
        _dialog = dialog
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            FlowSettingsRail(pane: $pane)
            content
        }
        .frame(width: 960, height: 640)
        .background(FlowColor.shadeWhite)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(FlowColor.border, lineWidth: 1)
        )
        .flowSettingsOverlays(presenter)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .flowShadow(.xl)
        .environmentObject(presenter)
        .onAppear(perform: appear)
        .onDisappear { keyMonitor.stop() }
        .onChange(of: dialog) { _, newValue in
            if presenter.dialog != newValue { presenter.dialog = newValue }
            if let newValue { openDeepLink(newValue) }
        }
        .onChange(of: presenter.dialog) { _, newValue in
            if dialog != newValue { dialog = newValue }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text(pane.title)
                    .flowText(.serif28)
                    .foregroundStyle(FlowColor.foreground)
                paneView
            }
            .padding(48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .id(pane)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlowColor.shadeWhite)
    }

    @ViewBuilder
    private var paneView: some View {
        switch pane {
        case .general: FlowGeneralPane()
        case .system: FlowSystemPane()
        case .aiCleanup: FlowAICleanupPane()
        case .server: FlowServerPane()
        case .dataPrivacy: FlowDataPrivacyPane()
        }
    }

    private func appear() {
        FlowSettingsAttention.shortcutManager = recordingShortcutManager
        presenter.selectPane = { newPane in pane = newPane }
        presenter.close = onClose
        if let dialog {
            presenter.dialog = dialog
            openDeepLink(dialog)
        }
        keyMonitor.start { event in
            handleKey(event)
        }
    }

    private func openDeepLink(_ dialog: FlowSettingsDialog) {
        if pane != .general { pane = .general }
        presenter.pulse(dialog.rowAnchor)
    }

    /// Esc closes the innermost layer; Option+Up/Down cycles panes.
    private func handleKey(_ event: NSEvent) -> Bool {
        if FlowShortcutCaptureState.isCapturing { return false }
        if let window = event.window, window is NSPanel { return false }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            if presenter.confirmation != nil {
                presenter.confirmation = nil
            } else if presenter.dialog != nil {
                presenter.dialog = nil
            } else if presenter.sheet != nil {
                return false
            } else {
                onClose()
            }
            return true
        }

        if modifiers == [.option], presenter.dialog == nil, presenter.confirmation == nil {
            let all = FlowSettingsPane.allCases
            guard let index = all.firstIndex(of: pane) else { return false }
            if event.keyCode == UInt16(kVK_UpArrow) {
                pane = all[(index - 1 + all.count) % all.count]
                return true
            }
            if event.keyCode == UInt16(kVK_DownArrow) {
                pane = all[(index + 1) % all.count]
                return true
            }
        }
        return false
    }
}

/// Local key monitor that lives as long as the view that owns it.
@MainActor
final class FlowSettingsKeyMonitor: ObservableObject {
    private var monitor: Any?

    func start(_ handler: @escaping (NSEvent) -> Bool) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handler(event) ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Rail

private struct FlowSettingsRail: View {
    @Binding var pane: FlowSettingsPane
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @ObservedObject private var engine = ParleEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Settings")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(FlowSettingsPane.allCases.filter { !$0.isAccountSection }) { item in
                    railRow(item)
                }
            }

            Rectangle()
                .fill(FlowColor.border)
                .frame(height: 1)
                .padding(.vertical, 12)
                .padding(.horizontal, 8)

            sectionTitle("Account")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(FlowSettingsPane.allCases.filter { $0.isAccountSection && ($0 != .server || engine.serverVisible) }) { item in
                    railRow(item)
                }
            }

            Spacer(minLength: 0)
            FlowSettingsRailFooter()
        }
        .padding(.top, 16)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(width: 208)
        .frame(maxHeight: .infinity)
        .background(FlowColor.backgroundTertiary)
        .overlay(alignment: .trailing) {
            Rectangle().fill(FlowColor.border).frame(width: 1)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .flowText(.label)
            .foregroundStyle(FlowColor.neutral500)
            .padding(8)
    }

    private func railRow(_ item: FlowSettingsPane) -> some View {
        FlowSettingsRailRow(
            pane: item,
            isSelected: pane == item,
            badge: badge(for: item)
        ) {
            pane = item
        }
    }

    private func badge(for item: FlowSettingsPane) -> Int? {
        switch item {
        case .general:
            return recordingShortcutManager.isShortcutConfigured ? nil : 1
        case .server:
            return engine.isUsingPC && engine.pcStatus == .offline ? 1 : nil
        case .system, .aiCleanup, .dataPrivacy:
            return nil
        }
    }
}

private struct FlowSettingsRailRow: View {
    let pane: FlowSettingsPane
    let isSelected: Bool
    let badge: Int?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                FlowSettingsIcon(
                    name: pane.iconName, size: 18, stroke: 1.75, color: FlowColor.foreground,
                    fallback: pane.sfFallback
                )
                .frame(width: 20, height: 20)
                Text(pane.title)
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                Spacer(minLength: 4)
                if let badge {
                    FlowSettingsCountBadge(count: badge)
                }
            }
            .padding(8)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected || isHovered ? FlowColor.neutral200 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(FlowMotion.standard, value: isHovered)
    }
}

private struct FlowSettingsRailFooter: View {
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Free Flow v\(version)")
                .flowText(.xs)
                .foregroundStyle(FlowColor.neutral500)
            Spacer(minLength: 4)
            updateButton
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var updateButton: some View {
        if updaterViewModel.availableUpdate != nil {
            FlowSettingsFooterIconButton(
                icon: "rotate-cw", fallback: "arrow.clockwise",
                hint: "Click to update and restart Free Flow"
            ) {
                updaterViewModel.checkForUpdates()
            }
        } else if !updaterViewModel.canCheckForUpdates {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .help("Checking for updates...")
        } else {
            FlowSettingsFooterIconButton(
                icon: "download", fallback: "arrow.down.to.line",
                hint: "Up to date; check again?"
            ) {
                updaterViewModel.checkForUpdates()
            }
        }
    }
}

private struct FlowSettingsFooterIconButton: View {
    let icon: String
    let fallback: String
    let hint: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            FlowSettingsIcon(name: icon, size: 16, stroke: 1.5, color: FlowColor.neutral600, fallback: fallback)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? FlowColor.neutral200 : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
        .onHover { isHovered = $0 }
    }
}
