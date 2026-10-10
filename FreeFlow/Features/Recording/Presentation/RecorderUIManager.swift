import AppKit
import Combine
import Foundation
import SwiftUI
import os

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch
    case mini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch:
            return String(localized: "Notch")
        case .mini:
            return String(localized: "Mini")
        }
    }

    static var stored: RecorderPanelStyle {
        let rawValue = UserDefaults.standard.string(forKey: "RecorderType") ?? RecorderPanelStyle.mini.rawValue
        return RecorderPanelStyle(rawValue: rawValue) ?? .mini
    }
}

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    func dismissRecorderPanel() async
}

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    /// Kept so settings, backup and import code compile. The stored value is ignored: the
    /// recorder UI is always the Flow Bar.
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: "RecorderType")
        }
    }

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .mini }
    }

    /// True while a dictation session is active (from toggle start until dismiss).
    /// RecordingShortcutManager relies on this to decide whether a key press starts or stops
    /// recording. It does NOT mean "the Flow Bar is on screen": the bar is always there.
    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }

            if isRecorderPanelVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanel()
            }
        }
    }

    private var panelInvalidationTask: Task<Void, Never>?
    private var didSetupNotifications = false
    private var lifecycleCancellable: AnyCancellable?
    private var assistantCancellable: AnyCancellable?

    private weak var engine: FreeFlowEngine?
    private var recorder: Recorder?

    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "RecorderUIManager")

    init() {}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Call after FreeFlowEngine is created to break the circular init dependency.
    func configure(engine: FreeFlowEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        setupNotifications()
        FlowBarController.shared.configure(engine: engine, recorderUIManager: self)
        observeAssistantResponses(engine: engine)
    }

    // MARK: - Recorder Panel Management

    /// A dictation session started. The Flow Bar panel always exists; this only tells it a
    /// session is active so it comes forward on the cursor's screen.
    private func showRecorderPanel() {
        guard engine != nil, recorder != nil else { return }
        FlowBarController.shared.sessionDidStart()
        logger.notice("Recorder session started (Flow Bar)")
    }

    private func hideRecorderPanel() {
        // `dismissRecorderPanel()` calls this directly and then clears the flag, which calls it
        // again, so this deliberately stays at debug level.
        logger.debug("Recorder session ended (Flow Bar)")
        FlowBarController.shared.sessionDidEnd()
    }

    // MARK: - Panel Invalidation

    /// The Flow Bar must survive sleep/wake cycles and display reconfigurations.
    ///
    /// A window that stopped rendering after a WindowServer hiccup can still report itself as
    /// visible, so on wake an idle bar is rebuilt outright. During a dictation it is only
    /// repositioned, so an active session never loses its UI.
    ///
    /// `didChangeScreenParameters` fires several times per reconfiguration and displays need a
    /// moment to settle afterwards, so the work is debounced and re-armed on every event.
    private func invalidatePanels(reason: String, rebuild: Bool) {
        panelInvalidationTask?.cancel()
        panelInvalidationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.applyPanelInvalidation(reason: reason, rebuild: rebuild)
        }
    }

    private func applyPanelInvalidation(reason: String, rebuild: Bool) {
        FlowBarController.shared.handleScreenInvalidation(
            reason: reason,
            rebuild: rebuild && !isRecorderPanelVisible
        )
    }

    // MARK: - Assistant responses

    /// Respond mode used to render the answer inside the recorder panel. The Flow Bar shows it
    /// as a standard toast instead. The session stays open (so a follow-up dictation still
    /// works) until the toast is closed or times out.
    private func observeAssistantResponses(engine: FreeFlowEngine) {
        assistantCancellable = engine.assistantSession.$phase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.handleAssistantPhase(phase)
            }
    }

    private func handleAssistantPhase(_ phase: AssistantPhase) {
        guard let engine else { return }

        switch phase {
        case .ready:
            guard
                let response = engine.assistantSession.messages.last(where: { $0.role == .assistant })?.content,
                !response.isEmpty
            else { return }

            var toast = FlowBarToast(style: .standard, title: "Response")
            toast.body = response
            toast.actionTitle = "Copy"
            toast.action = {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(response, forType: .string)
            }
            toast.secondaryActionTitle = "Close"
            toast.secondaryAction = {}
            toast.duration = 30
            FlowBarController.shared.showToast(toast) { [weak self] reason in
                self?.assistantToastDidEnd(reason)
            }
        case .failed(let message):
            var toast = FlowBarToast(style: .standard, title: "Response failed")
            toast.body = message
            toast.isError = true
            toast.secondaryActionTitle = "Close"
            toast.secondaryAction = {}
            toast.duration = 8
            FlowBarController.shared.showToast(toast) { [weak self] reason in
                self?.assistantToastDidEnd(reason)
            }
        case .inactive, .responding, .sendingFollowUp:
            break
        }
    }

    private func assistantToastDidEnd(_ reason: FlowBarDismissReason) {
        switch reason {
        case .replaced, .dictationStarted:
            // A follow-up or new dictation is starting; leave the session alone.
            return
        case .timeout, .closed, .action:
            break
        }
        Task { @MainActor [weak self] in
            guard let self, let engine = self.engine, self.isRecorderPanelVisible,
                engine.recordingState == .idle,
                !engine.assistantSession.isBusy,
                FlowDictationState.shared.phase == .idle
            else { return }
            await self.dismissRecorderPanel()
        }
    }

    // MARK: - Recorder Panel Management

    func toggleRecorderPanel(modeId: UUID? = nil) async {
        guard let engine = engine else { return }

        if isRecorderPanelVisible {
            switch engine.recordingState {
            case .recording:
                await engine.toggleRecord(modeId: modeId)
            case .starting, .transcribing, .enhancing:
                await cancelRecording()
            case .idle:
                if engine.assistantSession.canSendFollowUp {
                    SoundManager.shared.playStartSound()
                    await engine.toggleRecord(
                        modeId: modeId,
                        isAssistantFollowUp: true
                    )
                } else {
                    await dismissRecorderPanel()
                }
            case .busy:
                await dismissRecorderPanel()
            }
        } else {
            FlowOpenRouterFast.prewarm()
            FlowStartLatency.mark("sound")
            SoundManager.shared.playStartSound()
            FlowDictationState.shared.keyPressedToStart()
            isRecorderPanelVisible = true
            await engine.toggleRecord(modeId: modeId)
        }
    }

    func finishRecordingAndSend() async {
        guard isRecorderPanelVisible, let engine, engine.recordingState == .recording else { return }
        await engine.toggleRecord(sendAfterPaste: true)
    }

    var isActivelyRecording: Bool {
        isRecorderPanelVisible && engine?.recordingState == .recording
    }

    var recordingStatePublisher: AnyPublisher<RecordingState, Never>? {
        engine?.$recordingState.eraseToAnyPublisher()
    }

    func dismissRecorderPanel() async {
        guard let engine = engine else { return }

        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func resetOnLaunch() async {
        guard let engine = engine else { return }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func cancelRecording() async {
        guard let engine = engine else { return }
        await engine.cancelRecording()
        await dismissRecorderPanel()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        guard !didSetupNotifications else { return }
        didSetupNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
        lifecycleCancellable = LifecycleObserver.shared.publisher(
            for: [.systemDidWake, .displaysDidWake, .screenConfigurationChanged]
        ).sink { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .systemDidWake:
                    self.invalidatePanels(reason: "system wake", rebuild: true)
                case .displaysDidWake:
                    self.invalidatePanels(reason: "displays wake", rebuild: true)
                case .screenConfigurationChanged:
                    self.invalidatePanels(reason: "screen parameters changed", rebuild: false)
                default:
                    break
                }
            }
        }
    }

    @objc public func handleToggleRecorderPanelNotification() {
        Task {
            await toggleRecorderPanel()
        }
    }

    @objc public func handleDismissRecorderPanelNotification() {
        Task {
            switch engine?.recordingState {
            case .starting, .recording, .transcribing, .enhancing:
                await cancelRecording()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }
}
