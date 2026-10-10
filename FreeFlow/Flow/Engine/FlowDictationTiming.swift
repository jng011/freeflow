import AppKit
import Foundation
import os

/// One dictation's timing, target app and text, collected along the pipeline and
/// recorded once into FlowStatsStore when delivery decides what happened.
@MainActor
final class FlowDictationTiming {
    /// The dictation currently being recorded or processed. Cleanup reads its target app
    /// for the style rules; nil outside a dictation (files, retries).
    private(set) static var current: FlowDictationTiming?

    let startedAt: Date
    private(set) var stoppedAt: Date
    private(set) var textReadyAt: Date?
    private(set) var pastedAt: Date?

    /// Captured at recording start: the app the words are meant for.
    let appBundleID: String?
    let appName: String?
    let appProcessID: pid_t?
    /// Browser URL resolved at recording start (ActiveWindowService), read at stop.
    private(set) var url: String?

    var transcriptionID: UUID?
    var audioDuration: TimeInterval = 0
    var asrText = ""
    var finalText = ""
    var dictionaryReplacementCount = 0
    var transcriptionSource = "mac"
    var pasted = false
    /// The person had text selected when they started, so the paste replaces a selection.
    var hadSelection = false
    /// Delivery records after the paste finishes; the pipeline must not record first.
    var recordsAfterPaste = false

    private var didRecord = false
    private var delayNoticeTask: Task<Void, Never>?

    private static let processingDelayNotice: TimeInterval = 6

    init(startedAt: Date = Date()) {
        let app = NSWorkspace.shared.frontmostApplication
        self.startedAt = startedAt
        self.stoppedAt = startedAt
        self.appBundleID = app?.bundleIdentifier
        self.appName = app?.localizedName
        self.appProcessID = app?.processIdentifier
    }

    /// A reprocessed (undone) dictation keeps the original target app and start time.
    init(reprocessing original: FlowDictationTiming?) {
        let app = NSWorkspace.shared.frontmostApplication
        self.startedAt = original?.startedAt ?? Date()
        self.stoppedAt = Date()
        self.appBundleID = original?.appBundleID ?? app?.bundleIdentifier
        self.appName = original?.appName ?? app?.localizedName
        self.appProcessID = original?.appProcessID ?? app?.processIdentifier
        self.url = original?.url
    }

    // MARK: - Lifecycle

    func makeCurrent() {
        Self.current = self
    }

    func resignCurrent() {
        if Self.current === self {
            Self.current = nil
        }
    }

    /// Key up (or finish): processing time starts here.
    func markStopped() {
        stoppedAt = Date()
        if url == nil {
            url = ActiveWindowService.shared.currentURL
        }
        startDelayNotice()
    }

    func markTextReady() {
        if textReadyAt == nil { textReadyAt = Date() }
        cancelDelayNotice()
    }

    func markPasted(_ didPaste: Bool) {
        pasted = didPaste
        pastedAt = Date()
    }

    var stopToTextMs: Int? {
        textReadyAt.map { max(0, Int($0.timeIntervalSince(stoppedAt) * 1000)) }
    }

    var stopToPasteMs: Int? {
        pastedAt.map { max(0, Int($0.timeIntervalSince(stoppedAt) * 1000)) }
    }

    // MARK: - Processing delay notice

    private func startDelayNotice() {
        cancelDelayNotice()
        guard UserDefaults.standard.bool(forKey: FlowKeys.processingDelayNotice) else { return }
        delayNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.processingDelayNotice))
            guard !Task.isCancelled, let self, self.textReadyAt == nil, !self.didRecord,
                FlowDictationState.shared.phase == .processing
            else { return }
            FlowBarController.shared.showToast(
                FlowBarToast(style: .mini, title: "Taking longer than usual...", icon: .loaderCircle, duration: 4)
            )
        }
    }

    func cancelDelayNotice() {
        delayNoticeTask?.cancel()
        delayNoticeTask = nil
    }

    // MARK: - Stats

    /// Records this dictation once. Later calls are ignored.
    func record(status: FlowDictationCapture.Status) {
        guard !didRecord, let transcriptionID else { return }
        didRecord = true
        cancelDelayNotice()

        let isCanceled = status == .canceled
        let capture = FlowDictationCapture(
            transcriptionID: transcriptionID,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            audioDuration: audioDuration,
            speechDuration: nil,
            asrText: isCanceled ? "" : asrText,
            finalText: isCanceled || status == .failed ? "" : finalText,
            dictionaryReplacementCount: isCanceled ? 0 : dictionaryReplacementCount,
            appBundleID: appBundleID,
            appName: appName,
            url: url,
            language: UserDefaults.standard.string(forKey: "SelectedLanguage"),
            transcriptionSource: transcriptionSource,
            stopToTextMs: isCanceled ? nil : stopToTextMs,
            stopToPasteMs: isCanceled ? nil : stopToPasteMs,
            pasted: isCanceled ? false : pasted,
            status: status
        )
        FlowStatsStore.shared.record(capture)
    }

    /// Completed or empty, from the delivered text.
    func recordDelivered() {
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        record(status: trimmed.isEmpty ? .empty : .completed)
    }
}
