import AppKit
import CoreGraphics
import Foundation
import os

final class ShortcutMonitor {
    fileprivate enum EventKind {
        case keyDown
        case keyUp
        case flagsChanged
        case mouseDown
        case mouseDragged
        case mouseUp
    }

    private struct ShortcutState {
        var shortcut: Shortcut
        var isDown = false
        var pressedAt: TimeInterval?
        var isInterrupted = false
        var requiresStandaloneRelease = false
        /// Last release of a modifier-only shortcut, to spot a press macOS never reported.
        var releasedAt: TimeInterval?
        /// The press was recovered from the hardware key state, not from an event.
        var recoveredFromHardware = false
    }

    /// macOS coalesces fn (and other modifier) events when the key is tapped fast: a press can
    /// arrive with no release before it, or a release with no press. Within this window of the
    /// last release, the event's own flag state is trusted and the missing half is filled in.
    private static let missedModifierEventWindow: TimeInterval = 0.6

    private var shortcuts: [ShortcutAction: ShortcutState] = [:]
    private var pressedKeyCodes = Set<UInt16>()
    private var suppressedMouseButtons = Set<UInt16>()
    private var interruptibleActions: Set<ShortcutAction> = []
    private var standaloneModifierActions: Set<ShortcutAction> = []
    private var onShortcutDown: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutUp: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
    private var onStandaloneModifierChord: ((ShortcutAction) -> Void)?
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    /// Retries the tap until Accessibility is granted (a fresh install starts without it).
    private var tapRetryTimer: Timer?
    /// fn straight from the keyboard's HID reports; once live, fn events from the tap are ignored.
    private let fnHID = FnHIDMonitor()
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "ShortcutMonitor")

    private static let shortcutInterruptionWindow: TimeInterval = 1.0

    deinit {
        stop()
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        standaloneModifierActions: Set<ShortcutAction> = [],
        onShortcutDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil,
        onStandaloneModifierChord: ((ShortcutAction) -> Void)? = nil
    ) -> Bool {
        stop()

        for (action, shortcut) in shortcuts {
            self.shortcuts[action] = ShortcutState(shortcut: shortcut)
        }

        guard !self.shortcuts.isEmpty else {
            return true
        }

        self.interruptibleActions = interruptibleActions
        self.standaloneModifierActions = standaloneModifierActions
        self.onShortcutDown = onShortcutDown
        self.onShortcutUp = onShortcutUp
        self.onShortcutInterrupted = onShortcutInterrupted
        self.onStandaloneModifierChord = onStandaloneModifierChord

        if self.shortcuts.values.contains(where: { $0.shortcut.keyCode == Self.fnKeyCode }) {
            fnHID.start { [weak self] down, time in self?.handleFnHIDEdge(down: down, eventTime: time) }
        }

        if installEventTap() { return true }
        scheduleTapRetry()
        return false
    }

    private func scheduleTapRetry() {
        tapRetryTimer?.invalidate()
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.eventTap == nil, !self.shortcuts.isEmpty else {
                timer.invalidate()
                self.tapRetryTimer = nil
                return
            }
            if self.installEventTap() {
                self.logger.notice("Global shortcut event tap installed after retry")
                timer.invalidate()
                self.tapRetryTimer = nil
            }
        }
    }

    func updateStandaloneModifierActions(_ actions: Set<ShortcutAction>) {
        standaloneModifierActions = actions
    }

    func stop() {
        stopFnWatch()
        fnHID.stop()
        tapRetryTimer?.invalidate()
        tapRetryTimer = nil
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapRunLoopSource, .commonModes)
            self.eventTapRunLoopSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        shortcuts = [:]
        pressedKeyCodes = []
        suppressedMouseButtons = []
        interruptibleActions = []
        standaloneModifierActions = []
        onShortcutDown = nil
        onShortcutUp = nil
        onShortcutInterrupted = nil
        onStandaloneModifierChord = nil
    }

    private func installEventTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.resetPressedShortcutsAfterTapInterruption()
                if let eventTap = monitor.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress = monitor.handleCGEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            logger.error("Failed to install global shortcut event tap")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create global shortcut event tap run loop source")
            return false
        }

        self.eventTap = eventTap
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard UserSessionInputPolicy.allowsShortcutHandling else {
            clearPressedShortcutState()
            return false
        }

        // Diagnostic: Apple's fn/globe key may report a fast repeat press as a system-defined
        // event (type 14) instead of flagsChanged. Log those to see if double taps go missing there.
        if type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event) {
            logger.notice("raw sysdefined subtype=\(nsEvent.subtype.rawValue, privacy: .public) data1=\(nsEvent.data1, privacy: .public) hw=\(Double(event.timestamp) / 1_000_000_000, privacy: .public)")
        }

        guard let eventKind = EventKind(type) else {
            return false
        }

        let inputCode: UInt16
        switch eventKind {
        case .keyDown, .keyUp, .flagsChanged:
            inputCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        case .mouseDown, .mouseDragged, .mouseUp:
            inputCode = UInt16(clamping: event.getIntegerValueField(.mouseEventButtonNumber))
        }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        if eventKind == .flagsChanged, inputCode == 63 || inputCode == 179 {
            // Raw fn/globe events as macOS hands them over, with the hardware timestamp, to tell
            // a press the system never delivered from one the app dropped.
            let fnDown = modifierFlags.contains(.function)
            logger.notice("raw fn code=\(inputCode, privacy: .public) down=\(fnDown, privacy: .public) hw=\(Double(event.timestamp) / 1_000_000_000, privacy: .public) lag=\((ProcessInfo.processInfo.systemUptime - Double(event.timestamp) / 1_000_000_000) * 1000, privacy: .public)ms")
        }
        if fnHID.isLive, eventKind == .flagsChanged, inputCode == 63 || inputCode == 179 {
            // The HID monitor already delivered this edge, earlier and without coalescing.
            return false
        }
        return handleEvent(
            kind: eventKind,
            inputCode: inputCode,
            modifierFlags: modifierFlags,
            eventTime: ProcessInfo.processInfo.systemUptime
        )
    }

    /// An fn edge from the keyboard itself. Runs through the same path as a flagsChanged
    /// event, with the other modifiers read from the session state.
    private func handleFnHIDEdge(down: Bool, eventTime: TimeInterval) {
        guard UserSessionInputPolicy.allowsShortcutHandling else { return }
        var flags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        if down { flags.insert(.function) } else { flags.remove(.function) }
        _ = handleEvent(kind: .flagsChanged, inputCode: Self.fnKeyCode, modifierFlags: flags, eventTime: eventTime)
    }

    private func resetPressedShortcutsAfterTapInterruption() {
        releasePressedShortcuts(eventTime: ProcessInfo.processInfo.systemUptime)
    }

    private func clearPressedShortcutState() {
        releasePressedShortcuts(eventTime: ProcessInfo.processInfo.systemUptime)
        suppressedMouseButtons.removeAll()
    }

    private func releasePressedShortcuts(eventTime: TimeInterval) {
        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else { continue }
            let shouldDispatchUp = state.isDown && !state.requiresStandaloneRelease
            state.isDown = false
            state.pressedAt = nil
            state.isInterrupted = false
            state.requiresStandaloneRelease = false
            shortcuts[action] = state
            if shouldDispatchUp {
                dispatchShortcutUp(for: action, eventTime: eventTime)
            }
        }
        pressedKeyCodes.removeAll()
    }

    private func handleEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) -> Bool {
        var shouldSuppress: Bool
        switch kind {
        case .mouseDragged:
            shouldSuppress = suppressedMouseButtons.contains(inputCode)
        case .mouseUp:
            shouldSuppress = suppressedMouseButtons.remove(inputCode) != nil
        case .keyDown, .keyUp, .flagsChanged, .mouseDown:
            shouldSuppress = false
        }

        updatePressedKeyCodes(kind: kind, inputCode: inputCode)
        invalidateStandaloneModifierCandidateForKeyboardEvent(
            kind: kind,
            inputCode: inputCode,
            modifierFlags: modifierFlags
        )

        if kind == .keyDown {
            handleShortcutInterruptions(keyCode: inputCode, eventTime: eventTime)
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else {
                continue
            }

            if state.shortcut.isModifierOnly {
                handleModifierOnlyShortcut(
                    action: action,
                    state: state,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags,
                    eventTime: eventTime
                )
                continue
            }

            let transition: ShortcutTransition
            switch state.shortcut.kind {
            case .key:
                transition = transitionForKeyShortcut(
                    state.shortcut,
                    isDown: state.isDown,
                    kind: kind,
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            case .mouseButton:
                transition = transitionForMouseShortcut(
                    state.shortcut,
                    isDown: state.isDown,
                    kind: kind,
                    buttonNumber: inputCode,
                    modifierFlags: modifierFlags
                )
            case .modifierOnly:
                transition = .none
            }

            switch transition {
            case .none:
                break
            case .suppress:
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
            case .keyDown:
                state.isDown = true
                state.pressedAt = eventTime
                state.isInterrupted = false
                shortcuts[action] = state
                if state.shortcut.kind == .mouseButton {
                    suppressedMouseButtons.insert(inputCode)
                }
                shouldSuppress = true
                dispatchShortcutDown(for: action, eventTime: eventTime)
            case .keyUp:
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                if kind != .flagsChanged {
                    shouldSuppress = true
                }
                dispatchShortcutUp(for: action, eventTime: eventTime)
            }
        }

        return shouldSuppress
    }

    private enum ShortcutTransition {
        case none
        case suppress
        case keyDown
        case keyUp
    }

    private func transitionForKeyShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .keyDown:
            guard shortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .keyUp:
            return isDown && keyCode == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(
                modifierFlags,
                forKeyCode: shortcut.keyCode
            )
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .mouseDown, .mouseDragged, .mouseUp:
            return .none
        }
    }

    private func transitionForMouseShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        buttonNumber: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .mouseDown:
            guard shortcut.matchesMouseEvent(
                buttonNumber: buttonNumber,
                modifierFlags: modifierFlags
            ) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .mouseUp:
            return isDown && buttonNumber == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: nil)
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        case .keyDown, .keyUp, .mouseDragged:
            return .none
        }
    }

    private func handleModifierOnlyShortcut(
        action: ShortcutAction,
        state: ShortcutState,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) {
        var state = state

        guard kind == .flagsChanged else {
            return
        }

        if state.isDown {
            if state.recoveredFromHardware, keyCode == state.shortcut.keyCode {
                // The late event for a press already recovered from the hardware state: adopt it
                // instead of reading it as a release.
                state.recoveredFromHardware = false
                shortcuts[action] = state
                if state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) { return }
            }
            if state.shortcut.shouldReleaseModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
                let shouldTrigger =
                    state.requiresStandaloneRelease
                    && !state.isInterrupted
                let shouldDispatchUp = !state.requiresStandaloneRelease
                let pressedAt = state.pressedAt
                // The event says the key is down again: its release was never reported, so
                // this is the release and the next press at once (a fast double tap).
                let pressedAgain = shouldDispatchUp
                    && state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags)
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                state.requiresStandaloneRelease = false
                state.releasedAt = eventTime
                shortcuts[action] = state
                if shouldTrigger, let pressedAt {
                    dispatchShortcutDown(for: action, eventTime: pressedAt)
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                } else if shouldDispatchUp {
                    dispatchShortcutUp(for: action, eventTime: eventTime)
                    if state.shortcut.keyCode == Self.fnKeyCode, !pressedAgain { watchFnHardware(action: action) }
                }
                if pressedAgain {
                    logger.notice("fn release was never reported; treating this event as release + press")
                    state.isDown = true
                    state.pressedAt = eventTime
                    state.releasedAt = nil
                    shortcuts[action] = state
                    dispatchShortcutDown(for: action, eventTime: eventTime)
                }
            }

            return
        }

        // fn with Ctrl already held is prompt mode (Ctrl+fn): still the fn shortcut.
        let fnWithControl = keyCode == 63 && state.shortcut.keyCode == 63 && modifierFlags.contains(.control)
            && state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags.subtracting(.control))
        if state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) || fnWithControl {
            state.isDown = true
            state.pressedAt = eventTime
            state.requiresStandaloneRelease = standaloneModifierActions.contains(action)
            state.isInterrupted = state.requiresStandaloneRelease && !pressedKeyCodes.isEmpty
            shortcuts[action] = state
            if !state.requiresStandaloneRelease {
                dispatchShortcutDown(for: action, eventTime: eventTime)
            }
        } else if keyCode == state.shortcut.keyCode,
            !standaloneModifierActions.contains(action),
            Shortcut.normalizedModifierFlags(modifierFlags, forKeyCode: keyCode).isEmpty,
            let releasedAt = state.releasedAt,
            eventTime - releasedAt <= Self.missedModifierEventWindow
        {
            // A second release right after the last one: the press between them was never
            // reported. It was a quick tap, so deliver it as one.
            logger.notice("fn press was never reported; treating this release as a tap")
            state.releasedAt = eventTime
            shortcuts[action] = state
            dispatchShortcutDown(for: action, eventTime: eventTime)
            dispatchShortcutUp(for: action, eventTime: eventTime)
        }
    }

    // MARK: - fn hardware watch

    /// macOS sometimes never delivers a fast second fn press as an event, although the key
    /// went down (seen in logs: one press, then silence until the double-tap window closed).
    /// Free Flow's helper reads `CGEventSourceKeyState`/`FlagsState` as a backstop; so do we:
    /// for 0.75 s after an fn release, poll the hardware key state every 5 ms and deliver a
    /// press (and its release) that no event reported within 15 ms.
    private static let fnKeyCode: UInt16 = 63
    private static let fnWatchWindow: TimeInterval = 0.75
    private static let fnEventGrace: TimeInterval = 0.015
    private var fnWatchTimer: DispatchSourceTimer?

    private func fnIsDownInHardware() -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(Self.fnKeyCode))
            || CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
    }

    private func watchFnHardware(action: ShortcutAction) {
        fnWatchTimer?.cancel()
        guard !fnHID.isLive else { return }  // HID sees every edge; nothing to recover
        let started = ProcessInfo.processInfo.systemUptime
        var hardwareDownAt: TimeInterval?
        var hardwareUpAt: TimeInterval?
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, var state = self.shortcuts[action] else {
                self?.stopFnWatch()
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let down = self.fnIsDownInHardware()
            if !state.isDown {
                guard now - started <= Self.fnWatchWindow else { self.stopFnWatch(); return }
                guard down else { hardwareDownAt = nil; return }
                let downAt = hardwareDownAt ?? now
                hardwareDownAt = downAt
                guard now - downAt >= Self.fnEventGrace else { return }
                // Down in hardware for 15 ms and no event: the press was lost. Deliver it.
                self.logger.notice("fn press missing from events; recovered from hardware state")
                state.isDown = true
                state.pressedAt = downAt
                state.releasedAt = nil
                state.recoveredFromHardware = true
                self.shortcuts[action] = state
                self.dispatchShortcutDown(for: action, eventTime: downAt)
            } else if state.recoveredFromHardware {
                guard now - started <= 5 else { self.stopFnWatch(); return }
                guard !down else { hardwareUpAt = nil; return }
                let upAt = hardwareUpAt ?? now
                hardwareUpAt = upAt
                guard now - upAt >= Self.fnEventGrace else { return }
                // Its release never arrived as an event either.
                state.isDown = false
                state.pressedAt = nil
                state.recoveredFromHardware = false
                state.releasedAt = upAt
                self.shortcuts[action] = state
                self.dispatchShortcutUp(for: action, eventTime: upAt)
                self.watchFnHardware(action: action)
            } else {
                // A real event took over.
                self.stopFnWatch()
            }
        }
        fnWatchTimer = timer
        timer.resume()
    }

    private func stopFnWatch() {
        fnWatchTimer?.cancel()
        fnWatchTimer = nil
    }

    private func updatePressedKeyCodes(kind: EventKind, inputCode: UInt16) {
        switch kind {
        case .keyDown:
            pressedKeyCodes.insert(inputCode)
        case .keyUp:
            pressedKeyCodes.remove(inputCode)
        case .flagsChanged, .mouseDown, .mouseDragged, .mouseUp:
            break
        }
    }

    private func invalidateStandaloneModifierCandidateForKeyboardEvent(
        kind: EventKind,
        inputCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard kind == .keyDown || kind == .keyUp || kind == .flagsChanged else {
            return
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action],
                state.isDown,
                state.requiresStandaloneRelease,
                !state.isInterrupted
            else {
                continue
            }

            let isReleaseEvent = kind == .flagsChanged
                && state.shortcut.shouldReleaseModifierEvent(
                    keyCode: inputCode,
                    modifierFlags: modifierFlags
                )
            if !isReleaseEvent {
                state.isInterrupted = true
                shortcuts[action] = state
            }
        }
    }

    private func handleShortcutInterruptions(keyCode: UInt16, eventTime: TimeInterval) {
        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return
        }

        for action in standaloneModifierActions {
            guard shortcuts[action]?.shortcut.isModifierOnly == true else { continue }
            onStandaloneModifierChord?(action)
        }

        for action in interruptibleActions {
            guard var state = shortcuts[action],
                state.isDown,
                !state.isInterrupted,
                let pressedAt = state.pressedAt,
                eventTime - pressedAt <= Self.shortcutInterruptionWindow,
                state.shortcut.isInterruptedByAdditionalKeyDown(keyCode: keyCode)
            else {
                continue
            }

            state.isInterrupted = true
            shortcuts[action] = state
            dispatchShortcutInterrupted(for: action, eventTime: eventTime)
        }
    }

    private func dispatchShortcutDown(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutDown] in
            onShortcutDown?(action, eventTime)
        }
    }

    private func dispatchShortcutUp(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutUp] in
            onShortcutUp?(action, eventTime)
        }
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutInterrupted] in
            onShortcutInterrupted?(action, eventTime)
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged,
        CGEventType.otherMouseDown,
        CGEventType.otherMouseDragged,
        CGEventType.otherMouseUp,
    ].reduce(CGEventMask(1) << 14) { mask, type in  // 14: NSSystemDefined (diagnostic, see handleCGEvent)
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}

private extension ShortcutMonitor.EventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        case .otherMouseDown:
            self = .mouseDown
        case .otherMouseDragged:
            self = .mouseDragged
        case .otherMouseUp:
            self = .mouseUp
        default:
            return nil
        }
    }
}
