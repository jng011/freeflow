import Foundation
import os

/// What the Flow Bar shows for the current dictation.
enum FlowDictationPhase: Equatable {
    case idle
    case initializing
    case listening
    case processing
    case error
}

/// Live dictation state for the Flow UI (pill, microphone meter, milestones).
/// The engine drives it from `FreeFlowEngine.recordingState`; nothing else writes it.
@MainActor
final class FlowDictationState: ObservableObject {
    static let shared = FlowDictationState()

    @Published private(set) var phase: FlowDictationPhase = .idle
    @Published private(set) var isHandsFree = false
    /// First non-silent buffer of this session received.
    @Published private(set) var micActive = false
    /// The dead-mic / silence watch fired and audio has not resumed since.
    @Published private(set) var micSilent = false
    /// The dead-mic warning fired at least once this dictation (stays set after audio resumes).
    private(set) var micSilenceWarned = false
    @Published private(set) var recordingStartedAt: Date?
    /// Prompt mode or "Ask Siri" for the current dictation: an icon beside the pill.
    @Published private(set) var modeBadge: FlowModeBadge?

    func setModeBadge(_ badge: FlowModeBadge?) {
        if modeBadge != badge { modeBadge = badge }
    }

    /// The engine's recorder, used for the level meter.
    weak var recorder: Recorder?

    private var recordingState: RecordingState = .idle
    private var errorTask: Task<Void, Never>?
    private var micActiveTask: Task<Void, Never>?
    /// A hands-free lock requested a moment before the recorder reported `.starting`.
    private var pendingHandsFreeAt: Date?

    private static let micActiveAverageDb: Float = -55
    /// Digital silence sits at the recorder floor (-120 dB); any real buffer is above this.
    private static let micActivePeakDb: Float = -115
    private static let handsFreeGrace: TimeInterval = 2

    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowDictationState")

    private init() {}

    /// RMS dBFS of the latest meter snapshot; -160 when not recording.
    func currentInputLevelDB() -> Float {
        guard phase == .listening, let recorder else { return -160 }
        let meter = recorder.audioMeterSnapshot()
        return meter.averagePower <= 0 ? -160 : Float(-60 + 60 * meter.averagePower)
    }

    // MARK: - Engine hooks

    /// Called from `FreeFlowEngine.recordingState`'s didSet.
    func recordingStateDidChange(to state: RecordingState, from previous: RecordingState) {
        guard state != previous else { return }
        recordingState = state
        earlyStartTask?.cancel()
        earlyStartTask = nil

        switch state {
        case .idle:
            stopMicActiveWatch()
            isHandsFree = false
            micSilent = false
            recordingStartedAt = nil
            pendingHandsFreeAt = nil
            if phase != .error {
                setPhase(.idle)
            }
        case .starting:
            errorTask?.cancel()
            errorTask = nil
            micActive = false
            micSilent = false
            micSilenceWarned = false
            let lockedJustBefore = pendingHandsFreeAt.map { Date().timeIntervalSince($0) < Self.handsFreeGrace } ?? false
            isHandsFree = lockedJustBefore
            pendingHandsFreeAt = nil
            recordingStartedAt = Date()
            FlowStartLatency.mark("pill")
            setPhase(.initializing)
        case .recording:
            if recordingStartedAt == nil { recordingStartedAt = Date() }
            FlowStartLatency.mark("micOpen")
            setPhase(.listening)
            startMicActiveWatch()
        case .transcribing, .enhancing, .busy:
            stopMicActiveWatch()
            errorTask?.cancel()
            errorTask = nil
            setPhase(.processing)
        }
    }

    private var earlyStartTask: Task<Void, Never>?

    /// The key was just pressed: open the pill now, with the start sound, instead of after
    /// the permission check and recorder setup (about 85 ms later). Falls back to rest if
    /// the recorder never starts.
    func keyPressedToStart() {
        guard recordingState == .idle, phase == .idle || phase == .error else { return }
        errorTask?.cancel()
        errorTask = nil
        FlowStartLatency.mark("pillEarly")
        setPhase(.initializing)
        earlyStartTask?.cancel()
        earlyStartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.recordingState == .idle, self.phase == .initializing else { return }
            self.setPhase(.idle)
        }
    }

    /// Locks (or unlocks) hands-free for the current session. A lock requested just before
    /// the recorder starts is kept and applied when it does.
    func setHandsFree(_ handsFree: Bool) {
        guard handsFree else {
            pendingHandsFreeAt = nil
            if isHandsFree { isHandsFree = false }
            return
        }
        switch recordingState {
        case .starting, .recording:
            if !isHandsFree { isHandsFree = true }
        case .idle:
            pendingHandsFreeAt = Date()
        case .transcribing, .enhancing, .busy:
            break
        }
    }

    /// ParleMicWatch reports pure digital silence (true) or that audio resumed (false).
    func setMicSilent(_ silent: Bool) {
        guard recordingState == .recording || recordingState == .starting || !silent else { return }
        if micSilent != silent { micSilent = silent }
        if silent { micSilenceWarned = true }
        if !silent { noteAudioReceived() }
    }

    func noteAudioReceived() {
        guard recordingState == .recording || recordingState == .starting else { return }
        if !micActive {
            micActive = true
            FlowStartLatency.finish("firstAudio")
        }
    }

    /// The pipeline failed: red border for 500 ms, then back to rest.
    func flashError() {
        guard recordingState == .idle else { return }
        errorTask?.cancel()
        setPhase(.error)
        errorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, self.phase == .error else { return }
            self.setPhase(self.recordingState == .idle ? .idle : self.mappedPhase(self.recordingState))
        }
    }

    // MARK: - Private

    private func setPhase(_ newPhase: FlowDictationPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        // The badge belongs to one dictation; it goes when the pill goes back to rest.
        if newPhase == .idle { modeBadge = nil }
    }

    private func mappedPhase(_ state: RecordingState) -> FlowDictationPhase {
        switch state {
        case .idle: return .idle
        case .starting: return .initializing
        case .recording: return .listening
        case .transcribing, .enhancing, .busy: return .processing
        }
    }

    /// 20 Hz check for the first real audio of the session.
    private func startMicActiveWatch() {
        stopMicActiveWatch()
        guard !micActive else { return }
        micActiveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.micActive { return }
                if let levels = self.recorder?.rawMeterLevels(),
                    levels.average > Self.micActiveAverageDb || levels.peak > Self.micActivePeakDb
                {
                    self.noteAudioReceived()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopMicActiveWatch() {
        micActiveTask?.cancel()
        micActiveTask = nil
    }
}
