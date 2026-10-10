import AppKit
import Foundation
import SwiftData
import os

/// Dictation actions for the Flow Bar, menus and global shortcuts.
@MainActor
enum FlowDictationActions {
    private static weak var engine: FreeFlowEngine?
    private static weak var configuredRecorderUIManager: RecorderUIManager?
    private static let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowDictationActions")

    static func configure(engine: FreeFlowEngine, recorderUIManager: RecorderUIManager) {
        self.engine = engine
        configuredRecorderUIManager = recorderUIManager
    }

    static func configure(engine: FreeFlowEngine) {
        self.engine = engine
    }

    private static var recorderUIManager: RecorderUIManager? {
        configuredRecorderUIManager ?? (engine?.recorderUIManager as? RecorderUIManager)
    }

    // MARK: - Recording

    /// Starts recording already locked hands-free (pill click).
    static func startHandsFree() async {
        guard FlowDictationState.shared.phase == .idle, engine?.recordingState == .idle else { return }
        if let shortcutManager = RecordingShortcutManager.shared {
            await shortcutManager.beginHandsFreeFromUI()
        } else if let recorderUIManager, !recorderUIManager.isRecorderPanelVisible {
            FlowDictationState.shared.setHandsFree(true)
            await recorderUIManager.toggleRecorderPanel()
        }
    }

    /// Stops and pastes (pill check, or a click on the pill during push-to-talk).
    static func finish() async {
        guard FlowDictationState.shared.phase == .listening,
            let engine, engine.recordingState == .recording
        else { return }
        if let recorderUIManager {
            await recorderUIManager.toggleRecorderPanel()
        } else {
            await engine.toggleRecord()
        }
    }

    /// The person canceled: the audio is kept and the cancel toast offers Undo.
    static func cancel() async {
        let phase = FlowDictationState.shared.phase
        // Ignore pill clicks while the recorder is still starting.
        guard phase == .listening || phase == .processing, let engine else { return }
        await engine.cancelRecording(reason: .user)
        await recorderUIManager?.dismissRecorderPanel()
    }

    /// Re-runs the last canceled dictation (within the Undo window) and pastes it.
    @discardableResult
    static func undoLastCancel() async -> Bool {
        guard let pending = FlowCancelUndo.take() else { return false }
        guard let engine, engine.recordingState == .idle else { return false }

        guard FileManager.default.fileExists(atPath: pending.audioURL.path),
            let transcription = fetchTranscription(id: pending.transcriptionID, in: engine.modelContext)
        else {
            FlowBarController.shared.showToast(
                FlowBarToast(style: .mini, title: "Couldn't recover that dictation", icon: .circleAlert)
            )
            return false
        }

        await FlowCancelUndo.reactivateTarget(pending)
        await engine.reprocessCanceled(transcription: transcription, audioURL: pending.audioURL, original: pending.timing)
        return true
    }

    // MARK: - History

    /// Re-transcribes a stored recording, updates that row, and copies the result.
    static func retry(transcriptionID: UUID) async {
        guard let engine else { return }
        guard let transcription = fetchTranscription(id: transcriptionID, in: engine.modelContext) else {
            notify("Couldn't find that transcript")
            return
        }
        do {
            let text = try await retranscribe(transcription, engine: engine)
            if ClipboardManager.copyToClipboard(text) {
                notify("Transcript copied", style: .success)
            } else {
                notify("Couldn't copy the transcript", style: .error)
            }
        } catch {
            logger.error("Retry failed: \(error, privacy: .public)")
            notify("Couldn't transcribe that recording", style: .error)
        }
    }

    /// Pastes the last transcript. A canceled or failed one is transcribed again first.
    static func pasteLast() async {
        guard let engine else { return }
        if engine.recordingState == .transcribing || engine.recordingState == .enhancing {
            await engine.cancelRecording(reason: .system)
            await recorderUIManager?.dismissRecorderPanel()
        }

        guard let last = LastTranscriptionService.getLastTranscription(from: engine.modelContext) else {
            FlowBarController.shared.showToast(FlowBarToast(style: .mini, title: "No transcript yet"))
            return
        }

        let status = last.transcriptionStatus
        let needsTranscription =
            status == TranscriptionStatus.canceled.rawValue || status == TranscriptionStatus.failed.rawValue
        guard needsTranscription, audioURL(of: last) != nil else {
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
            return
        }

        do {
            let text = try await retranscribe(last, engine: engine)
            try? await Task.sleep(for: .milliseconds(150))
            CursorPaster.pasteAtCursor(text)
        } catch {
            logger.error("Paste last failed: \(error, privacy: .public)")
            FlowBarController.shared.showToast(
                FlowBarToast(style: .mini, title: "Couldn't transcribe the last recording", icon: .circleAlert)
            )
        }
    }

    /// Copies the last transcript as plain text.
    static func copyLast() {
        guard let engine,
            let last = LastTranscriptionService.getLastTranscription(from: engine.modelContext)
        else {
            FlowBarController.shared.showToast(FlowBarToast(style: .mini, title: "No transcript yet"))
            return
        }
        guard ClipboardManager.copyToClipboard(deliveredText(of: last)) else {
            FlowBarController.shared.showToast(
                FlowBarToast(style: .mini, title: "Couldn't copy the transcript", icon: .circleAlert)
            )
            return
        }
        FlowBarController.shared.showToast(FlowBarToast(style: .mini, title: "Copied last transcript", icon: .copy))
    }

    // MARK: - Helpers

    private enum RetryError: LocalizedError {
        case noAudio
        case noModel

        var errorDescription: String? {
            switch self {
            case .noAudio: return "The recording is no longer on disk."
            case .noModel: return "No transcription model is selected."
            }
        }
    }

    /// Runs the stored audio through transcription and cleanup again and writes the result
    /// into the same row. Returns the text to deliver.
    private static func retranscribe(_ transcription: Transcription, engine: FreeFlowEngine) async throws -> String {
        guard let audioURL = audioURL(of: transcription) else { throw RetryError.noAudio }
        guard
            let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: engine.transcriptionModelManager
            )
        else { throw RetryError.noModel }

        let service = AudioTranscriptionService(
            modelContext: engine.modelContext,
            serviceRegistry: engine.serviceRegistry,
            enhancementService: engine.enhancementService
        )
        let result = try await service.retranscribeAudio(from: audioURL, using: configuration.model)
        let fresh = result.transcription

        // Update the original row instead of keeping the temporary copy.
        transcription.text = fresh.text
        transcription.enhancedText = fresh.enhancedText
        transcription.duration = fresh.duration
        transcription.transcriptionModelName = fresh.transcriptionModelName
        transcription.aiEnhancementModelName = fresh.aiEnhancementModelName
        transcription.promptName = fresh.promptName
        transcription.transcriptionDuration = fresh.transcriptionDuration
        transcription.enhancementDuration = fresh.enhancementDuration
        transcription.aiRequestSystemMessage = fresh.aiRequestSystemMessage
        transcription.aiRequestUserMessage = fresh.aiRequestUserMessage
        transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue

        let removedTemporaryRow = fresh.id != transcription.id
        if removedTemporaryRow {
            if let copiedAudio = Self.audioURL(of: fresh), copiedAudio != audioURL {
                try? FileManager.default.removeItem(at: copiedAudio)
            }
            engine.modelContext.delete(fresh)
        }
        do {
            try engine.modelContext.save()
        } catch {
            logger.error("Failed to save retried transcription: \(error, privacy: .public)")
        }
        if removedTemporaryRow {
            NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
        }
        NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

        if result.enhancementFailure == nil, let enhanced = transcription.enhancedText, !enhanced.isEmpty {
            return enhanced
        }
        return transcription.text
    }

    private static func fetchTranscription(id: UUID, in context: ModelContext) -> Transcription? {
        var descriptor = FetchDescriptor<Transcription>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func audioURL(of transcription: Transcription) -> URL? {
        guard let string = transcription.audioFileURL, let url = URL(string: string),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// What was delivered: the cleaned text when cleanup succeeded, otherwise the transcript.
    private static func deliveredText(of transcription: Transcription) -> String {
        if let enhanced = transcription.enhancedText, !enhanced.isEmpty,
            !enhanced.hasPrefix(EnhancementFailureFormatter.message(description: "").trimmingCharacters(in: .whitespaces))
        {
            return enhanced
        }
        return transcription.text
    }

    /// In-window toast while the main window is up, otherwise a Flow Bar toast.
    private static func notify(_ message: String, style: FlowToastStyle = .info) {
        let mainWindowVisible =
            NSApp.isActive && NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
        if mainWindowVisible {
            FlowToastCenter.shared.show(message, style: style)
        } else {
            FlowBarController.shared.showToast(
                FlowBarToast(
                    style: .mini,
                    title: message,
                    icon: style == .error ? .circleAlert : (style == .success ? .circleCheck : nil)
                )
            )
        }
    }
}
