import Foundation
import SwiftData
import os

/// Handles the full post-recording pipeline:
/// transcribe → filter → format → word-replace → AI enhance → deliver → save
@MainActor
class TranscriptionPipeline {
    struct AssistantHooks {
        let isFollowUp: Bool
        let sendFollowUp: (String, Transcription) async -> Void
        let startResponse: (String, EnhancementRuntimeConfiguration) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void

        static let inactive = AssistantHooks(
            isFollowUp: false,
            sendFollowUp: { _, _ in },
            startResponse: { _, _ in },
            showResponse: { _, _ in },
            failResponse: { _ in }
        )
    }

    private let modelContext: ModelContext
    private let serviceRegistry: TranscriptionServiceRegistry
    private let enhancementService: AIEnhancementService?
    private let delivery = TranscriptionDelivery()
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "TranscriptionPipeline")

    init(
        modelContext: ModelContext,
        serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.serviceRegistry = serviceRegistry
        self.enhancementService = enhancementService
    }

    /// Run the full pipeline for a given transcription record.
    /// - Parameters:
    ///   - transcription: The pending Transcription SwiftData object to populate and save.
    ///   - audioURL: The recorded audio file.
    ///   - transcriptionConfiguration: Mode-resolved transcription engine settings for this phase.
    ///   - session: An active streaming session if one was prepared, otherwise nil.
    ///   - onStateChange: Called when the pipeline moves to a new recording state (e.g. `.enhancing`).
    ///   - shouldCancel: Returns true if the user requested cancellation.
    ///   - onCancel: Called when cancellation is detected to cancel active session state.
    ///   - onDismiss: Called when delivery should close the recorder panel.
    func run(
        transcription: Transcription,
        audioURL: URL,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        formattingConfiguration resolveFormattingConfiguration: @escaping () -> TranscriptionFormattingConfiguration,
        session: TranscriptionSession?,
        triggerWordModeSelection: @escaping (String) -> String? = { _ in nil },
        enhancementConfiguration: @escaping () -> EnhancementRuntimeConfiguration?,
        recordingContextSnapshot: @escaping () async -> RecordingContextSnapshot? = { nil },
        outputConfiguration: @escaping () -> OutputRuntimeConfiguration,
        sendAfterPaste: Bool = false,
        onStateChange: @escaping (RecordingState) -> Void,
        shouldCancel: () -> Bool,
        onCancel: @escaping () async -> Void,
        onDismiss: @escaping () async -> Void,
        assistant: AssistantHooks = .inactive,
        timing: FlowDictationTiming? = nil
    ) async {
        let model = transcriptionConfiguration.model
        var finalText: String?
        var asrText = ""
        var sendEnter = false
        var askSiri = false
        var cleanupAccepted = false
        timing?.transcriptionID = transcription.id
        timing?.transcriptionSource =
            ParleEngine.shared.isUsingPC && ParlePC.isPCModel(model) ? "pc" : "mac"
        var responseError: String?
        var outputForDelivery: OutputRuntimeConfiguration?
        var responseConfig: EnhancementRuntimeConfiguration?

        func finishCanceledTranscription() async {
            await onCancel()

            let canceledDuration: TimeInterval?
            if transcription.duration > 0 {
                canceledDuration = nil
            } else {
                let duration = await AudioFileMetadata.duration(for: audioURL)
                canceledDuration = duration > 0 ? duration : nil
            }

            transcription.markAsCanceledTranscription(
                duration: canceledDuration,
                modelName: transcription.transcriptionModelName ?? model.displayName
            )
            timing?.cancelDelayNotice()

            do {
                try modelContext.save()
            } catch {
                logger.error("Failed to save canceled transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        do {
            let transcriptionStart = Date()
            var text: String
            if let session {
                text = try await session.transcribe(audioURL: audioURL)
            } else {
                text = try await serviceRegistry.transcribe(
                    audioURL: audioURL,
                    model: model,
                    context: transcriptionConfiguration.requestContext
                )
            }
            text = TranscriptionOutputFilter.filter(text)

            // Voice switches: the speaker was scored live while recording, so this is instant.
            // Ctrl+fn: rewrite as a prompt for an AI assistant instead of cleaning as prose.
            let promptMode = !assistant.isFollowUp && FlowPromptMode.consume()
            var notMyVoice = false
            var usedFilteredAudio = false
            if !assistant.isFollowUp, let verdict = await FlowVoiceGate.shared.finish() {
                if verdict.notMine, FlowVoiceSettings.onlyMine {
                    notMyVoice = true
                } else if let filteredURL = verdict.filteredAudioURL {
                    // Someone else spoke too: transcribe only the owner's stretches.
                    if let filtered = try? await serviceRegistry.transcribe(
                        audioURL: filteredURL,
                        model: model,
                        context: transcriptionConfiguration.requestContext
                    ) {
                        text = TranscriptionOutputFilter.filter(filtered)
                        usedFilteredAudio = true
                    }
                    try? FileManager.default.removeItem(at: filteredURL)
                }
            }
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            if shouldCancel() {
                await finishCanceledTranscription()
                return
            }

            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !assistant.isFollowUp,
                let processedText = triggerWordModeSelection(text)
            {
                text = processedText
            }

            let formattingConfiguration = resolveFormattingConfiguration()
            let resolvedEnhancementConfiguration = enhancementConfiguration()
            let resolvedOutputConfiguration = outputConfiguration()
            let modeMetadata = metadata(
                for: formattingConfiguration.mode ?? resolvedEnhancementConfiguration?.mode
                    ?? resolvedOutputConfiguration.mode ?? transcriptionConfiguration.mode
            )

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            // What Whisper heard, before the dictionary and cleanup touch it (for stats).
            asrText = text
            timing?.asrText = text

            let firstReplacement = WordReplacementService.shared.applyReplacementsCounted(to: text, using: modelContext)
            text = firstReplacement.text
            timing?.dictionaryReplacementCount += firstReplacement.count
            let cleanedText = text

            let actualDuration = await AudioFileMetadata.duration(for: audioURL)

            transcription.text = cleanedText
            transcription.duration = actualDuration
            transcription.transcriptionModelName = model.displayName
            transcription.transcriptionDuration = transcriptionDuration
            transcription.modeName = modeMetadata.name
            transcription.modeEmoji = modeMetadata.emoji
            timing?.audioDuration = actualDuration
            finalText = cleanedText

            if !assistant.isFollowUp {
                let shouldRespondInRecorder =
                    resolvedOutputConfiguration.outputMode == .respond
                    && resolvedEnhancementConfiguration?.isEnabled == true
                    && resolvedEnhancementConfiguration.map { configuration in
                        enhancementService?.isConfigured(for: configuration) == true
                    } == true
                outputForDelivery = resolvedOutputConfiguration
                responseConfig = shouldRespondInRecorder ? resolvedEnhancementConfiguration : nil

                let isSkipShortEnhancementEnabled = UserDefaults.standard.bool(forKey: "SkipShortEnhancement")
                let savedThreshold = UserDefaults.standard.integer(forKey: "ShortEnhancementWordThreshold")
                let shortEnhancementWordThreshold = savedThreshold > 0 ? savedThreshold : 3
                let shouldSkipShortEnhancement =
                    !shouldRespondInRecorder && isSkipShortEnhancementEnabled
                    && WordCounter.count(in: text) <= shortEnhancementWordThreshold
                    && !promptMode
                    && !Self.containsSpokenCommand(text)
                // Auto cleanup level "None" turns dictation cleanup off (Respond still answers).
                let shouldSkipEnhancement =
                    shouldSkipShortEnhancement || (!shouldRespondInRecorder && !FlowCleanupPolicy.isCleanupEnabled)

                if let enhancementService,
                    let resolvedEnhancementConfiguration,
                    resolvedEnhancementConfiguration.isEnabled,
                    enhancementService.isConfigured(for: resolvedEnhancementConfiguration),
                    !shouldSkipEnhancement
                {
                    if shouldCancel() {
                        await finishCanceledTranscription()
                        return
                    }

                    onStateChange(.enhancing)
                    let textForAI = text
                    if shouldRespondInRecorder {
                        await assistant.startResponse(textForAI, resolvedEnhancementConfiguration)
                    }

                    do {
                        let capturedSnapshot = await recordingContextSnapshot()
                        timing?.hadSelection = capturedSnapshot?.selectedText != nil
                        // Context awareness off: the cleanup model sees only the words.
                        let contextSnapshot =
                            UserDefaults.standard.bool(forKey: FlowKeys.contextAwareness) ? capturedSnapshot : nil
                        transcription.aiEnhancementModelName =
                            resolvedEnhancementConfiguration.modelName
                            ?? resolvedEnhancementConfiguration.provider?.defaultModel
                        transcription.promptName = resolvedEnhancementConfiguration.prompt?.title
                        let enhancementResult: AIEnhancementResult
                        if promptMode, let aiService = enhancementService.getAIService(),
                            let provider = resolvedEnhancementConfiguration.provider
                        {
                            let started = Date()
                            let vocabulary = CustomVocabularyService.shared.getCustomVocabulary(from: modelContext)
                                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            let rewritten = try await FlowPromptMode.rewrite(
                                textForAI,
                                vocabulary: vocabulary,
                                aiService: aiService,
                                provider: provider,
                                modelName: resolvedEnhancementConfiguration.modelName
                            )
                            transcription.promptName = "Prompt mode"
                            enhancementResult = AIEnhancementResult(
                                text: rewritten.text,
                                duration: Date().timeIntervalSince(started),
                                promptName: "Prompt mode",
                                systemMessage: rewritten.systemPrompt,
                                userMessage: rewritten.userMessage
                            )
                        } else if !usedFilteredAudio, !promptMode,
                            var live = await (session as? ParlePCStreamingSession)?.liveCleanupResult()
                        {
                            // "Scratch that" right after the cleaned part takes back its last sentence.
                            if let crossed = FlowBacktrack.applyAcrossBoundary(
                                cleanedStart: live.cleanedPrefix, rawRest: live.rawRemainder
                            ), !crossed.rest.isEmpty {
                                live = (crossed.start, crossed.rest)
                            }
                            // Most of it was cleaned while the person talked; clean only the rest.
                            let tailResult = try await enhancementService.enhance(
                                live.rawRemainder,
                                configuration: resolvedEnhancementConfiguration,
                                contextSnapshot: contextSnapshot,
                                precedingText: String(live.cleanedPrefix.suffix(500))
                            )
                            enhancementResult = AIEnhancementResult(
                                text: [live.cleanedPrefix, tailResult.text].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                duration: tailResult.duration,
                                promptName: tailResult.promptName,
                                systemMessage: tailResult.systemMessage,
                                userMessage: tailResult.userMessage
                            )
                        } else {
                            enhancementResult = try await enhancementService.enhance(
                                textForAI,
                                configuration: resolvedEnhancementConfiguration,
                                contextSnapshot: contextSnapshot
                            )
                        }
                        transcription.promptName =
                            enhancementResult.promptName ?? resolvedEnhancementConfiguration.prompt?.title
                        transcription.enhancementDuration = enhancementResult.duration
                        transcription.aiRequestSystemMessage = enhancementResult.systemMessage
                        transcription.aiRequestUserMessage = enhancementResult.userMessage
                        // Measure against what's left once "scratch that" is applied, or a long
                        // retraction would look like the model dropping words.
                        // A prompt is restructured on purpose, so the length guard doesn't apply.
                        if (promptMode && !enhancementResult.text.isEmpty) || ParleCleanupGuard.accepts(
                            input: FlowBacktrack.apply(to: textForAI),
                            output: enhancementResult.text
                        ) {
                            // Dictionary replacements run again after the model (Flow's order), so
                            // "btw" written by the model still becomes "by the way".
                            let secondReplacement = WordReplacementService.shared.applyReplacementsCounted(
                                to: enhancementResult.text,
                                using: modelContext
                            )
                            timing?.dictionaryReplacementCount += secondReplacement.count
                            transcription.enhancedText = secondReplacement.text
                            finalText = secondReplacement.text
                            cleanupAccepted = true
                        } else {
                            // The model answered or rewrote instead of cleaning: paste what was said.
                            Logger(subsystem: "com.jaydenghiyam.parle", category: "CleanupGuard")
                                .notice("Rejected cleanup output; pasting the raw transcript")
                            let rejectedTranscriptionID = transcription.id
                            FlowBarController.shared.showToast(
                                FlowBarToast(
                                    style: .mini,
                                    title: "Formatting may be missing",
                                    actionTitle: "Retry",
                                    action: {
                                        Task { await FlowDictationActions.retry(transcriptionID: rejectedTranscriptionID) }
                                    },
                                    duration: 6
                                )
                            )
                        }
                    } catch {
                        let errorDescription = EnhancementFailureFormatter.description(for: error)
                        let failureMessage = EnhancementFailureFormatter.message(description: errorDescription)
                        transcription.enhancedText = failureMessage
                        responseError = errorDescription
                        // Flow's mini toast: the raw text still pastes, tap to run cleanup again.
                        let failedTranscriptionID = transcription.id
                        await MainActor.run {
                            FlowBarController.shared.showToast(
                                FlowBarToast(
                                    style: .mini,
                                    title: "Formatting may be missing",
                                    actionTitle: "Retry",
                                    action: {
                                        Task { await FlowDictationActions.retry(transcriptionID: failedTranscriptionID) }
                                    },
                                    duration: 6
                                )
                            )
                        }
                        if shouldCancel() {
                            await finishCanceledTranscription()
                            return
                        }
                    }
                }
            }

            // Backtrack: an explicit "scratch that" / "never mind" never reaches the paste,
            // whether or not cleanup ran or caught it.
            if !assistant.isFollowUp, let text = finalText, FlowBacktrack.containsCommand(text) {
                let backtracked = FlowBacktrack.apply(to: text)
                if backtracked != text {
                    if cleanupAccepted {
                        transcription.enhancedText = backtracked
                    } else {
                        transcription.text = backtracked
                    }
                    finalText = backtracked
                }
            }
            // "Only my voice" is on and this didn't sound like the owner: keep it in history,
            // don't paste, and offer to paste anyway.
            if notMyVoice, let heldText = finalText, !heldText.isEmpty {
                finalText = nil
                FlowBarController.shared.showToast(
                    FlowBarToast(
                        style: .standard,
                        title: "Not your voice",
                        body: "This didn't sound like you, so nothing was pasted.",
                        isWarning: true,
                        actionTitle: "Paste anyway",
                        action: { CursorPaster.pasteAtCursor(heldText) },
                        duration: 6
                    )
                )
            }
            // Sound came in but no words came out: say so (Flow's "We couldn't hear you").
            // Runs before the "scratch that" check so junk like "[Music]" never pastes or
            // shows the scratch toast. Skipped when the dead-mic warning already covered it.
            if !assistant.isFollowUp,
                Self.isNoSpeech(asrText),
                actualDuration >= 0.6,
                !shouldCancel()
            {
                finalText = nil
                let dictation = FlowDictationState.shared
                if dictation.micActive, !dictation.micSilenceWarned {
                    FlowBarController.shared.showToast(
                        FlowBarToast(
                            style: .standard,
                            title: "We couldn't hear you",
                            body: "No speech came through from \(Self.currentMicrophoneName()).",
                            isWarning: true,
                            actionTitle: "Microphone",
                            action: {
                                FlowNavigator.shared.presentSettings(.general, dialog: .microphone)
                            },
                            duration: 6
                        )
                    )
                }
            }
            if !assistant.isFollowUp, let text = finalText,
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !asrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                // Everything said was taken back.
                finalText = nil
                await MainActor.run {
                    FlowBarController.shared.showToast(FlowBarToast(style: .mini, title: "Scratched. Nothing to paste."))
                }
            }

            // "Ask Siri, ..." (opt-in): the rest goes to Spotlight instead of the current app.
            if !assistant.isFollowUp, FlowAskSiriCommand.isEnabled,
                outputForDelivery?.outputMode == .paste,
                let deliveredText = finalText,
                // Cleaned text first; the raw words if cleanup rephrased the opening.
                let question = FlowAskSiriCommand.question(in: deliveredText) ?? FlowAskSiriCommand.question(in: asrText)
            {
                finalText = question
                askSiri = true
            }

            if !assistant.isFollowUp, !askSiri,
                outputForDelivery?.outputMode == .paste,
                let deliveredText = finalText,
                let pressEnter = FlowPressEnterCommand.evaluate(finalText: deliveredText, asrText: asrText)
            {
                finalText = pressEnter.text
                sendEnter = pressEnter.sendEnter
                if cleanupAccepted {
                    transcription.enhancedText = pressEnter.text
                } else {
                    transcription.text = pressEnter.text
                }
            }

            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue
        } catch {
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

            if let nativeAppleError = error as? NativeAppleTranscriptionService.ServiceError,
                nativeAppleError.shouldShowNotification
            {
                await MainActor.run {
                    NotificationManager.shared.showNotification(
                        title: errorDescription,
                        type: .error,
                        duration: 5.0
                    )
                }
            }

            transcription.text = String(format: String(localized: "Transcription Failed: %@"), errorDescription)
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
        }

        func saveTranscriptionAndPostCompletion() {
            var didInsertSessionMetric = false

            if transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue {
                do {
                    didInsertSessionMetric = try SessionMetricRecorder.recordRecorderSession(
                        transcription: transcription,
                        model: model,
                        in: modelContext
                    )
                } catch {
                    logger.error("Failed to record session metric: \(error, privacy: .public)")
                }
            }

            do {
                try modelContext.save()
                if didInsertSessionMetric {
                    NotificationCenter.default.post(name: .sessionMetricsDidChange, object: nil)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("Failed to save transcription: \(error, privacy: .public)")
            }
        }

        if shouldCancel() {
            await finishCanceledTranscription()
            return
        }

        timing?.finalText = finalText ?? ""
        timing?.markTextReady()

        await delivery.deliver(
            TranscriptionDelivery.Request(
                transcription: transcription,
                text: finalText,
                output: outputForDelivery ?? outputConfiguration(),
                responseConfig: responseConfig,
                responseError: responseError,
                isAssistantFollowUp: assistant.isFollowUp,
                sendAfterPaste: sendAfterPaste,
                sendEnter: sendEnter,
                askSiri: askSiri,
                appliesStyleRules: cleanupAccepted,
                timing: timing
            ),
            actions: TranscriptionDelivery.Actions(
                setState: onStateChange,
                dismiss: onDismiss,
                sendFollowUp: assistant.sendFollowUp,
                showResponse: assistant.showResponse,
                failResponse: assistant.failResponse
            )
        )

        // Small "it worked" confirmation the first few times a smart feature kicks in.
        // Checked after the paste starts so it never delays the words.
        if !assistant.isFollowUp,
            transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue,
            (outputForDelivery ?? outputConfiguration()).outputMode == .paste,
            let deliveredText = finalText,
            let confirmation = Self.smartFormattingConfirmation(
                asrText: asrText,
                finalText: deliveredText,
                cleanupAccepted: cleanupAccepted,
                bundleID: timing?.appBundleID,
                appName: timing?.appName,
                url: timing?.url
            ),
            FlowTipLedger.isEligible(confirmation.tip)
        {
            Task { @MainActor in
                // Let any toast or card from this dictation (failure, no text box) land first.
                try? await Task.sleep(nanoseconds: 600_000_000)
                let bar = FlowBarController.shared
                guard bar.presentation == nil, FlowTipLedger.isEligible(confirmation.tip) else { return }
                FlowTipLedger.markShown(confirmation.tip)
                bar.showToast(
                    FlowBarToast(style: .mini, title: confirmation.title, icon: confirmation.icon, duration: 3)
                )
            }
        }

        saveTranscriptionAndPostCompletion()

        if let timing {
            if transcription.transcriptionStatus == TranscriptionStatus.failed.rawValue {
                timing.record(status: .failed)
            } else if !timing.recordsAfterPaste {
                // Follow-ups, Respond, custom commands and empty results: nothing was pasted.
                timing.recordDelivered()
            }
        }
    }

    private func metadata(for mode: ModeConfig?) -> (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    /// Short dictations still get cleanup when they use a spoken command it handles.
    static func containsSpokenCommand(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["scratch that", "quote", "new paragraph", "new line", "wait no", "i mean", "actually"]
            .contains { lowered.contains($0) }
    }

    /// No words in the transcript: empty, punctuation only, or only bracketed
    /// tokens like "[BLANK_AUDIO]" or "(music)".
    static func isNoSpeech(_ text: String) -> Bool {
        let stripped = text
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    /// Which smart-formatting confirmation (if any) this dictation earned. At most one,
    /// in priority order: Backtrack, Listed, Email.
    static func smartFormattingConfirmation(
        asrText: String,
        finalText: String,
        cleanupAccepted: Bool,
        bundleID: String?,
        appName: String?,
        url: String?
    ) -> (tip: FlowTipLedger.Tip, title: String, icon: FlowIconName)? {
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Backtrack: a stand-alone "scratch that" / "never mind" was said and is gone now.
        if FlowBacktrack.containsCommand(asrText), !FlowBacktrack.containsCommand(finalText) {
            return (.confirmBacktrack, "Backtrack caught!", .undo2)
        }

        // The rest is the cleanup model's formatting.
        guard cleanupAccepted else { return nil }

        func listLineCount(_ text: String) -> Int {
            text.components(separatedBy: .newlines).filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("- ")
                    || trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            }.count
        }
        if listLineCount(finalText) >= 2, listLineCount(asrText) == 0 {
            return (.confirmListed, "Listed!", .check)
        }

        if FlowAppCategory.classify(bundleID: bundleID, appName: appName, url: url) == .email {
            let lines = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            if lines.count >= 3,
                lines[1].trimmingCharacters(in: .whitespaces).isEmpty,
                !lines[2].trimmingCharacters(in: .whitespaces).isEmpty
            {
                let greeting = lines[0].trimmingCharacters(in: .whitespaces).lowercased()
                let greetingWords = ["hi", "hello", "hey", "dear", "good morning", "good afternoon", "good evening", "greetings"]
                let startsWithGreeting = greetingWords.contains { word in
                    greeting == word || greeting.hasPrefix(word + " ") || greeting.hasPrefix(word + ",")
                        || greeting.hasPrefix(word + "!")
                }
                if startsWithGreeting, greeting.split(separator: " ").count <= 6 {
                    return (.confirmEmail, "Email formatted!", .mail)
                }
            }
        }

        return nil
    }

    /// Name of the input device this dictation used, for user-facing text.
    static func currentMicrophoneName() -> String {
        let manager = AudioDeviceManager.shared
        let idString = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
            ?? manager.selectedDeviceID.map { String($0) }
        if let idString,
            let name = manager.availableDevices.first(where: { String($0.id) == idString })?.name,
            !name.isEmpty
        {
            return name
        }
        return "your microphone"
    }
}
