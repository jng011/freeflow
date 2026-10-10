import AppKit
import Combine
import SwiftUI
import os

// MARK: - Public model

/// Every visual state of the Flow Bar pill.
enum FlowBarState: Equatable {
    case hidden
    case resting
    case ready
    case initializing
    case activePTT
    case activeHandsFree
    case processing
    case error

    var isActive: Bool {
        self == .activePTT || self == .activeHandsFree
    }

    var isIdleLike: Bool {
        self == .hidden || self == .resting || self == .ready
    }
}

/// A toast shown by the Flow Bar, anchored where the pill sits.
struct FlowBarToast {
    enum Style { case mini, condensed, standard }
    var style: Style = .mini
    var badge: String? = nil  // standard only, e.g. "Milestone", "Tip"
    var title: String
    var body: String? = nil
    var icon: FlowIconName? = nil  // mini/condensed leading icon
    var isError: Bool = false  // standard: red alert icon; plays error sound if sound == nil
    var isWarning: Bool = false  // standard: yellow triangle icon
    var actionTitle: String? = nil
    var action: (@MainActor () -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryAction: (@MainActor () -> Void)? = nil
    var duration: TimeInterval = 4
    var showsProgress: Bool = false  // condensed: draining bar
    var sound: FlowNotificationSound? = nil  // played at 0.5 volume via SoundManager
}

/// Why a toast or card went away. Passed to internal end handlers.
enum FlowBarDismissReason {
    case timeout
    case closed
    case action
    case replaced
    case dictationStarted
}

/// The toast or card currently owned by the bar.
struct FlowBarPresentation: Identifiable {
    enum Kind {
        case toast(FlowBarToast)
        case card(String)
    }

    let id = UUID()
    let kind: Kind
    let duration: TimeInterval
    let showsProgress: Bool
    /// Pill state the morph starts from.
    let originState: FlowBarState
}

enum FlowBarHoveredButton: Equatable {
    case cancel
    case finish
}

// MARK: - Controller

@MainActor
final class FlowBarController: ObservableObject {
    static let shared = FlowBarController()

    // Published UI state
    @Published private(set) var state: FlowBarState = .hidden
    @Published private(set) var isPointerOverPill = false
    @Published private(set) var presentation: FlowBarPresentation?
    @Published private(set) var dismissingPresentationID: UUID?
    @Published private(set) var isPillSuppressed = false
    @Published private(set) var isToastPaused = false
    @Published private(set) var isToastHovered = false
    @Published private(set) var tooltip: FlowBarTooltipContent?
    @Published private(set) var cardCopied = false

    let levelMeter = FlowBarLevelMeter()

    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowBar")

    private weak var engine: FreeFlowEngine?
    private weak var recorderUIManager: RecorderUIManager?

    private var panel: FlowBarPanel?
    private var hostingView: FlowBarHostingView?
    private let tracker = FlowBarMouseTracker()
    private var cancellables = Set<AnyCancellable>()
    private var isConfigured = false
    private var isSessionActive = false

    // State machine inputs
    private var restState: FlowBarState = .hidden
    private var isHoveringHotArea = false
    private var hoverTask: Task<Void, Never>?
    private var lastPhase: FlowDictationPhase = .idle
    private var errorUntil: Date?
    private var errorTask: Task<Void, Never>?
    private var latchedHandsFree = false
    private var morphingUntil = Date.distantPast
    private var deferredApplyTask: Task<Void, Never>?
    private var stateChangedAt = Date.distantPast
    private var snoozeTask: Task<Void, Never>?

    // Tooltip
    private var hoveredButton: FlowBarHoveredButton?
    private var tooltipTask: Task<Void, Never>?
    private var pendingTooltip: FlowBarTooltipContent?

    // Presentation
    private var presentationFrameInPanel: CGRect = .zero
    private var presentationTimerTask: Task<Void, Never>?
    private var presentationRemaining: TimeInterval = 0
    private var presentationResumedAt = Date()
    private var presentationOnEnd: (@MainActor (FlowBarDismissReason) -> Void)?
    private var presentationCleanupTask: Task<Void, Never>?
    private var keyMonitors: [Any] = []

    // Screen following
    private var screenTimer: Timer?

    private static let morphDuration: TimeInterval = 0.42
    private static let exitContentDuration: TimeInterval = 0.12

    private init() {}

    // MARK: - Configuration

    /// Called from RecorderUIManager.configure(engine:recorder:). Creates the always-on panel.
    func configure(engine: FreeFlowEngine, recorderUIManager: RecorderUIManager) {
        self.engine = engine
        self.recorderUIManager = recorderUIManager
        guard !isConfigured else { return }
        isConfigured = true

        tracker.onMove = { [weak self] point in
            self?.trackerDidMove(to: point)
        }
        tracker.start()

        FlowDictationState.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.dictationStateDidChange()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVisibility()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.repositionPanel(animated: false)
            }
            .store(in: &cancellables)

        buildPanel()
        startScreenTimer()
        refreshVisibility()
        logger.notice("Flow Bar configured")
    }

    // MARK: - Session hooks (RecorderUIManager)

    /// A dictation session became active (old meaning of `isRecorderPanelVisible = true`).
    func sessionDidStart() {
        isSessionActive = true
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
        followCursorScreen(force: true)
        recomputeState()
    }

    /// The dictation session ended. The bar stays on screen and returns to rest.
    func sessionDidEnd() {
        isSessionActive = false
        recomputeState()
    }

    /// Screen reconfiguration or wake. Rebuilding drops a window that may have stopped rendering.
    func handleScreenInvalidation(reason: String, rebuild: Bool) {
        if rebuild, !isSessionActive, presentation == nil, FlowDictationState.shared.phase == .idle {
            logger.notice("Rebuilding Flow Bar panel (\(reason, privacy: .public))")
            destroyPanel()
            buildPanel()
        } else {
            logger.notice("Repositioning Flow Bar panel (\(reason, privacy: .public))")
            if panel == nil { buildPanel() }
            repositionPanel(animated: false)
            panel?.orderFrontRegardless()
        }
    }

    // MARK: - Public API

    func showCancelToast(undo: @escaping @MainActor () async -> Void) {
        var toast = FlowBarToast(style: .condensed, title: "Transcript cancelled")
        toast.actionTitle = "Undo"
        toast.action = {
            Task { @MainActor in
                await undo()
            }
        }
        toast.duration = 5
        toast.showsProgress = true
        showToast(toast)
    }

    /// Shown when the dictation key was only tapped: dictating takes a hold or a double-tap.
    func showDontTapToast() {
        let key = ShortcutStore.shortcut(for: .primaryRecording)?.displayTokens.joined(separator: " + ") ?? "fn"
        var toast = FlowBarToast(style: .standard, title: "Don't tap. Hold down \(key).")
        toast.body = "Hold down \(key) while speaking, release to see text."
        toast.isWarning = true
        toast.duration = 5
        toast.showsProgress = true
        showToast(toast)
    }

    func showNoTextboxCard(text: String) {
        present(.card(text), duration: 8, showsProgress: false, onEnd: nil)
        installKeyMonitors()
    }

    func showToast(_ toast: FlowBarToast) {
        showToast(toast, onEnd: nil)
    }

    /// Internal variant that reports how the toast ended.
    @discardableResult
    func showToast(_ toast: FlowBarToast, onEnd: (@MainActor (FlowBarDismissReason) -> Void)?) -> UUID {
        if let sound = toast.sound {
            SoundManager.shared.playNotificationSound(sound)
        } else if toast.isError {
            SoundManager.shared.playNotificationSound(.error)
        }
        let showsProgress = toast.showsProgress && (toast.style == .condensed || toast.style == .standard)
        return present(.toast(toast), duration: max(0.5, toast.duration), showsProgress: showsProgress, onEnd: onEnd)
    }

    func dismissToast() {
        guard let presentation else { return }
        beginDismiss(id: presentation.id, reason: .closed)
    }

    /// Dismisses only if `id` is still the visible toast.
    func dismissToast(ifCurrent id: UUID) {
        guard presentation?.id == id else { return }
        beginDismiss(id: id, reason: .closed)
    }

    func flashError() {
        errorUntil = Date().addingTimeInterval(0.5)
        scheduleErrorExpiry()
        recomputeState(force: true)
    }

    func refreshVisibility() {
        let defaults = UserDefaults.standard
        let showAlways = defaults.object(forKey: FlowKeys.showBarAlways) as? Bool ?? true
        let snoozeUntil = defaults.double(forKey: FlowKeys.barSnoozeUntil)
        let onboarded = defaults.bool(forKey: OnboardingSettings.completedV2Key)
        let now = Date().timeIntervalSince1970

        restState = (!showAlways || snoozeUntil > now || !onboarded) ? .hidden : .resting

        snoozeTask?.cancel()
        snoozeTask = nil
        if snoozeUntil > now {
            let wait = snoozeUntil - now + 0.5
            snoozeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.refreshVisibility()
            }
        }
        recomputeState()
    }

    func hideForOneHour() {
        UserDefaults.standard.set(Date().timeIntervalSince1970 + 3600, forKey: FlowKeys.barSnoozeUntil)
        refreshVisibility()

        var toast = FlowBarToast(style: .mini, title: "The Flow Bar will be hidden for an hour")
        toast.actionTitle = "Undo"
        toast.action = { [weak self] in
            UserDefaults.standard.set(0.0, forKey: FlowKeys.barSnoozeUntil)
            self?.refreshVisibility()
        }
        toast.duration = 5
        showToast(toast)
    }

    // MARK: - View callbacks

    func pillTapped() {
        switch state {
        case .ready:
            Task { await FlowDictationActions.startHandsFree() }
        case .activePTT:
            Task { await FlowDictationActions.finish() }
        default:
            break
        }
    }

    func cancelTapped() {
        Task { await FlowDictationActions.cancel() }
    }

    func finishTapped() {
        Task { await FlowDictationActions.finish() }
    }

    /// Runs a toast action. The toast is dismissed first, then the action runs.
    func performToastAction(primary: Bool) {
        guard let presentation, case .toast(let toast) = presentation.kind else { return }
        let action = primary ? toast.action : toast.secondaryAction
        beginDismiss(id: presentation.id, reason: .action)
        action?()
    }

    func copyCardText() {
        guard let presentation, case .card(let text) = presentation.kind, !cardCopied else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        cardCopied = true
        presentationTimerTask?.cancel()
        let id = presentation.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            self?.beginDismiss(id: id, reason: .action)
        }
    }

    func updatePresentationFrame(_ frame: CGRect, id: UUID) {
        guard presentation?.id == id else { return }
        presentationFrameInPanel = frame
    }

    /// Fraction of the toast lifetime that is left, for the draining bar.
    func remainingFraction(at date: Date) -> Double {
        guard let presentation, presentation.duration > 0 else { return 0 }
        let elapsed = isToastPaused ? 0 : date.timeIntervalSince(presentationResumedAt)
        return min(1, max(0, (presentationRemaining - elapsed) / presentation.duration))
    }

    /// Right-click on the pill in READY (or RESTING after a quick move).
    func handleRightClick(event: NSEvent, in view: NSView) -> Bool {
        guard presentation == nil, state == .ready || state == .resting,
            let pill = pillScreenRect()?.insetBy(dx: -10, dy: -6),
            pill.contains(NSEvent.mouseLocation)
        else { return false }

        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(FlowBarMenuAction.item(title: "Paste last transcript") {
            Task { await FlowDictationActions.pasteLast() }
        })

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        micMenu.autoenablesItems = false
        let devices = AudioDeviceManager.shared.availableDevices
        let current = AudioDeviceManager.shared.getCurrentDevice()
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No devices available", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            micMenu.addItem(empty)
        } else {
            for device in devices {
                let deviceID = device.id
                let item = FlowBarMenuAction.item(title: device.name) {
                    AudioDeviceManager.shared.selectDeviceAndSwitchToCustomMode(id: deviceID)
                }
                item.state = deviceID == current ? .on : .off
                micMenu.addItem(item)
            }
        }
        micItem.submenu = micMenu
        menu.addItem(micItem)

        menu.addItem(.separator())
        menu.addItem(FlowBarMenuAction.item(title: "Hide for 1 hour") { [weak self] in
            self?.hideForOneHour()
        })
        menu.addItem(FlowBarMenuAction.item(title: "Settings...") {
            FlowNavigator.shared.presentSettings()
            NSApp.activate()
        })

        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return true
    }

    // MARK: - State machine

    private func dictationStateDidChange() {
        let phase = FlowDictationState.shared.phase
        if phase != lastPhase {
            let previous = lastPhase
            lastPhase = phase
            if phase == .error {
                errorUntil = Date().addingTimeInterval(0.5)
                scheduleErrorExpiry()
            }
            if (phase == .initializing || phase == .listening),
                previous == .idle || previous == .error,
                let presentation, dismissingPresentationID != presentation.id
            {
                beginDismiss(id: presentation.id, reason: .dictationStarted)
            }
        }
        recomputeState()
    }

    private func scheduleErrorExpiry() {
        errorTask?.cancel()
        errorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled, let self else { return }
            self.errorUntil = nil
            self.recomputeState()
        }
    }

    private func computeState() -> FlowBarState {
        let dictation = FlowDictationState.shared
        if let errorUntil, errorUntil > Date() {
            return .error
        }

        switch dictation.phase {
        case .idle, .error:
            latchedHandsFree = false
            if restState == .hidden { return .hidden }
            return isHoveringHotArea ? .ready : .resting
        case .initializing:
            latchedHandsFree = false
            return .initializing
        case .listening:
            // A listening update never downgrades hands-free back to push-to-talk.
            if dictation.isHandsFree || latchedHandsFree || state == .activeHandsFree {
                latchedHandsFree = true
                return .activeHandsFree
            }
            return .activePTT
        case .processing:
            latchedHandsFree = false
            return .processing
        }
    }

    private func recomputeState(force: Bool = false) {
        // Finish a toast morph before applying out-of-order phase updates.
        let now = Date()
        if !force, now < morphingUntil {
            scheduleDeferredApply(after: morphingUntil.timeIntervalSince(now))
            return
        }

        updateMouseCapture()
        let newState = computeState()
        if newState != state {
            let oldState = state
            if newState == .activeHandsFree && oldState != .activeHandsFree {
                SoundManager.shared.playLockSound()
            }
            state = newState
            stateChangedAt = now

            if newState.isActive {
                levelMeter.start()
            } else {
                levelMeter.stop()
            }
            if !newState.isActive { hoveredButton = nil }
        }
        updateMouseCapture()
        updateTooltip()
    }

    private func scheduleDeferredApply(after delay: TimeInterval) {
        deferredApplyTask?.cancel()
        deferredApplyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.01, delay + 0.01)))
            guard !Task.isCancelled else { return }
            self?.recomputeState()
        }
    }

    // MARK: - Tooltip

    private func updateTooltip() {
        let desired: FlowBarTooltipContent?
        var delay: Duration = .zero

        if presentation != nil {
            desired = nil
        } else {
            switch state {
            case .ready:
                desired = .dictate(key: Self.primaryKeyDisplay())
                delay = .milliseconds(150)
            case .activeHandsFree:
                if let hoveredButton {
                    desired = hoveredButton == .cancel ? .cancel : .finish
                    delay = .milliseconds(50)
                } else if isPointerOverPill {
                    desired = .handsFree(key: Self.primaryKeyDisplay())
                } else {
                    desired = nil
                }
            default:
                desired = nil
            }
        }

        guard desired != pendingTooltip else { return }
        pendingTooltip = desired
        tooltipTask?.cancel()

        guard let desired else {
            tooltip = nil
            return
        }
        if delay == .zero || tooltip != nil {
            tooltip = desired
            return
        }
        let tooltipDelay = delay
        tooltipTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: tooltipDelay)
            guard !Task.isCancelled, let self, self.pendingTooltip == desired else { return }
            self.tooltip = desired
        }
    }

    static func primaryKeyDisplay() -> String {
        guard let shortcut = ShortcutStore.shortcut(for: .primaryRecording) else { return "fn" }
        let tokens = shortcut.displayTokens.map { $0 == "Fn" ? "fn" : $0 }
        let joined = tokens.joined(separator: " + ")
        return joined.isEmpty ? "fn" : joined
    }

    // MARK: - Presentation lifecycle

    @discardableResult
    private func present(
        _ kind: FlowBarPresentation.Kind,
        duration: TimeInterval,
        showsProgress: Bool,
        onEnd: (@MainActor (FlowBarDismissReason) -> Void)?
    ) -> UUID {
        // Only one toast or card at a time: the newer one replaces the older one.
        if presentation != nil {
            endPresentationImmediately(reason: .replaced)
        }

        let origin = state == .hidden ? FlowBarState.resting : state
        let newPresentation = FlowBarPresentation(
            kind: kind,
            duration: duration,
            showsProgress: showsProgress,
            originState: origin
        )
        cardCopied = false
        presentationFrameInPanel = .zero
        presentationOnEnd = onEnd
        presentationRemaining = duration
        isToastPaused = false
        isToastHovered = false
        dismissingPresentationID = nil
        presentation = newPresentation
        isPillSuppressed = true
        morphingUntil = Date().addingTimeInterval(Self.morphDuration)

        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
        scheduleExpiry()
        tracker.setFastPolling(true)
        updateTooltip()
        updateMouseCapture()
        return newPresentation.id
    }

    private func scheduleExpiry() {
        presentationTimerTask?.cancel()
        guard let presentation else { return }
        let id = presentation.id
        let remaining = max(0, presentationRemaining)
        presentationResumedAt = Date()
        presentationTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.beginDismiss(id: id, reason: .timeout)
        }
    }

    private func setToastHovered(_ hovered: Bool) {
        guard let presentation, dismissingPresentationID != presentation.id else { return }
        guard hovered != isToastHovered else { return }
        isToastHovered = hovered
        guard !cardCopied else { return }

        if hovered {
            presentationRemaining -= Date().timeIntervalSince(presentationResumedAt)
            presentationTimerTask?.cancel()
            isToastPaused = true
        } else {
            isToastPaused = false
            scheduleExpiry()
        }
    }

    private func beginDismiss(id: UUID, reason: FlowBarDismissReason) {
        guard presentation?.id == id, dismissingPresentationID != id else { return }
        dismissingPresentationID = id
        presentationTimerTask?.cancel()
        presentationTimerTask = nil
        removeKeyMonitors()
        morphingUntil = Date().addingTimeInterval(Self.exitContentDuration + Self.morphDuration)

        let onEnd = presentationOnEnd
        presentationOnEnd = nil

        presentationCleanupTask?.cancel()
        presentationCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.exitContentDuration + Self.morphDuration))
            guard !Task.isCancelled, let self, self.presentation?.id == id else { return }
            self.finishPresentation()
        }

        onEnd?(reason)
    }

    /// Drops the current presentation without the exit morph (used when a newer one replaces it).
    private func endPresentationImmediately(reason: FlowBarDismissReason) {
        presentationTimerTask?.cancel()
        presentationTimerTask = nil
        presentationCleanupTask?.cancel()
        presentationCleanupTask = nil
        removeKeyMonitors()
        let onEnd = presentationOnEnd
        presentationOnEnd = nil
        presentation = nil
        dismissingPresentationID = nil
        onEnd?(reason)
    }

    private func finishPresentation() {
        presentation = nil
        dismissingPresentationID = nil
        presentationFrameInPanel = .zero
        isToastPaused = false
        isToastHovered = false
        cardCopied = false
        isPillSuppressed = false
        tracker.setFastPolling(false)
        recomputeState(force: true)
    }

    // MARK: - Key monitors (no-textbox card)

    private func installKeyMonitors() {
        removeKeyMonitors()
        let handler: (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            return MainActor.assumeIsolated { self.handleCardKey(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            _ = handler(event)
        }) {
            keyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            handler(event) ? nil : event
        }) {
            keyMonitors.append(local)
        }
    }

    private func removeKeyMonitors() {
        for monitor in keyMonitors {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitors.removeAll()
    }

    private func handleCardKey(_ event: NSEvent) -> Bool {
        guard let presentation, case .card = presentation.kind,
            dismissingPresentationID != presentation.id
        else { return false }

        if event.keyCode == 53 {  // Esc
            beginDismiss(id: presentation.id, reason: .closed)
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 8, flags == .command, isToastHovered {  // ⌘C while hovered
            copyCardText()
            return true
        }
        return false
    }

    // MARK: - Mouse tracking

    private func pillScreenRect() -> CGRect? {
        guard let panel else { return nil }
        let size = FlowBarMetrics.pillSize(for: state)
        let frame = panel.frame
        return CGRect(
            x: frame.midX - size.width / 2,
            y: frame.minY + FlowBarMetrics.bottomInset,
            width: size.width,
            height: size.height
        )
    }

    private func presentationScreenRect() -> CGRect? {
        guard let panel, presentation != nil, presentationFrameInPanel != .zero else { return nil }
        let frame = panel.frame
        let rect = presentationFrameInPanel
        return CGRect(
            x: frame.minX + rect.minX,
            y: frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func pillHotRect() -> CGRect? {
        guard presentation == nil, state != .hidden, let pill = pillScreenRect() else { return nil }
        let extra: CGFloat = state == .ready ? 12 : 0
        return pill.insetBy(dx: -(10 + extra), dy: -6)
    }

    private func trackerDidMove(to point: NSPoint) {
        if updateHover(at: point) {
            recomputeState()
        }
    }

    /// Re-evaluates click-through and hover flags without touching the state machine.
    private func updateMouseCapture() {
        _ = updateHover(at: NSEvent.mouseLocation)
    }

    /// Returns true when a flag that feeds the state machine or tooltip changed.
    private func updateHover(at point: NSPoint) -> Bool {
        let pillHot = pillHotRect()
        let toastRect = presentationScreenRect()
        let insidePill = pillHot?.contains(point) ?? false
        let insideToast = toastRect?.contains(point) ?? false
        var changed = false

        if let panel {
            let shouldIgnore = !(insidePill || insideToast)
            if panel.ignoresMouseEvents != shouldIgnore {
                panel.ignoresMouseEvents = shouldIgnore
            }
        }

        // Pointer over the pill itself (READY hover fill, hands-free tooltip)
        let overPill = presentation == nil && state != .hidden && (pillScreenRect()?.contains(point) ?? false)
        if overPill != isPointerOverPill {
            isPointerOverPill = overPill
            changed = true
        }

        // Hands-free buttons
        var button: FlowBarHoveredButton?
        if state == .activeHandsFree, presentation == nil, let pill = pillScreenRect() {
            let inset = max(0, (pill.width - FlowBarMetrics.popoContentWidth) / 2)
            let size = FlowBarMetrics.buttonSize
            let cancel = CGRect(x: pill.minX + inset, y: pill.midY - size / 2, width: size, height: size)
            let finish = CGRect(x: pill.maxX - inset - size, y: pill.midY - size / 2, width: size, height: size)
            if cancel.insetBy(dx: -2, dy: -4).contains(point) {
                button = .cancel
            } else if finish.insetBy(dx: -2, dy: -4).contains(point) {
                button = .finish
            }
        }
        if button != hoveredButton {
            hoveredButton = button
            changed = true
        }

        // READY: debounce 100 ms on the way in, leave immediately
        let idleHover = insidePill && (state == .resting || state == .ready)
        if idleHover {
            if !isHoveringHotArea, hoverTask == nil {
                hoverTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    self.hoverTask = nil
                    self.isHoveringHotArea = true
                    self.recomputeState()
                }
            }
        } else {
            hoverTask?.cancel()
            hoverTask = nil
            if isHoveringHotArea {
                isHoveringHotArea = false
                changed = true
            }
        }

        setToastHovered(insideToast)
        return changed
    }

    // MARK: - Panel

    private func buildPanel() {
        guard panel == nil else { return }
        guard let screen = Self.cursorScreen() ?? RecorderScreenResolver.resolve() else {
            logger.error("Flow Bar panel not created: no screen available")
            return
        }
        let newPanel = FlowBarPanel(frame: FlowBarPanel.frame(on: screen))
        let host = FlowBarHostingView(rootView: FlowBarView(controller: self, dictation: FlowDictationState.shared))
        host.controller = self
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: FlowBarPanel.panelSize)
        host.autoresizingMask = [.width, .height]
        newPanel.contentView = host
        newPanel.orderFrontRegardless()
        panel = newPanel
        hostingView = host
        tracker.panel = newPanel
    }

    private func destroyPanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        hostingView = nil
        tracker.panel = nil
    }

    private func startScreenTimer() {
        screenTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.followCursorScreen(force: false)
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        screenTimer = timer
    }

    private static func cursorScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
    }

    private func followCursorScreen(force: Bool) {
        guard let panel else { return }
        let now = Date()
        // Never move mid-morph.
        if !force, now < morphingUntil || now.timeIntervalSince(stateChangedAt) < 0.15 {
            return
        }
        guard let screen = Self.cursorScreen() ?? RecorderScreenResolver.resolve() else { return }
        let target = FlowBarPanel.frame(on: screen)
        guard panel.frame != target else { return }
        let distance = hypot(target.midX - panel.frame.midX, target.minY - panel.frame.minY)
        panel.setFrame(target, display: true, animate: distance < 100)
    }

    private func repositionPanel(animated: Bool) {
        guard let panel, let screen = Self.cursorScreen() ?? RecorderScreenResolver.resolve() else { return }
        let target = FlowBarPanel.frame(on: screen)
        if panel.frame != target {
            panel.setFrame(target, display: true, animate: animated)
        }
    }
}

// MARK: - Menu helper

/// Retains a closure for an NSMenuItem (menu item targets are weak).
final class FlowBarMenuAction: NSObject {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        MainActor.assumeIsolated {
            handler()
        }
    }

    @MainActor
    static func item(title: String, handler: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = FlowBarMenuAction(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(FlowBarMenuAction.invoke(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.isEnabled = true
        return item
    }
}
