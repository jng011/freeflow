import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "TranscriptionDelivery")

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let sendAfterPaste: Bool
        /// The "press enter" voice command was spoken: press Return after pasting.
        var sendEnter: Bool = false
        /// The "ask Siri" voice command: open Spotlight, paste there, press Return.
        var askSiri: Bool = false
        /// Cleanup ran and was accepted, so the per-app final-period rule applies.
        var appliesStyleRules: Bool = false
        var timing: FlowDictationTiming? = nil
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async {
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            await paste(text, request: request, actions: actions)
        } else {
            await actions.dismiss()
        }
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            await actions.dismiss()
            return
        }

        let commandText = deliverableText(from: text)
        let finishAndSendKey: FinishAndSendKey = item.sendAfterPaste ? FinishAndSendSettings.selectedKey : .none
        await actions.dismiss()

        Task {
            await runCustomCommand(command: command, commandText: commandText, finishAndSendKey: finishAndSendKey)
        }
    }

    private func runCustomCommand(command: String, commandText: String, finishAndSendKey: FinishAndSendKey) async {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }

            if finishAndSendKey.isEnabled {
                // Let the target app finish pasting before sending.
                try await Task.sleep(nanoseconds: 150_000_000)
                CursorPaster.performSendKey(finishAndSendKey)
            }
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(_ text: String, request: Request, actions: Actions) async {
        let timing = request.timing
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        // The stop sound already played when recording stopped.
        await actions.dismiss()

        if request.askSiri {
            timing?.finalText = text
            timing?.recordsAfterPaste = true
            let sent = await FlowAskSiriCommand.send(text)
            timing?.markPasted(sent)
            timing?.recordDelivered()
            return
        }

        // Fit the words to what's around the cursor, and notice when there's no text box.
        let caret = ParleCaret.frontmostIsTerminal ? nil : ParleCaret.contextForPaste()
        var textToPaste = deliverableText(from: text)
        if request.appliesStyleRules {
            textToPaste = FlowCleanupPolicy.applyFinalPeriodRule(
                to: textToPaste,
                bundleID: timing?.appBundleID,
                appName: timing?.appName,
                url: timing?.url,
                replacingSelection: timing?.hadSelection ?? false,
                caretBefore: caret?.before
            )
        }
        timing?.finalText = textToPaste
        let deliveredText = textToPaste

        // "press enter" with nothing else said: just press Return.
        let pressEnterOnly =
            request.sendEnter
            && FlowPressEnterCommand.Outcome(text: textToPaste, sendEnter: true).hasNothingToPaste
        if pressEnterOnly {
            timing?.recordsAfterPaste = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                CursorPaster.performSendKey(.enter)
                timing?.markPasted(false)
                timing?.recordDelivered()
            }
            return
        }

        let pastedText: String
        if let caret, caret.isEditable, !caret.isSecure, caret.before != nil || caret.after != nil {
            pastedText = ParleCaret.fit(textToPaste, before: caret.before, after: caret.after, defaultTrailingSpace: appendSpace)
        } else {
            pastedText = textToPaste + (appendSpace ? " " : "")
        }
        let nowhereToType = caret.map { !$0.isEditable } ?? false

        let pasteTask = CursorPaster.startPasteAtCursor(pastedText, keepOnClipboard: nowhereToType)
        if nowhereToType {
            // The words stay on the clipboard too; the card offers a Copy button.
            FlowBarController.shared.showNoTextboxCard(text: textToPaste)
        }

        let selectedKey = FinishAndSendSettings.selectedKey
        let finishAndSendKey: FinishAndSendKey = request.sendAfterPaste ? selectedKey : .none
        let sendEnter = request.sendEnter && !nowhereToType
        timing?.recordsAfterPaste = true
        Task { @MainActor in
            let pasteOutcome = await pasteTask.value
            let didPaste = pasteOutcome.result.didPostPasteCommand
            timing?.markPasted(didPaste && !nowhereToType)

            if didPaste && (finishAndSendKey.isEnabled || sendEnter) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let generation = pasteOutcome.autoLearnGeneration {
                    await AutoLearnService.shared.cancelForAutoSend(generation: generation)
                }
                // The finish-and-send key wins; the voice command presses plain Return.
                CursorPaster.performSendKey(finishAndSendKey.isEnabled ? finishAndSendKey : .enter)
            }

            FlowDictionaryStore.shared.noteUsage(in: deliveredText)
            if didPaste, !nowhereToType, let stopToPasteMs = timing?.stopToPasteMs, stopToPasteMs > 1500 {
                SoundManager.shared.playPasteSound()
            }
            timing?.recordDelivered()
        }
    }

    /// The trial restriction banner is never injected into dictated text (private build).
    private func deliverableText(from text: String) -> String {
        text
    }
}
