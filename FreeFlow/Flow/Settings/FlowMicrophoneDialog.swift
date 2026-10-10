import CoreAudio
import SwiftUI

private enum FlowMicSelection: Hashable {
    case systemDefault
    case device(String)
    case ranked
}

private struct FlowMicOption: Identifiable {
    let id: String
    let selection: FlowMicSelection
    let title: String
    let detail: String?
    let warning: String?
    let isAvailable: Bool
}

struct FlowMicrophoneDialog: View {
    let onClose: () -> Void

    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @AppStorage(FlowKeys.notifySuggestions) private var notifySuggestions = true
    @State private var isEditingRanking = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        FlowSettingsDialogFrame(title: "Microphone", subtitle: "Used for dictation.", maxWidth: 512) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if isEditingRanking {
                        rankingEditor
                    } else {
                        ForEach(options) { option in
                            FlowMicOptionCard(
                                option: option,
                                isSelected: option.selection == currentSelection,
                                showsLiveLevel: option.selection == currentSelection
                            ) {
                                select(option.selection)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(width: 464)
            .frame(maxHeight: 402)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button(isEditingRanking ? "Done editing" : "Edit Ranking") {
                withAnimation(FlowMotion.standard) { isEditingRanking.toggle() }
            }
            .flowSettingsButton(.link)
            Spacer(minLength: 12)
            Button("Done", action: onClose)
                .flowSettingsButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
        .onAppear { audioDeviceManager.loadAvailableDevices() }
    }

    // MARK: Options

    private var currentSelection: FlowMicSelection {
        switch audioDeviceManager.inputMode {
        case .systemDefault:
            return .systemDefault
        case .prioritized:
            return .ranked
        case .custom:
            guard let id = audioDeviceManager.selectedDeviceID,
                let device = audioDeviceManager.availableDevices.first(where: { $0.id == id })
            else { return .systemDefault }
            return .device(device.uid)
        }
    }

    private var options: [FlowMicOption] {
        var result: [FlowMicOption] = []
        let systemName = audioDeviceManager.getSystemDefaultDeviceName()
        result.append(
            FlowMicOption(
                id: "system",
                selection: .systemDefault,
                title: FlowMicrophoneNaming.systemTitle,
                detail: systemName.map { "Currently \($0)" } ?? "Follows your Mac's sound settings",
                warning: nil,
                isAvailable: true
            ))

        let devices = audioDeviceManager.availableDevices
        let hasInternal = devices.contains { audioDeviceManager.isInternalMicrophone($0.id) }
        let sorted = devices.sorted { lhs, rhs in
            let l = audioDeviceManager.isInternalMicrophone(lhs.id)
            let r = audioDeviceManager.isInternalMicrophone(rhs.id)
            if l != r { return l }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        if !hasInternal && audioDeviceManager.isClamshellClosed {
            result.append(
                FlowMicOption(
                    id: "builtin-closed",
                    selection: .device("builtin-closed"),
                    title: FlowMicrophoneNaming.builtInTitle,
                    detail: "Laptop lid is closed",
                    warning: nil,
                    isAvailable: false
                ))
        }

        for device in sorted {
            let isInternal = audioDeviceManager.isInternalMicrophone(device.id)
            result.append(
                FlowMicOption(
                    id: device.uid,
                    selection: .device(device.uid),
                    title: isInternal ? FlowMicrophoneNaming.builtInTitle : device.name,
                    detail: isInternal ? device.name : nil,
                    warning: notifySuggestions && isSlowToStart(device.id, name: device.name)
                        ? "AirPods can be slow to start and less accurate. The built-in mic works better." : nil,
                    isAvailable: true
                ))
        }

        if !audioDeviceManager.prioritizedDevices.isEmpty {
            result.append(
                FlowMicOption(
                    id: "ranked",
                    selection: .ranked,
                    title: "Use my ranking",
                    detail: "Picks the highest ranked microphone that is connected",
                    warning: nil,
                    isAvailable: true
                ))
        }
        return result
    }

    private func isSlowToStart(_ id: AudioDeviceID, name: String) -> Bool {
        FlowMicrophoneTraits.isSlowToStart(id, name: name, manager: audioDeviceManager)
    }

    private func select(_ selection: FlowMicSelection) {
        switch selection {
        case .systemDefault:
            audioDeviceManager.selectInputMode(.systemDefault)
        case .ranked:
            audioDeviceManager.selectInputMode(.prioritized)
        case .device(let uid):
            guard let device = audioDeviceManager.availableDevices.first(where: { $0.uid == uid }) else { return }
            audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    // MARK: Ranking

    private var rankedDevices: [PrioritizedDevice] {
        audioDeviceManager.prioritizedDevices.sorted { $0.priority < $1.priority }
    }

    private var unrankedDevices: [(id: AudioDeviceID, uid: String, name: String)] {
        audioDeviceManager.availableDevices.filter { device in
            !audioDeviceManager.prioritizedDevices.contains { $0.id == device.uid }
        }
    }

    @ViewBuilder
    private var rankingEditor: some View {
        Text("Drag to reorder microphone preference ranking")
            .flowText(.xs)
            .foregroundStyle(FlowColor.foregroundTertiary)

        ForEach(Array(rankedDevices.enumerated()), id: \.element.id) { index, device in
            let isAvailable = audioDeviceManager.availableDevices.contains { $0.uid == device.id }
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .flowText(.smStrong)
                    .monospacedDigit()
                    .foregroundStyle(FlowColor.neutral500)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.name)
                        .flowText(.smEmph)
                        .foregroundStyle(FlowColor.neutral600)
                        .lineLimit(1)
                    if !isAvailable {
                        Text("Not connected")
                            .flowText(.xs)
                            .foregroundStyle(FlowColor.foregroundTertiary)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    audioDeviceManager.removePrioritizedDevice(id: device.id)
                } label: {
                    Text("Forget device")
                        .flowText(.xs)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                }
                .buttonStyle(.plain)
                FlowSettingsIcon(name: "arrow-up-down", size: 16, stroke: 1.5, color: FlowColor.neutral500, fallback: "line.3.horizontal")
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(FlowColor.backgroundTertiary))
            .opacity(isAvailable ? 1 : 0.6)
            .draggable(device.id)
            .dropDestination(for: String.self) { items, _ in
                guard let moved = items.first else { return false }
                move(id: moved, before: device.id)
                return true
            }
        }

        if !unrankedDevices.isEmpty {
            Text("Other devices (\(unrankedDevices.count))")
                .flowText(.xsStrong)
                .foregroundStyle(FlowColor.neutral500)
                .padding(.top, 8)
            ForEach(unrankedDevices, id: \.uid) { device in
                HStack {
                    Text(device.name)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.neutral600)
                        .lineLimit(1)
                    Spacer()
                    Button("Add") {
                        audioDeviceManager.addPrioritizedDevice(uid: device.uid, name: device.name)
                    }
                    .flowSettingsButton(.secondary, size: .xs)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
            }
        }
    }

    private func move(id: String, before targetID: String) {
        guard id != targetID else { return }
        var devices = rankedDevices
        guard let from = devices.firstIndex(where: { $0.id == id }) else { return }
        let item = devices.remove(at: from)
        let to = devices.firstIndex(where: { $0.id == targetID }) ?? devices.count
        devices.insert(item, at: to)
        let updated = devices.enumerated().map { index, device in
            PrioritizedDevice(id: device.id, name: device.name, priority: index, modelUID: device.modelUID)
        }
        audioDeviceManager.updatePriorities(devices: updated)
    }
}

// MARK: - Card

private struct FlowMicOptionCard: View {
    let option: FlowMicOption
    let isSelected: Bool
    let showsLiveLevel: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(FlowFont.sans(16, weight: 600))
                        .foregroundStyle(FlowColor.neutral600)
                    if let detail = option.detail {
                        Text(detail)
                            .flowText(.sm)
                            .foregroundStyle(FlowColor.foregroundTertiary)
                    }
                    if let warning = option.warning {
                        Text(warning)
                            .flowText(.xs)
                            .foregroundStyle(FlowColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
                FlowMicLevelMeter(isLive: showsLiveLevel && option.isAvailable)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? FlowSettingsPalette.dawn700 : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isAvailable)
        .opacity(option.isAvailable ? 1 : 0.6)
        .onHover { isHovered = $0 }
        .animation(FlowMotion.standard, value: isHovered)
    }

    private var fill: Color {
        if isSelected { return FlowSettingsPalette.selectedFill }
        return isHovered ? FlowColor.neutral200 : FlowColor.backgroundTertiary
    }
}

/// 24 segments, 12 tall. Shows live levels only while a dictation is already recording;
/// it never opens its own capture session.
struct FlowMicLevelMeter: View {
    let isLive: Bool
    var segments = 24

    var body: some View {
        if isLive {
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                bars(active: activeSegments())
            }
        } else {
            bars(active: 0)
        }
    }

    private func bars(active: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(index < active ? FlowSettingsPalette.dawn700 : FlowColor.neutral200)
                    .frame(height: 12)
            }
        }
    }

    @MainActor
    private func activeSegments() -> Int {
        let state = FlowDictationState.shared
        guard state.phase == .listening else { return 0 }
        let db = state.currentInputLevelDB()
        let normalized = (Double(db) + 60) / 60
        return Int((min(max(normalized, 0), 1) * Double(segments)).rounded())
    }
}

/// Shared microphone checks, used by the dialog's per-device warning and the
/// AirPods tip shown at dictation start.
enum FlowMicrophoneTraits {
    /// AirPods (by name) or any Bluetooth input: slow to start and less accurate.
    static func isSlowToStart(_ id: AudioDeviceID, name: String, manager: AudioDeviceManager) -> Bool {
        if name.localizedCaseInsensitiveContains("AirPods") { return true }
        let transport = manager.getUInt32DeviceProperty(
            deviceID: id, selector: kAudioDevicePropertyTransportType)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}
