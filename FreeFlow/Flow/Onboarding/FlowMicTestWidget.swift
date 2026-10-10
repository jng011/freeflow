import AVFoundation
import AppKit
import CoreAudio
import SwiftUI

// Onboarding mic test: a temporary AVAudioEngine input tap that runs only while
// the "Test your microphone" page is visible. Sounds are suspended meanwhile.

/// Builds the input tap outside any actor so the audio thread never touches main-actor state.
enum FlowMicTap {
    /// Points the input node at `deviceID` (when given), installs a level tap and starts the engine.
    static func start(
        engine: AVAudioEngine,
        deviceID: AudioDeviceID?,
        onLevel: @escaping @Sendable (Float) -> Void
    ) -> Bool {
        let input = engine.inputNode
        if let deviceID, let unit = input.audioUnit {
            var id = deviceID
            AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return false }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            onLevel(rmsDB(buffer))
        }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
    }

    static func stop(engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// RMS of the first channel in dBFS (-160 for silence).
    static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -160 }
        let samples = data[0]
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return -160 }
        return max(-160, 20 * log10(rms))
    }
}

@MainActor
final class FlowMicTestMeter: ObservableObject {
    enum Status: Equatable { case idle, listening, noPermission, noDevice, failed }

    @Published private(set) var status: Status = .idle
    /// 0...1, smoothed.
    @Published private(set) var level: Double = 0
    @Published private(set) var heardVoice = false
    /// True after 6 s on the page without any level.
    @Published private(set) var showsCantHear = false

    private var engine: AVAudioEngine?
    private var silenceTask: Task<Void, Never>?
    private var soundSuspension: Task<Void, Never>?
    private var isActive = false

    private static let floorDB: Double = -60
    private static let ceilingDB: Double = -12
    private static let voiceDB: Float = -45

    func start() {
        guard !isActive else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.start()
                    } else {
                        self?.status = .noPermission
                    }
                }
            }
            return
        default:
            status = .noPermission
            return
        }

        let manager = AudioDeviceManager.shared
        let deviceID: AudioDeviceID?
        switch manager.inputMode {
        case .systemDefault:
            deviceID = manager.getSystemDefaultDevice()
        case .custom, .prioritized:
            deviceID = manager.selectedDeviceID ?? manager.getSystemDefaultDevice()
        }
        guard deviceID != nil || !manager.availableDevices.isEmpty else {
            status = .noDevice
            return
        }

        let engine = AVAudioEngine()
        let started = FlowMicTap.start(engine: engine, deviceID: deviceID) { db in
            Task { @MainActor [weak self] in
                self?.ingest(db)
            }
        }
        guard started else {
            status = manager.availableDevices.isEmpty ? .noDevice : .failed
            return
        }

        self.engine = engine
        isActive = true
        status = .listening
        level = 0
        heardVoice = false
        showsCantHear = false

        soundSuspension = Task { @MainActor [weak self] in
            await FlowSoundSettings.withSoundsSuspended {
                while !Task.isCancelled, self?.isActive == true {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        silenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, self.isActive, !self.heardVoice else { return }
            self.showsCantHear = true
        }
    }

    func stop() {
        silenceTask?.cancel()
        silenceTask = nil
        soundSuspension?.cancel()
        soundSuspension = nil
        if let engine {
            FlowMicTap.stop(engine: engine)
        }
        engine = nil
        isActive = false
        level = 0
        if status == .listening { status = .idle }
    }

    /// Stops and starts again on the current device (after the microphone changes).
    func restart() {
        let wasActive = isActive || status != .idle
        stop()
        status = .idle
        if wasActive { start() }
    }

    private func ingest(_ db: Float) {
        guard isActive else { return }
        let normalized = (Double(db) - Self.floorDB) / (Self.ceilingDB - Self.floorDB)
        let target = min(max(normalized, 0), 1)
        // Fast attack, slower release so the bars do not flicker.
        level = target > level ? target : level * 0.8 + target * 0.2
        if db > Self.voiceDB, !heardVoice {
            heardVoice = true
            showsCantHear = false
        }
    }
}

// MARK: - Widget

/// "Do you see purple bars while you speak?" card for the right panel.
struct FlowMicTestWidget: View {
    @ObservedObject var meter: FlowMicTestMeter
    let onChangeMicrophone: () -> Void
    let onYes: () -> Void

    var body: some View {
        FlowOnboardingWidgetCard {
            switch meter.status {
            case .noPermission:
                errorState(
                    title: "Microphone access required",
                    detail: "Allow Free Flow to use your microphone in System Settings, then come back here."
                ) {
                    Button("Open Settings") { openMicrophoneSettings() }
                        .buttonStyle(FlowButtonStyle(variant: .primary, size: .sm))
                }
            case .noDevice:
                errorState(
                    title: "No microphone detected",
                    detail: "Connect a microphone or open your laptop lid, then try again."
                ) {
                    Button("Try again") { meter.restart() }
                        .buttonStyle(FlowButtonStyle(variant: .secondary, size: .sm))
                }
            case .failed:
                errorState(
                    title: "We couldn't start your microphone",
                    detail: "Pick another microphone or try again."
                ) {
                    HStack(spacing: 8) {
                        Button("Change microphone", action: onChangeMicrophone)
                            .buttonStyle(FlowButtonStyle(variant: .secondary, size: .sm))
                        Button("Try again") { meter.restart() }
                            .buttonStyle(FlowButtonStyle(variant: .primary, size: .sm))
                    }
                }
            case .idle, .listening:
                listening
            }
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Do you see purple bars while you speak?")
                .flowText(.h3)
                .foregroundStyle(FlowColor.foreground)
                .fixedSize(horizontal: false, vertical: true)

            FlowMicTestBars(level: meter.level)

            if meter.showsCantHear {
                HStack(alignment: .top, spacing: 8) {
                    FlowIcon(.circleAlert, size: 16, stroke: 1.75, color: FlowColor.warning)
                    Text("We can't hear you. Try changing your mic.")
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                Button("Change microphone", action: onChangeMicrophone)
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .md))
                Spacer(minLength: 8)
                Button("Yes", action: onYes)
                    .buttonStyle(FlowButtonStyle(variant: .primary, size: .md))
            }
        }
        .animation(FlowMotion.standard, value: meter.showsCantHear)
    }

    private func errorState<Actions: View>(
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                FlowIcon(.circleAlert, size: 20, stroke: 1.75, color: FlowColor.destructive)
                Text(title)
                    .flowText(.h4)
                    .foregroundStyle(FlowColor.foreground)
            }
            Text(detail)
                .flowText(.sm)
                .foregroundStyle(FlowColor.foregroundTertiary)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
    }

    private func openMicrophoneSettings() {
        if let url = FlowPermission.microphone.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 10 capsule bars (16x48) spread across a backgroundTertiary box.
struct FlowMicTestBars: View {
    let level: Double
    private let count = 10

    var body: some View {
        let active = Int((min(max(level, 0), 1) * Double(count)).rounded())
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                if index > 0 { Spacer(minLength: 4) }
                Capsule()
                    .fill(index < active ? FlowColor.chord600 : FlowColor.neutral200)
                    .frame(width: 16, height: 48)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.backgroundTertiary))
        .animation(.easeOut(duration: 0.08), value: active)
    }
}

/// "QUICK TIP" card shown under the mic test text.
struct FlowQuickTipCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Quick tip".uppercased())
                .flowText(.label)
                .foregroundStyle(FlowColor.vast950)
            Text(text)
                .flowText(.sm)
                .foregroundStyle(FlowColor.vast950)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.dawn500))
    }
}
