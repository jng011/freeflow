import AppKit
import Carbon.HIToolbox
import Foundation
import os

@MainActor
class RecordingShortcutManager: ObservableObject {
    /// The live manager, so the Flow Bar can start a hands-free session.
    private(set) static weak var shared: RecordingShortcutManager?

    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
            shortcutModeHandler.resetShortcutState(for: .primaryRecording)
            modeShortcutManager.recordingModeDidChange()
            updateStandaloneModifierActions()
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
            shortcutModeHandler.resetShortcutState(for: .secondaryRecording)
            updateStandaloneModifierActions()
        }
    }
    private var engine: FreeFlowEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"
        case doubleTap = "doubleTap"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            case .doubleTap: return String(localized: "Double Tap")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing && recordingState != .enhancing && recordingState != .busy
    }

    init(engine: FreeFlowEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()
        Self.seedFlowUtilityShortcuts()

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                // The onboarding shortcut test only lights up the keys; it must not start a dictation.
                if FlowOnboardingState.isTestingShortcut, !recorderUIManager.isRecorderPanelVisible {
                    return false
                }
                return Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId in
                await recorderUIManager.toggleRecorderPanel(modeId: modeId)
            },
            cancelRecording: { reason in
                // Another key during the first moment of push-to-talk, or a lone tap: an accidental start.
                await engine.cancelRecording(reason: reason)
                await recorderUIManager.dismissRecorderPanel()
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }

        Self.shared = self
        FlowDictationActions.configure(engine: engine, recorderUIManager: recorderUIManager)
    }

    /// Flow defaults: Paste last transcript ⌃⌘V and Copy last transcript ⌃⌘C, unless the
    /// person already set or cleared them.
    private static func seedFlowUtilityShortcuts() {
        ShortcutStore.seedShortcut(
            .key(keyCode: UInt16(kVK_ANSI_V), modifierFlags: [.control, .command]),
            for: .pasteLastTranscription
        )
        ShortcutStore.seedShortcut(
            .key(keyCode: UInt16(kVK_ANSI_C), modifierFlags: [.control, .command]),
            for: .copyLastTranscription
        )
    }

    /// Starts a session already locked hands-free (Flow Bar click). The next shortcut
    /// press stops it, exactly like a tapped session.
    func beginHandsFreeFromUI() async {
        await shortcutModeHandler.beginHandsFreeFromUI()
    }

    /// A cancel (Esc, the toast's Cancel) also drops a tap queued while processing, so it
    /// doesn't start a new dictation once the cancelled one winds down.
    func dropQueuedPress() {
        shortcutModeHandler.dropQueuedPress()
    }

    private func refreshShortcutMonitoring() {
        removeAllMonitoring()

        refreshShortcutMonitor()
    }

    private func refreshShortcutMonitor() {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut =
            secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            standaloneModifierActions: standaloneModifierActions,
            // The monitor calls these on the main queue, in event order. Starting each Task from
            // the main actor keeps that order: a Task started off the actor can run late, and a
            // fast double tap then saw its second press before the first release (read as a tap).
            onShortcutDown: { [weak self] action, eventTime in
                MainActor.assumeIsolated {
                    FlowStartLatency.keyDown(eventTime: eventTime)
                    Task { @MainActor in
                        guard let self else { return }
                        if action == .commandMode {
                            await CommandModeController.shared.shortcutDown(
                                engine: self.engine, recorderUIManager: self.recorderUIManager)
                            return
                        }
                        guard let mode = self.recordingMode(for: action) else { return }
                        await self.shortcutModeHandler.handleShortcutDown(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    }
                }
            },
            onShortcutUp: { [weak self] action, eventTime in
                MainActor.assumeIsolated {
                    Task { @MainActor in
                        guard let self else { return }
                        if let mode = self.recordingMode(for: action) {
                            await self.shortcutModeHandler.handleShortcutUp(
                                action: action,
                                eventTime: eventTime,
                                mode: mode
                            )
                        } else {
                            await self.handleGlobalShortcut(action)
                        }
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                MainActor.assumeIsolated {
                    Task { @MainActor in
                        guard let self, self.recordingMode(for: action) != nil else { return }
                        await self.shortcutModeHandler.handleInterruption(action: action)
                    }
                }
            },
            onStandaloneModifierChord: { [weak self] action in
                MainActor.assumeIsolated {
                    self?.shortcutModeHandler.clearPendingDoubleTap(for: action)
                }
            }
        )
    }

    private var standaloneModifierActions: Set<ShortcutAction> {
        var actions = Set<ShortcutAction>()
        if primaryRecordingShortcutMode == .toggle || primaryRecordingShortcutMode == .doubleTap {
            actions.insert(.primaryRecording)
        }
        if secondaryRecordingShortcutMode == .toggle || secondaryRecordingShortcutMode == .doubleTap {
            actions.insert(.secondaryRecording)
        }
        return actions
    }

    private func updateStandaloneModifierActions() {
        shortcutMonitor.updateStandaloneModifierActions(standaloneModifierActions)
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .pasteLastTranscription:
            await FlowDictationActions.pasteLast()
        case .copyLastTranscription:
            FlowDictationActions.copyLast()
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openQuickHistory:
            QuickHistoryController.shared.show(modelContext: engine.modelContext, engine: engine)
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        case .commandMode:
            await CommandModeController.shared.shortcutUp(engine: engine, recorderUIManager: recorderUIManager)
        default:
            break
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitor.stop()

        shortcutModeHandler.reset()
    }

    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured =
            primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured =
            secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }

    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }

    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    private let tapLog = Logger(subsystem: "com.jaydenghiyam.parle", category: "ShortcutTap")
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor (FlowCancelReason) async -> Void

    private var shortcutPressStartTime: TimeInterval?
    /// Presses made while the last dictation is still being processed. They start the next
    /// one the moment it lands, instead of cancelling it or leaving a phantom lock.
    private var queuedStartTask: Task<Void, Never>?
    private var queuedPressCount = 0
    private var queuedKeyHeld = false
    private var queuedPressedAt: TimeInterval?
    private var queuedAction: ShortcutAction?
    /// "Still processing" notice: once per processing period, and never for a fast
    /// re-press (within 500 ms of the last key event).
    private var processingNoticeShown = false
    private var processingNoticeID: UUID?
    private var lastKeyEventAt: TimeInterval?
    private let processingNoticeMinGap: TimeInterval = 0.5
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var activeShortcutIsDoubleTap = false
    private var lastShortcutPressTime: Date?
    private var pendingDoubleTapReleaseTimes: [ShortcutAction: TimeInterval] = [:]
    /// Hybrid: a lone tap is discarded; a second tap within the window locks hands-free.
    private var pendingTapDeadline: TimeInterval?
    private var isSecondTap = false
    private var pressStoppedHandsFree = false
    private var tapDiscardTask: Task<Void, Never>?

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5
    private let doubleTapThreshold: TimeInterval = 0.7
    /// Free Flow's rule: a second press within 500 ms of the first press locks hands-free.
    private let quickLockWindow: TimeInterval = 0.5
    /// When the press that opened the current hybrid session went down.
    private var sessionPressedAt: TimeInterval?
    /// A push-to-talk hold this long suggests hands-free mode after release.
    private let handsFreeSuggestionHoldThreshold: TimeInterval = 60
    private static let handsFreeSuggestionTip = FlowTipLedger.Tip(
        id: "handsFreeSuggestion", maxShows: 3, minInterval: FlowTipLedger.Tip.hour)

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor (FlowCancelReason) async -> Void
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
    }

    func reset() {
        clearQueuedPress()
        processingNoticeShown = false
        lastKeyEventAt = nil
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
        pendingTapDeadline = nil
        sessionPressedAt = nil
        isSecondTap = false
        pressStoppedHandsFree = false
        tapDiscardTask?.cancel()
        tapDiscardTask = nil
        clearPendingDoubleTaps()
    }

    func clearPendingDoubleTaps() {
        pendingDoubleTapReleaseTimes.removeAll()
    }

    /// Flow Bar click while idle: record hands-free until the next shortcut press.
    func beginHandsFreeFromUI() async {
        guard !isRecorderVisible(), recordingState() == .idle, canHandleShortcutAction() else { return }
        processingNoticeShown = false
        isShortcutPressed = false
        shortcutPressStartTime = nil
        activeRecordingShortcutAction = nil
        isHandsFreeRecording = true
        FlowDictationState.shared.setHandsFree(true)
        await toggleRecorderPanel(nil)
    }

    /// Tells the Flow Bar the current session is locked hands-free.
    private func isRecordingLive() -> Bool {
        switch recordingState() {
        case .starting, .recording: return true
        case .idle: return isRecorderVisible()
        case .transcribing, .enhancing, .busy: return false
        }
    }

    private func queuePress(action: ShortcutAction, eventTime: TimeInterval, sinceLastKey: TimeInterval, modeId: UUID?) {
        queuedPressCount += 1
        queuedKeyHeld = true
        queuedAction = action
        if queuedPressedAt == nil { queuedPressedAt = eventTime }
        tapLog.notice("queued press count=\(self.queuedPressCount, privacy: .public) state=\(String(describing: self.recordingState()), privacy: .public)")
        if queuedPressCount == 1, sinceLastKey > processingNoticeMinGap {
            showProcessingNoticeIfNeeded()
        }
        guard queuedStartTask == nil else { return }
        queuedStartTask = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(6)
            while let self, !Task.isCancelled, Date() < deadline {
                if self.canHandleShortcutAction(), self.recordingState() == .idle, !self.isRecorderVisible() {
                    await self.startQueuedPress(modeId: modeId)
                    return
                }
                // A lone tap that was let go: nothing to start.
                if self.queuedPressCount == 1, !self.queuedKeyHeld,
                    let pressedAt = self.queuedPressedAt,
                    ProcessInfo.processInfo.systemUptime - pressedAt > self.doubleTapThreshold
                {
                    break
                }
                try? await Task.sleep(for: .milliseconds(15))
            }
            self?.clearQueuedPress()
        }
    }

    private func startQueuedPress(modeId: UUID?) async {
        let presses = queuedPressCount
        let held = queuedKeyHeld
        let pressedAt = queuedPressedAt
        let action = queuedAction
        clearQueuedPress()
        // The last dictation landed: a new processing period may show the notice again.
        processingNoticeShown = false
        if let noticeID = processingNoticeID {
            processingNoticeID = nil
            FlowBarController.shared.dismissToast(ifCurrent: noticeID)
        }
        tapLog.notice("queued start presses=\(presses, privacy: .public) held=\(held, privacy: .public)")
        if presses >= 2 {
            isHandsFreeRecording = true
            isShortcutPressed = held
            activeRecordingShortcutAction = held ? action : nil
            isSecondTap = held
            shortcutPressStartTime = pressedAt
            await toggleRecorderPanel(modeId)
            markHandsFreeIfRecording()
        } else if held {
            // Still held: a normal push-to-talk that started late. Its release stops it.
            isShortcutPressed = true
            activeRecordingShortcutAction = action
            shortcutPressStartTime = pressedAt.map { min($0, ProcessInfo.processInfo.systemUptime - hybridPressThreshold) }
            lastShortcutPressTime = Date()
            await toggleRecorderPanel(modeId)
        }
    }

    func dropQueuedPress() {
        clearQueuedPress()
    }

    /// Prompt mode: Ctrl held when fn goes down, or pressed within 0.3 s while fn is still held.
    private func armPromptMode(action: ShortcutAction) {
        FlowPromptMode.reset()
        guard action == .primaryRecording, FlowPromptMode.isEnabled else { return }
        if NSEvent.modifierFlags.contains(.control) {
            FlowPromptMode.activate()
            return
        }
        Task { @MainActor [weak self] in
            let step: UInt64 = 30_000_000
            var waited: TimeInterval = 0
            while waited < FlowPromptMode.lateControlWindow {
                try? await Task.sleep(nanoseconds: step)
                waited += 0.03
                guard let self, self.isShortcutPressed else { return }
                if NSEvent.modifierFlags.contains(.control) {
                    FlowPromptMode.activate()
                    return
                }
            }
        }
    }

    private func clearQueuedPress() {
        queuedStartTask?.cancel()
        queuedStartTask = nil
        queuedPressCount = 0
        queuedKeyHeld = false
        queuedPressedAt = nil
        queuedAction = nil
    }

    /// "Free Flow was processing your last transcript" notice, with a Cancel that does what Esc does.
    private func showProcessingNoticeIfNeeded() {
        guard !processingNoticeShown, !canHandleShortcutAction() else { return }
        processingNoticeShown = true
        let toast = FlowBarToast(
            style: .standard,
            title: "Still processing your last dictation",
            body: "Press Esc or click Cancel to stop it.",
            actionTitle: "Cancel",
            action: { [weak self] in
                guard let self else { return }
                self.processingNoticeID = nil
                // Already landed: don't cancel the dictation the queued press started.
                guard !self.canHandleShortcutAction() else { return }
                self.clearQueuedPress()
                Task { @MainActor in await self.cancelRecording(.user) }
            },
            duration: 6
        )
        processingNoticeID = FlowBarController.shared.showToast(toast, onEnd: nil)
    }

    /// Nudge after a long push-to-talk hold: 3 s after release, suggest double tap
    /// hands-free. At most 3 times total, at most once an hour.
    private func scheduleHandsFreeSuggestion() {
        guard FlowTipLedger.isEligible(Self.handsFreeSuggestionTip) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            // A new dictation started meanwhile: don't cover the pill.
            let state = self.recordingState()
            guard !self.isShortcutPressed, state != .starting, state != .recording,
                FlowTipLedger.isEligible(Self.handsFreeSuggestionTip)
            else { return }
            FlowTipLedger.markShown(Self.handsFreeSuggestionTip)
            let key = ShortcutStore.shortcut(for: .primaryRecording)?.displayTokens.joined(separator: " + ") ?? "fn"
            var toast = FlowBarToast(style: .standard, title: "Try hands-free mode")
            toast.badge = "Tip"
            toast.body = "Double tap \(key) to dictate without holding it down. Tap \(key) again to stop."
            toast.duration = 8
            FlowBarController.shared.showToast(toast)
        }
    }

    private func markHandsFreeIfRecording() {
        switch recordingState() {
        case .starting, .recording:
            FlowDictationState.shared.setHandsFree(true)
        case .idle:
            // Started a moment ago and the recorder hasn't reported `.starting` yet.
            if isRecorderVisible() {
                FlowDictationState.shared.setHandsFree(true)
            }
        case .transcribing, .enhancing, .busy:
            break
        }
    }

    func clearPendingDoubleTap(for action: ShortcutAction) {
        pendingDoubleTapReleaseTimes.removeValue(forKey: action)
    }

    func clearPendingModeDoubleTaps() {
        pendingDoubleTapReleaseTimes = pendingDoubleTapReleaseTimes.filter { action, _ in
            if case .mode = action { return false }
            return true
        }
    }

    func resetShortcutState(for action: ShortcutAction) {
        pendingDoubleTapReleaseTimes.removeValue(forKey: action)
        guard activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        shortcutPressStartTime = nil
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false
    }

    func handleShortcutDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        let sinceLastKey = lastKeyEventAt.map { eventTime - $0 } ?? .infinity
        lastKeyEventAt = eventTime

        if interruptedRecordingActions.remove(action) != nil {
            tapLog.notice("down ignored: marked interrupted")
            return
        }

        if mode == .doubleTap && (!canHandleShortcutAction() || recordingState() == .starting) {
            clearPendingDoubleTap(for: action)
            return
        }

        if mode == .hybrid, !isShortcutPressed, queuedStartTask != nil || !canHandleShortcutAction() {
            queuePress(action: action, eventTime: eventTime, sinceLastKey: sinceLastKey, modeId: modeId)
            return
        }
        // Nothing is processing: the next processing period may show its notice.
        processingNoticeShown = false

        if mode == .hybrid, !isShortcutPressed, recordingState() == .idle, !isRecorderVisible(),
            isHandsFreeRecording || pressStoppedHandsFree
        {
            // The last session ended on its own (cancel, silence, error) while locked. Its
            // hands-free flag is stale: without this, the next press is spent "stopping" a
            // session that no longer exists and a double tap becomes a lone tap.
            tapLog.notice("clearing stale hands-free flag")
            isHandsFreeRecording = false
            pressStoppedHandsFree = false
            isSecondTap = false
        }

        if mode == .hybrid {
            let sinceStart = sessionPressedAt.map { eventTime - $0 } ?? -1
            tapLog.notice("hybrid down pressed=\(self.isShortcutPressed, privacy: .public) deadline=\(self.pendingTapDeadline.map { $0 - eventTime } ?? -1, privacy: .public) sinceStart=\(sinceStart, privacy: .public) state=\(String(describing: self.recordingState()), privacy: .public) visible=\(self.isRecorderVisible(), privacy: .public) hf=\(self.isHandsFreeRecording, privacy: .public)")
        }

        // Second press of a double tap : within 0.5 s of the press that
        // started the session, or within the window after its release. Either one locks.
        if mode == .hybrid, !isShortcutPressed, !isHandsFreeRecording, !pressStoppedHandsFree,
            isRecordingLive() || sessionPressedAt.map({ eventTime - $0 < quickLockWindow }) == true,
            pendingTapDeadline.map({ eventTime <= $0 }) == true
                || sessionPressedAt.map({ eventTime - $0 < quickLockWindow }) == true
        {
            // Second tap of a double tap: the recording from the first tap keeps going.
            sessionPressedAt = nil
            pendingTapDeadline = nil
            tapDiscardTask?.cancel()
            tapDiscardTask = nil
            isSecondTap = true
            isShortcutPressed = true
            activeRecordingShortcutAction = action
            shortcutPressStartTime = eventTime
            // Lock on the second press, not its release: the pill and lock sound answer at once.
            isHandsFreeRecording = true
            markHandsFreeIfRecording()
            return
        }

        // The hybrid key needs no cooldown: a fast second press is a double tap, never noise.
        if mode != .doubleTap, mode != .hybrid, let lastTrigger = lastShortcutPressTime,
            Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown
        {
            return
        }

        guard !isShortcutPressed else {
            if mode == .hybrid { tapLog.notice("hybrid down ignored: key already down") }
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutIsDoubleTap = mode == .doubleTap
        activeShortcutCanCancelAccidentalStart = mode != .doubleTap && canCurrentShortcutPressCancelAccidentalStart
        if mode != .doubleTap {
            lastShortcutPressTime = Date()
        }
        shortcutPressStartTime = eventTime

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                pressStoppedHandsFree = true
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                if mode == .hybrid {
                    sessionPressedAt = eventTime
                    armPromptMode(action: action)
                }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .doubleTap:
            break
        }
    }

    func handleShortcutUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        lastKeyEventAt = eventTime
        if queuedStartTask != nil, !isShortcutPressed, queuedAction == action {
            queuedKeyHeld = false
            return
        }
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        activeShortcutIsDoubleTap = false

        switch mode {
        case .toggle:
            isHandsFreeRecording = true
            markHandsFreeIfRecording()

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            tapLog.notice("hybrid up dur=\(pressDuration, privacy: .public) second=\(self.isSecondTap, privacy: .public) stoppedHF=\(self.pressStoppedHandsFree, privacy: .public) hf=\(self.isHandsFreeRecording, privacy: .public) visible=\(self.isRecorderVisible(), privacy: .public)")
            if isSecondTap {
                // Already locked when the second press went down.
                isSecondTap = false
            } else if pressStoppedHandsFree || isHandsFreeRecording {
                // The press that stopped (or belongs to) a hands-free session.
                pressStoppedHandsFree = false
            } else if pressDuration >= hybridPressThreshold {
                if pressDuration >= handsFreeSuggestionHoldThreshold {
                    scheduleHandsFreeSuggestion()
                }
                if recordingState() == .recording {
                    guard canHandleShortcutAction() else { return }
                    await toggleRecorderPanel(modeId)
                }
            } else {
                // A lone tap: wait for a second one, otherwise throw the recording away.
                pendingTapDeadline = eventTime + doubleTapThreshold
                tapDiscardTask?.cancel()
                tapDiscardTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(self?.doubleTapThreshold ?? 0.7))
                    guard let self, !Task.isCancelled, self.pendingTapDeadline != nil else { return }
                    self.pendingTapDeadline = nil
                    self.tapDiscardTask = nil
                    self.tapLog.notice("lone tap expired hf=\(self.isHandsFreeRecording, privacy: .public) pressed=\(self.isShortcutPressed, privacy: .public) visible=\(self.isRecorderVisible(), privacy: .public)")
                    guard !self.isHandsFreeRecording, !self.isShortcutPressed, self.isRecorderVisible(),
                        self.isRecordingLive()
                    else { return }
                    await self.cancelRecording(.lonelyTap)
                }
            }

        case .doubleTap:
            guard canHandleShortcutAction(), recordingState() != .starting else {
                clearPendingDoubleTap(for: action)
                break
            }
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration < 0 || pressDuration > doubleTapThreshold {
                pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            } else if let firstRelease = pendingDoubleTapReleaseTimes.removeValue(forKey: action),
                eventTime - firstRelease >= 0,
                eventTime - firstRelease <= doubleTapThreshold
            {
                await toggleRecorderPanel(modeId)
                isHandsFreeRecording = isRecorderVisible()
                if isHandsFreeRecording {
                    markHandsFreeIfRecording()
                }
            } else {
                pendingDoubleTapReleaseTimes[action] = eventTime
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: ShortcutAction) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        if activeShortcutIsDoubleTap {
            isShortcutPressed = false
            shortcutPressStartTime = nil
            activeRecordingShortcutAction = nil
            activeShortcutCanCancelAccidentalStart = false
            activeShortcutIsDoubleTap = false
            pendingDoubleTapReleaseTimes.removeValue(forKey: action)
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording(.otherShortcut)
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
