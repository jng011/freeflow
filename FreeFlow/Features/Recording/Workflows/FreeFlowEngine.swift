import AVFoundation
import AppKit
import Foundation
import SwiftData
import SwiftUI
import os

private final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State {
        var bufferedChunks: [Data] = []
        var callback: ((Data) -> Void)?
        var isActive = false
        var droppedChunks = 0
    }

    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ data: Data) {
        let callback = state.withLock { state -> ((Data) -> Void)? in
            guard state.isActive else {
                if state.bufferedChunks.count < maxBufferedChunks {
                    state.bufferedChunks.append(data)
                } else {
                    state.droppedChunks += 1
                }
                return nil
            }
            return state.callback
        }
        callback?(data)
    }

    func activate(_ callback: @escaping (Data) -> Void) -> Int {
        let initialState = state.withLock { state -> (chunks: [Data], droppedChunks: Int) in
            state.callback = callback
            state.isActive = false
            let chunks = state.bufferedChunks
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.droppedChunks = 0
            return (chunks, droppedChunks)
        }
        var chunksToSend = initialState.chunks
        var droppedChunks = initialState.droppedChunks

        while true {
            for chunk in chunksToSend {
                callback(chunk)
            }

            let nextState = state.withLock { state -> (chunks: [Data], droppedChunks: Int, finished: Bool) in
                let droppedChunks = state.droppedChunks
                state.droppedChunks = 0
                guard !state.bufferedChunks.isEmpty else {
                    state.isActive = true
                    return ([], droppedChunks, true)
                }
                let chunks = state.bufferedChunks
                state.bufferedChunks.removeAll()
                return (chunks, droppedChunks, false)
            }
            droppedChunks += nextState.droppedChunks

            if nextState.finished {
                return droppedChunks
            }
            chunksToSend = nextState.chunks
        }
    }

    func reset() -> Int {
        state.withLock { state -> Int in
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.callback = nil
            state.isActive = false
            state.droppedChunks = 0
            return droppedChunks
        }
    }
}

@MainActor
class FreeFlowEngine: NSObject, ObservableObject {
    private enum RecordingUseCase {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool {
            self == .assistantFollowUp
        }
    }

    @Published var recordingState: RecordingState = .idle {
        didSet {
            guard recordingState != oldValue else { return }
            FlowDictationState.shared.recordingStateDidChange(to: recordingState, from: oldValue)
            if recordingState == .starting {
                // A new dictation: the previous cancel can no longer be undone.
                FlowCancelUndo.discard()
            }
            if oldValue == .recording {
                durationLimitTask?.cancel()
                durationLimitTask = nil
            }
            if recordingState == .idle, oldValue == .starting || oldValue == .recording, let activeTiming {
                // Recording never reached the pipeline (failed to start or was reset).
                activeTiming.cancelDelayNotice()
                activeTiming.resignCurrent()
                self.activeTiming = nil
            }
        }
    }
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    private var activeRecordingStartID: UUID?
    private var activePipelineTranscriptionID: UUID?
    private var canceledPipelineTranscriptionIDs = Set<UUID>()
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activePipelineUseCase: RecordingUseCase = .newSession
    private var activeRecordingContextStore: RecordingContextSnapshotStore?
    private var activeRecordingContextTasks: [Task<Void, Never>] = []
    /// Flow stats and target app for the dictation being recorded.
    private var activeTiming: FlowDictationTiming?
    private var activePipelineTranscription: Transcription?
    private var durationLimitTask: Task<Void, Never>?
    /// A cancel that arrived during the 250 ms tail after stop; the tail finishes it.
    private var pendingTailCancelReason: FlowCancelReason?
    private var microphoneDisconnectObserver: NSObjectProtocol?

    /// Maximum dictation length, with a warning a minute before.
    private static let dictationLimit: TimeInterval = 20 * 60
    private static let dictationLimitWarning: TimeInterval = 19 * 60

    let recorder = Recorder()
    var recordedFile: URL? = nil
    /// Rows still pending from before this time were left by a previous run.
    private let launchDate = Date()
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FreeFlowEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.jaydenghiyam.FreeFlow")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
        FlowDictationState.shared.recorder = recorder
        FlowDictationActions.configure(engine: self)
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    // MARK: - Toggle Record

    func toggleRecord(modeId: UUID? = nil, isAssistantFollowUp: Bool = false, sendAfterPaste: Bool = false) async {
        if recordingState == .starting {
            await cancelRecording()
            return
        }

        if recordingState == .recording {
            // The stop sound plays the moment the person stops, not when the paste lands.
            SoundManager.shared.playStopSound()
            let timing = activeTiming
            activeTiming = nil
            timing?.markStopped()
            activePipelineUseCase = activeRecordingUseCase
            activeRecordingUseCase = .newSession
            activeRecordingStartID = nil
            partialTranscript = ""
            pendingTailCancelReason = nil
            recordingState = .transcribing
            // Keep listening a moment after stop so the last syllable isn't clipped. 120 ms covers
            // the mic buffer (~11 ms) and a word trailing past the key; 250 ms was just a wait.
            FlowStopLatency.stopped()
            let tailStarted = Date()
            ParleCaret.prefetch()
            let tailLeft = 0.12 - Date().timeIntervalSince(tailStarted)
            if tailLeft > 0 { try? await Task.sleep(for: .seconds(tailLeft)) }
            await recorder.stopRecording()
            FlowStopLatency.mark("micStopped")
            if !shouldCancelRecording { (currentSession as? ParlePCStreamingSession)?.beginFinish() }

            if let recordedFile {
                if !shouldCancelRecording {
                    let transcription = makeRecordingTranscription(
                        for: recordedFile,
                        text: "",
                        duration: 0,
                        transcriptionStatus: .pending
                    )
                    modelContext.insert(transcription)
                    try? modelContext.save()
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

                    await runPipeline(
                        on: transcription,
                        audioURL: recordedFile,
                        contextStore: activeRecordingContextStore,
                        sendAfterPaste: sendAfterPaste,
                        timing: timing
                    )
                } else {
                    // Canceled during the tail: keep the audio, never paste.
                    let reason = pendingTailCancelReason ?? .user
                    pendingTailCancelReason = nil
                    let canceled = await finishActiveRecorderCancellation(keepAudio: reason != .otherShortcut && reason != .lonelyTap)
                    handleFlowCancel(reason: reason, transcription: canceled, timing: timing)
                }
            } else {
                timing?.cancelDelayNotice()
                timing?.resignCurrent()
                cancelCurrentSession()
                if !shouldCancelRecording {
                    logger.error("❌ No recorded file found after stopping recording")
                }
                recordingState = .idle
                await cleanupResources()
            }
        } else {
            let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
            let recordingUseCase: RecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession

            activePipelineTranscriptionID = nil
            shouldCancelRecording = false
            partialTranscript = ""
            activeRecordingUseCase = recordingUseCase
            clearActiveRecordingContext()
            // Command mode: this recording edits the selection captured at key down.
            CommandModeController.shared.recordingWillStart()
            // Voice switches: score the speaker live while this dictation records.
            if !recordingUseCase.isAssistantFollowUp, !CommandModeController.shared.hasActiveCommand {
                FlowVoiceGate.shared.begin()
            } else {
                FlowVoiceGate.shared.cancel()
            }

            if !recordingUseCase.isAssistantFollowUp {
                assistantSession.reset()
            }

            requestRecordPermission { [self] granted in
                if granted {
                    Task { @MainActor [self] in
                        guard await self.passesRecordingPreflight() else {
                            return
                        }

                        let startID = UUID()
                        self.activeRecordingStartID = startID
                        let activeModeTask = ActiveWindowService.shared.beginApplyingConfiguration(modeId: modeId) {
                            [weak self] in
                            guard let self else { return false }
                            return self.activeRecordingStartID == startID && !self.shouldCancelRecording
                        }

                        do {
                            let fileName = "\(UUID().uuidString).wav"
                            let permanentURL = self.recordingsDirectory.appendingPathComponent(fileName)
                            self.recordedFile = permanentURL

                            let realtimeAudioGate = RealtimeAudioChunkGate()
                            self.recorder.onAudioChunk = realtimeAudioGate.receive

                            // Capture the target app now: it is the app the words are for.
                            let timing = FlowDictationTiming()
                            timing.makeCurrent()
                            self.activeTiming = timing

                            self.recordingState = .starting

                            try await self.recorder.startRecording(toOutputFile: permanentURL)

                            guard self.activeRecordingStartID == startID,
                                self.recorderUIManager?.isRecorderPanelVisible ?? false,
                                !self.shouldCancelRecording
                            else {
                                activeModeTask.cancel()
                                let shouldKeepRecordingFile = self.shouldCancelRecording
                                if self.activeRecordingStartID == startID {
                                    await self.recorder.stopRecording()
                                    if !shouldKeepRecordingFile {
                                        self.recordedFile = nil
                                    }
                                    self.recordingState = .idle
                                    self.activeRecordingStartID = nil
                                }
                                return
                            }

                            self.recordingState = .recording
                            self.startDurationLimit(for: startID)
                            ParleEngine.shared.beginDictationAccessCheck()

                            // Only retire the previous paste session once recording
                            // has actually started. Preflight/permission failures
                            // must leave it available for Auto Learn capture.
                            if AutoLearnSettings.isEnabled {
                                await AutoLearnService.shared.recordingDidStart()
                            }

                            await activeModeTask.value

                            guard self.recordingState == .recording,
                                self.activeRecordingStartID == startID,
                                !self.shouldCancelRecording
                            else {
                                return
                            }

                            self.startRecordingContextCapture()

                            let modelResolution = ModeRuntimeResolver.transcriptionModelResolution(
                                transcriptionModelManager: self.transcriptionModelManager
                            )
                            guard
                                let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                                    from: modelResolution
                                )
                            else {
                                let failure = self.recordingModelFailure(for: modelResolution)
                                NotificationManager.shared.showNotification(
                                    title: failure.title,
                                    type: .error,
                                    duration: 7.0,
                                    actionButton: (failure.actionLabel, failure.action)
                                )
                                await self.recorder.stopRecording()
                                try? FileManager.default.removeItem(at: permanentURL)
                                self.recordedFile = nil
                                self.recordingState = .idle
                                self.activeRecordingStartID = nil
                                self.clearActiveRecordingContext()
                                await self.cleanupResources()
                                await self.recorderUIManager?.dismissRecorderPanel()
                                return
                            }

                            if self.serviceRegistry.shouldUseRealtimeTranscription(for: transcriptionConfiguration) {
                                let session = self.serviceRegistry.createSession(
                                    for: transcriptionConfiguration,
                                    onPartialTranscript: { [weak self] partial in
                                        Task { @MainActor in
                                            guard let self,
                                                self.activeRecordingStartID == startID,
                                                self.recordingState == .recording
                                            else {
                                                return
                                            }
                                            self.partialTranscript = partial
                                        }
                                    }
                                )
                                self.currentSession = session
                                self.currentSessionTranscriptionConfiguration = transcriptionConfiguration
                                // the server: clean up while the person talks (only when cleanup is on).
                                if let pcSession = session as? ParlePCStreamingSession,
                                    let enhancementService = self.enhancementService,
                                    let aiService = enhancementService.getAIService()
                                {
                                    let enhancement = ModeRuntimeResolver.currentEnhancementConfiguration(
                                        enhancementService: enhancementService,
                                        aiService: aiService
                                    )
                                    if enhancement.isEnabled, enhancementService.isConfigured(for: enhancement),
                                        !CommandModeController.shared.hasActiveCommand,
                                        FlowCleanupPolicy.isCleanupEnabled
                                    {
                                        pcSession.liveCleaner = { [weak enhancementService] text, preceding in
                                            guard let enhancementService else { throw CancellationError() }
                                            return try await enhancementService.enhance(
                                                text, configuration: enhancement, precedingText: preceding
                                            ).text
                                        }
                                    }
                                }
                                let realCallback = try await session.prepare(
                                    configuration: transcriptionConfiguration
                                )

                                if let realCallback {
                                    let droppedStartupChunks = realtimeAudioGate.activate(realCallback)
                                    if droppedStartupChunks > 0 {
                                        self.logger.warning(
                                            "Realtime startup audio gate dropped \(droppedStartupChunks, privacy: .public) chunks before streaming became active"
                                        )
                                    }
                                } else {
                                    _ = realtimeAudioGate.reset()
                                    self.recorder.onAudioChunk = nil
                                }
                            } else {
                                self.currentSession = nil
                                self.currentSessionTranscriptionConfiguration = nil
                                self.recorder.onAudioChunk = nil
                                _ = realtimeAudioGate.reset()
                            }


                            Task { @MainActor [weak self] in
                                guard let self else { return }

                                let currentModel = ModeRuntimeResolver.transcriptionConfiguration(
                                    transcriptionModelManager: self.transcriptionModelManager
                                )?.model

                                if let model = currentModel,
                                    model.provider == .whisper
                                {
                                    if let localWhisperModel = self.whisperModelManager.availableModels.first(where: {
                                        $0.name == model.name
                                    }),
                                        self.whisperModelManager.whisperContext == nil
                                    {
                                        do {
                                            try await self.whisperModelManager.loadModel(localWhisperModel)
                                        } catch {
                                            self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                                        }
                                    }
                                } else if let fluidAudioModel = currentModel as? FluidAudioModel {
                                    try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(
                                        for: fluidAudioModel)
                                }

                            }

                        } catch {
                            activeModeTask.cancel()
                            self.logger.error("Recording failed to start: \(error, privacy: .public)")
                            let audioFailure = self.recordingAudioFailure(for: error)
                            if audioFailure == nil {
                                await self.recorder.stopRecording()
                            }
                            self.cancelCurrentSession()
                            if let recordedFile = self.recordedFile {
                                try? FileManager.default.removeItem(at: recordedFile)
                            }
                            self.recordingState = .idle
                            self.recordedFile = nil
                            self.activeRecordingStartID = nil
                            self.clearActiveRecordingContext()
                            await self.cleanupResources()
                            if let failure = audioFailure {
                                NotificationManager.shared.showNotification(
                                    title: failure.title,
                                    type: .error,
                                    duration: 7.0,
                                    actionButton: (failure.actionLabel, failure.action)
                                )
                            } else {
                                NotificationManager.shared.showNotification(
                                    title: String(localized: "Recording failed to start"), type: .error)
                            }
                            await self.recorderUIManager?.dismissRecorderPanel()
                        }
                    }
                } else {
                    logger.error("Recording permission denied")
                }
            }
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    @MainActor
    private func recordingModelFailure(
        for resolution: ModeTranscriptionModelResolution
    ) -> (title: String, actionLabel: String, action: () -> Void) {
        switch resolution {
        case .noMode:
            return (
                String(localized: "No mode configured"),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .noSelection(let mode):
            return (
                String(
                    format: String(localized: "No transcription model is selected for the '%@' mode"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .modelNotFound(let mode):
            return (
                String(
                    format: String(localized: "The transcription model selected for the '%@' mode is unavailable"),
                    mode.name
                ),
                String(localized: "Manage Modes"),
                ModeSetupNavigator.openModesSettings
            )
        case .unavailable(let mode, let model), .available(let mode, let model):
            return (
                String(
                    format: String(localized: "'%@' is not available for the %@ mode"),
                    model.displayName,
                    mode.name
                ),
                String(localized: "Manage AI Models"),
                ModeSetupNavigator.openModelsSettings
            )
        }
    }

    /// Checks requirements that do not depend on asynchronous app and URL mode resolution.
    @MainActor
    private func passesRecordingPreflight() async -> Bool {
        if !ModeManager.shared.hasEnabledConfiguration {
            await failRecordingPreflight(
                title: String(localized: "No mode configured"),
                actionLabel: String(localized: "Manage Modes"),
                action: ModeSetupNavigator.openModesSettings
            )
            return false
        }

        return true
    }

    @MainActor
    private func failRecordingPreflight(
        title: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) async {
        logger.error("❌ Recording preflight failed: \(title, privacy: .public)")
        recordingState = .idle
        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            duration: 7.0,
            actionButton: (actionLabel, action)
        )
        await recorderUIManager?.dismissRecorderPanel()
    }

    // MARK: - Recording Context

    private func startRecordingContextCapture() {
        clearActiveRecordingContext()

        let store = RecordingContextSnapshotStore()
        activeRecordingContextStore = store
        activeRecordingContextTasks = RecordingContextCaptureService.startCapture(into: store)
    }

    private func clearActiveRecordingContext() {
        activeRecordingContextTasks.forEach { $0.cancel() }
        activeRecordingContextTasks.removeAll()
        activeRecordingContextStore = nil
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(
        on transcription: Transcription,
        audioURL: URL,
        contextStore: RecordingContextSnapshotStore?,
        sendAfterPaste: Bool,
        timing: FlowDictationTiming? = nil
    ) async {
        guard
            let transcriptionConfiguration = currentSessionTranscriptionConfiguration
                ?? ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager)
        else {
            transcription.text = String(localized: "Transcription Failed: No model selected")
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            recordingState = .idle
            activePipelineUseCase = .newSession
            timing?.transcriptionID = transcription.id
            timing?.record(status: .failed)
            timing?.resignCurrent()
            await recorderUIManager?.dismissRecorderPanel()
            flashPipelineFailure(transcriptionID: transcription.id)
            return
        }

        let session = currentSession
        let transcriptionID = transcription.id
        // Command mode: the transcript is the instruction for the captured selection.
        let commandSelection = CommandModeController.shared.takeActiveSelection()
        let commandHooks = commandSelection.map { selection in
            CommandModeController.shared.pipelineHooks(
                selection: selection,
                enhancementService: enhancementService,
                dismiss: { [weak self] in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.recorderUIManager?.dismissRecorderPanel()
                }
            )
        }
        activePipelineTranscriptionID = transcriptionID
        activePipelineTranscription = transcription

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration()
            },
            session: session,
            triggerWordModeSelection: { [weak self] text in
                self?.selectTriggerWordModeIfNeeded(for: text)
            },
            enhancementConfiguration: { [weak self] in
                guard let self,
                    let enhancementService = self.enhancementService,
                    let aiService = enhancementService.getAIService()
                else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            recordingContextSnapshot: {
                await MainActor.run {
                    contextStore?.snapshot
                }
            },
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration()
            },
            sendAfterPaste: sendAfterPaste,
            onStateChange: { [weak self] state in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                self.recordingState = state
            },
            shouldCancel: { [weak self] in
                guard let self else { return false }
                return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (self.activePipelineTranscriptionID == transcriptionID && self.shouldCancelRecording)
            },
            onCancel: { [weak self, session] in
                guard let self else { return }
                self.cancelPipelineSession(transcriptionID: transcriptionID, session: session)
            },
            onDismiss: { [weak self] in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                await self.recorderUIManager?.dismissRecorderPanel()
            },
            assistant: commandHooks ?? TranscriptionPipeline.AssistantHooks(
                isFollowUp: activePipelineUseCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.fail(message)
                }
            ),
            timing: timing
        )

        timing?.resignCurrent()
        let didFinishActivePipeline = activePipelineTranscriptionID == transcriptionID
        if didFinishActivePipeline {
            // Free model resources after going idle, off the path to the next dictation: the
            // XPC unload took 120-180 ms and kept a new fn press queued behind it.
            activeRecordingStartID = nil
            activeRecordingUseCase = .newSession
            activePipelineTranscriptionID = nil
            activePipelineTranscription = nil
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            recordedFile = nil
            shouldCancelRecording = false
            activePipelineUseCase = .newSession
            clearActiveRecordingContext()
        }
        canceledPipelineTranscriptionIDs.remove(transcriptionID)

        // Command mode never pastes the transcript, so close the session here when the
        // command did not (nothing was said, or the transcription failed).
        if didFinishActivePipeline, commandSelection != nil,
            recordingState != .recording, recordingState != .starting,
            recorderUIManager?.isRecorderPanelVisible == true
        {
            await recorderUIManager?.dismissRecorderPanel()
        }

        if didFinishActivePipeline
            && (recordingState == .transcribing || recordingState == .enhancing || recordingState == .busy)
        {
            recordingState = .idle
        }
        if didFinishActivePipeline {
            Task { @MainActor [weak self] in await self?.releaseModelResourcesIfIdle() }
        }

        if didFinishActivePipeline,
            transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue
        {
            flashPipelineFailure(transcriptionID: transcriptionID)
        }
    }

    /// Red pill for 500 ms and a "Something's not right" toast that can retry.
    private func flashPipelineFailure(transcriptionID: UUID) {
        FlowDictationState.shared.flashError()
        FlowBarController.shared.showToast(
            FlowBarToast(
                style: .mini,
                title: "Something's not right",
                icon: .circleAlert,
                actionTitle: "Retry",
                action: {
                    Task { @MainActor in
                        await FlowDictationActions.retry(transcriptionID: transcriptionID)
                    }
                },
                sound: .error
            )
        )
    }

    private func selectTriggerWordModeIfNeeded(for text: String) -> String? {
        guard let (triggeredMode, processedText) = ModeManager.shared.getConfigurationForTriggerWord(text) else {
            return nil
        }

        ModeManager.shared.setActiveConfiguration(triggeredMode)
        return processedText
    }

    // MARK: - Cancellation

    func cancelRecording(reason: FlowCancelReason = .user) async {
        if reason == .user { RecordingShortcutManager.shared?.dropQueuedPress() }
        FlowVoiceGate.shared.cancel()
        let shouldFinishSessionImmediately: Bool
        // nil when nothing was in progress, so there is nothing to report.
        var flowCancel: (transcription: Transcription?, timing: FlowDictationTiming?)?
        switch recordingState {
        case .starting, .recording:
            let timing = activeTiming
            activeTiming = nil
            requestRecordingCancellation()
            let canceled = await finishActiveRecorderCancellation(keepAudio: reason != .otherShortcut && reason != .lonelyTap)
            flowCancel = (canceled, timing)
            shouldFinishSessionImmediately = false
        case .transcribing, .enhancing:
            if activePipelineTranscriptionID == nil {
                // Still in the 250 ms tail after stop: toggleRecord saves the audio and reports it.
                pendingTailCancelReason = reason
            } else {
                // The pipeline notices and marks this row canceled; the audio stays on disk.
                flowCancel = (activePipelineTranscription, FlowDictationTiming.current)
            }
            requestRecordingCancellation()
            partialTranscript = ""
            recordingState = .idle
            shouldFinishSessionImmediately = false
        case .idle, .busy:
            partialTranscript = ""
            shouldCancelRecording = false
            recordingState = .idle
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            await finishRecorderSession()
        }

        if let flowCancel {
            handleFlowCancel(reason: reason, transcription: flowCancel.transcription, timing: flowCancel.timing)
        }
    }

    /// Sound, stats and the Undo toast for a canceled dictation.
    private func handleFlowCancel(
        reason: FlowCancelReason,
        transcription: Transcription?,
        timing: FlowDictationTiming?
    ) {
        timing?.cancelDelayNotice()
        timing?.resignCurrent()

        if reason != .otherShortcut, reason != .lonelyTap, let timing, let transcription {
            timing.transcriptionID = transcription.id
            timing.audioDuration = transcription.duration
            timing.record(status: .canceled)
        }

        switch reason {
        case .otherShortcut:
            SoundManager.shared.playEscSound()
            // Explain the accidental cancel (at most once a minute); otherwise the plain mini toast.
            let otherKeyTip = FlowTipLedger.Tip(id: "otherKeyCancel", maxShows: nil, minInterval: 60)
            if FlowTipLedger.isEligible(otherKeyTip, respectingSuggestions: false) {
                FlowTipLedger.markShown(otherKeyTip)
                let key = ShortcutStore.shortcut(for: .primaryRecording)?.displayTokens.joined(separator: " + ") ?? "fn"
                var toast = FlowBarToast(style: .standard, title: "Dictation cancelled")
                toast.body = "Another key was pressed while starting. Hold only \(key) to dictate."
                toast.isWarning = true
                toast.duration = 5
                FlowBarController.shared.showToast(toast)
            } else {
                FlowBarController.shared.showToast(FlowBarToast(style: .mini, title: "Dictation cancelled"))
            }
        case .lonelyTap:
            FlowBarController.shared.showDontTapToast()
        case .user:
            SoundManager.shared.playEscSound()
            guard let transcription,
                let audioURLString = transcription.audioFileURL,
                let audioURL = URL(string: audioURLString),
                FileManager.default.fileExists(atPath: audioURL.path)
            else { return }
            FlowCancelUndo.register(
                transcriptionID: transcription.id,
                audioURL: audioURL,
                targetPID: timing?.appProcessID,
                bundleID: timing?.appBundleID,
                timing: timing
            )
            FlowBarController.shared.showCancelToast {
                _ = await FlowDictationActions.undoLastCancel()
            }
        case .system:
            break
        }
    }

    /// Undo: runs a canceled dictation's saved audio through the same pipeline and delivery
    /// a normal dictation uses, updating the same history row.
    func reprocessCanceled(
        transcription: Transcription,
        audioURL: URL,
        original: FlowDictationTiming? = nil
    ) async {
        guard recordingState == .idle else { return }
        let transcriptionID = transcription.id

        // A cancel during processing leaves that pipeline winding down; let it finish so it
        // can't mark the row canceled again after this run.
        var waited: TimeInterval = 0
        while canceledPipelineTranscriptionIDs.contains(transcriptionID)
            || activePipelineTranscriptionID == transcriptionID
        {
            guard waited < 15, recordingState == .idle else { return }
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        guard recordingState == .idle else { return }

        transcription.transcriptionStatus = TranscriptionStatus.pending.rawValue
        transcription.text = ""
        transcription.enhancedText = nil
        try? modelContext.save()

        let timing = FlowDictationTiming(reprocessing: original)
        timing.makeCurrent()
        timing.markStopped()

        cancelCurrentSession()
        shouldCancelRecording = false
        partialTranscript = ""
        activePipelineUseCase = .newSession
        clearActiveRecordingContext()
        recordingState = .transcribing
        if let recorderUIManager = recorderUIManager as? RecorderUIManager,
            !recorderUIManager.isRecorderPanelVisible
        {
            recorderUIManager.isRecorderPanelVisible = true
        }

        await runPipeline(
            on: transcription,
            audioURL: audioURL,
            contextStore: nil,
            sendAfterPaste: false,
            timing: timing
        )
    }

    /// Stops and processes the current recording exactly like a finish.
    func finishActiveRecording() async {
        guard recordingState == .recording else { return }
        if let recorderUIManager = recorderUIManager as? RecorderUIManager {
            await recorderUIManager.toggleRecorderPanel()
        } else {
            await toggleRecord()
        }
    }

    // MARK: - Dictation length limit

    private func startDurationLimit(for startID: UUID) {
        durationLimitTask?.cancel()
        durationLimitTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.dictationLimitWarning))
            } catch {
                return
            }
            guard let self, self.recordingState == .recording, self.activeRecordingStartID == startID else { return }
            FlowBarController.shared.showToast(
                FlowBarToast(
                    style: .mini,
                    title: "Less than 1 minute left before the 20 minute limit",
                    duration: 6
                )
            )

            do {
                try await Task.sleep(for: .seconds(Self.dictationLimit - Self.dictationLimitWarning))
            } catch {
                return
            }
            guard self.recordingState == .recording, self.activeRecordingStartID == startID else { return }
            // Detach from this task: stopping cancels it, and the pipeline must not inherit that.
            self.durationLimitTask = nil
            Task { @MainActor [weak self] in
                await self?.finishActiveRecording()
            }
            FlowBarController.shared.showToast(
                FlowBarToast(
                    style: .standard,
                    title: "Dictation ended",
                    body: "Free Flow supports up to 20 minutes per dictation.",
                    duration: 6
                )
            )
        }
    }

    func resetRecordingSession() async {
        activeTiming?.resignCurrent()
        activeTiming = nil
        pendingTailCancelReason = nil
        cancelCurrentSession()
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        canceledPipelineTranscriptionIDs.removeAll()
        shouldCancelRecording = false
        partialTranscript = ""
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        activePipelineUseCase = .newSession
        clearActiveRecordingContext()
        await recorder.stopRecording()
        recordedFile = nil
        recordingState = .idle
        await cleanupResources()
    }

    private func requestRecordingCancellation() {
        shouldCancelRecording = true

        if (recordingState == .transcribing || recordingState == .enhancing),
            let activePipelineTranscriptionID
        {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }

        cancelCurrentSession()
    }

    /// - Parameter keepAudio: false for an accidental start: nothing is kept or listed.
    @discardableResult
    private func finishActiveRecorderCancellation(keepAudio: Bool = true) async -> Transcription? {
        activeRecordingStartID = nil
        clearActiveRecordingContext()
        await recorder.stopRecording()
        var canceled: Transcription?
        if keepAudio {
            canceled = await saveCanceledRecording()
        } else if let recordedFile {
            try? FileManager.default.removeItem(at: recordedFile)
        }
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        await cleanupResources()
        return canceled
    }

    @discardableResult
    private func saveCanceledRecording() async -> Transcription? {
        guard let recordedFile,
            FileManager.default.fileExists(atPath: recordedFile.path)
        else { return nil }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
        return transcription
    }

    // MARK: - Quit and Relaunch Recovery

    /// Called while the app quits: finalizes an in-progress recording and makes sure it has a
    /// pending history row, so the next launch can offer a retry. The caller bounds the wait.
    func preserveInFlightDictationForQuit() async {
        switch recordingState {
        case .recording:
            activeRecordingStartID = nil
            await recorder.stopRecording()
            guard let file = recordedFile, FileManager.default.fileExists(atPath: file.path) else { return }
            recordedFile = nil
            let transcription = makeRecordingTranscription(
                for: file,
                text: "",
                duration: 0,
                transcriptionStatus: .pending
            )
            modelContext.insert(transcription)
            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save recording on quit: \(error, privacy: .public)")
            }
        case .transcribing, .enhancing, .busy:
            // toggleRecord inserts the pending row right after its short stop tail.
            if activePipelineTranscriptionID == nil {
                try? await Task.sleep(for: .milliseconds(300))
            }
            try? modelContext.save()
        default:
            break
        }
    }

    /// Marks rows a previous run left pending (quit or crash mid-dictation) as failed so History
    /// can retry them. Returns the most recent recovered row that still has its audio.
    @discardableResult
    func recoverInterruptedDictations() -> Transcription? {
        let cutoff = launchDate
        let descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate<Transcription> { $0.transcriptionStatus == "pending" && $0.timestamp < cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        guard let stuck = try? modelContext.fetch(descriptor), !stuck.isEmpty else { return nil }

        var latestWithAudio: Transcription?
        for transcription in stuck {
            guard transcription.id != activePipelineTranscriptionID,
                let string = transcription.audioFileURL, let url = URL(string: string),
                FileManager.default.fileExists(atPath: url.path)
            else { continue }
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            if transcription.text.isEmpty {
                transcription.text = String(localized: "Transcription Failed: Free Flow closed before it finished")
            }
            if latestWithAudio == nil { latestWithAudio = transcription }
        }
        guard latestWithAudio != nil else { return nil }
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save recovered dictations: \(error, privacy: .public)")
        }
        return latestWithAudio
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = ModeManager.shared.currentEffectiveConfiguration,
            mode.isEnabled
        else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    // MARK: - Resource Cleanup

    private func cancelPipelineSession(transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()

        guard activePipelineTranscriptionID == transcriptionID else {
            logger.notice("Skipping stale pipeline cleanup")
            return
        }

        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func cancelCurrentSession() {
        currentSession?.cancel()
        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func finishRecorderSession() async {
        enhancementService?.clearCapturedContexts()
    }

    /// Background version of `cleanupResources` for after a dictation: stops as soon as a new
    /// one has started, so it never clears that session's context or start ID.
    private func releaseModelResourcesIfIdle() async {
        guard recordingState == .idle else { return }
        await finishRecorderSession()
        guard recordingState == .idle else { return }
        await whisperModelManager.cleanupResources()
        guard recordingState == .idle else { return }
        await serviceRegistry.cleanup()
    }

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        await finishRecorderSession()
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
        microphoneDisconnectObserver = NotificationCenter.default.addObserver(
            forName: .flowMicrophoneDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.recordingState == .recording else { return }
                FlowBarController.shared.showToast(
                    FlowBarToast(style: .mini, title: "Microphone disconnected", icon: .mic)
                )
                // Process what was captured before the microphone went away.
                await self.finishActiveRecording()
            }
        }
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt =
                UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
