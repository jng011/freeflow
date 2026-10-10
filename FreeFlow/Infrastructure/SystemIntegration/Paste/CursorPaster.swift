import AppKit
import Carbon
import Foundation
import os

class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "CursorPaster")

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    struct PasteOutcome {
        let result: PasteResult
        let autoLearnGeneration: UInt64?
    }

    private static let prePasteDelay: TimeInterval = 0.015
    private static let pasteShortcutEventDelay: TimeInterval = 0.004
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25
    /// Terminals read the clipboard a beat later than other apps.
    private static let terminalRestoreDelay: TimeInterval = 0.5
    static let pasteByParagraphKey = "ParlePasteByParagraph"

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(_ text: String, keepOnClipboard: Bool = false) -> Task<PasteOutcome, Never> {
        Task { @MainActor in
            await performPasteSession(text, keepOnClipboard: keepOnClipboard)
        }
    }

    @MainActor
    private static func performPasteSession(_ text: String, keepOnClipboard: Bool = false) async -> PasteOutcome {
        let pasteboard = NSPasteboard.general
        // keepOnClipboard: the paste may have had nowhere to go, so leave the words there.
        let shouldRestoreClipboard = !keepOnClipboard && UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        let savedContents = shouldRestoreClipboard ? snapshotClipboard(from: pasteboard) : []
        let sessionID = UUID().uuidString
        let inTerminal = frontmostIsTerminal
        let pasteText = inTerminal ? terminalText(text) : text
        let targetProcessID = AutoLearnSettings.isEnabled
            ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil

        // Words that won't stay on the clipboard are marked transient and concealed so
        // clipboard managers skip them.
        guard
            ClipboardManager.setClipboard(
                pasteText,
                transient: shouldRestoreClipboard,
                concealed: shouldRestoreClipboard,
                sessionID: shouldRestoreClipboard ? sessionID : nil
            )
        else {
            logger.error("Failed to prepare clipboard for paste")
            return PasteOutcome(result: .commandNotPosted, autoLearnGeneration: nil)
        }

        await wait(prePasteDelay)
        await waitForModifierKeysUp()
        let pasteResult = await postPasteCommand()
        await FlowStopLatency.finish("pasted")

        var autoLearnGeneration: UInt64?
        if AutoLearnSettings.isEnabled {
            autoLearnGeneration = await AutoLearnService.shared.pasteDidFinish(
                text: text,
                processID: targetProcessID,
                commandPosted: pasteResult.didPostPasteCommand
            )
        }
        if shouldRestoreClipboard {
            scheduleClipboardRestore(
                savedContents,
                expectedText: pasteText,
                sessionID: sessionID,
                on: pasteboard,
                minimumDelay: inTerminal ? terminalRestoreDelay : minimumClipboardRestoreDelay
            )
        }

        return PasteOutcome(result: pasteResult, autoLearnGeneration: autoLearnGeneration)
    }

    /// Terminal apps where Claude Code / Codex run. One paste only: swapping the
    /// clipboard between quick pastes races the terminal and repeats or drops text.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
    ]

    @MainActor
    private static var frontmostIsTerminal: Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    /// Line breaks become single spaces, so a prompt box gets one clean line.
    static func terminalText(_ text: String) -> String {
        guard UserDefaults.standard.object(forKey: pasteByParagraphKey) as? Bool ?? true else { return text }
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Paragraphs become one line, but lists keep one item per line.
        var result = ""
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result += isListItem(line) || isListItem(lines[index - 1]) ? "\n" : " "
            }
            result += line
        }
        return result
    }

    /// "- item", "• item", "* item", "1. item" or "1) item".
    static func isListItem(_ line: String) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") { return true }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    private static func snapshotClipboard(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                return nil
            }
        }
    }

    @MainActor
    private static func postPasteCommand() async -> PasteResult {
        if PasteMethod.current() == .appleScript {
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        } else {
            return await pasteFromClipboard()
        }
    }

    private static func scheduleClipboardRestore(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard,
        minimumDelay: TimeInterval = minimumClipboardRestoreDelay
    ) {
        let delay = max(
            UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
            minimumDelay
        )

        Task { @MainActor in
            await wait(delay)
            guard pasteboardStillOwnedByPasteSession(pasteboard, expectedText: expectedText, sessionID: sessionID)
            else {
                return
            }
            pasteboard.clearContents()
            if !savedContents.isEmpty {
                pasteboard.writeObjects(pasteboardItems(from: savedContents))
            }
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText
            && pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript(
        "tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode = makeScript(
        "tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    @MainActor
    private static func pasteUsingAppleScript() -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard() async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        return .commandPosted
    }

    /// Waits (up to 400 ms) until no modifier key is held, so a still-held fn or control
    /// key doesn't turn Cmd+V into a different shortcut.
    private static func waitForModifierKeysUp() async {
        let modifierMask: CGEventFlags = [
            .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn,
        ]
        let deadline = Date().addingTimeInterval(0.4)
        while !CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty,
            Date() < deadline
        {
            await wait(0.01)
        }
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Send Key

    static func performSendKey(_ key: FinishAndSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags = .maskCommand
        }

        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
