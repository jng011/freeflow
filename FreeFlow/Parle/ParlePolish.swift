import AppKit
import ApplicationServices
import os

// Small touches that make dictation feel finished, modeled on what Free Flow does
// quietly: keep AI cleanup honest, fit text to the cursor, notice when a paste had
// nowhere to go, and notice a microphone that is sending nothing.

// MARK: - Cleanup guard

/// Rejects AI cleanup output that clearly isn't a cleaned-up version of what was
/// said (the model answered, chatted, or rewrote it), so the raw words get pasted.
enum ParleCleanupGuard {
    private static let chattyOpenings = [
        "sure", "here is", "here's", "certainly", "of course", "okay, here", "i've cleaned", "as an ai",
    ]

    static func accepts(input: String, output: String) -> Bool {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let lowered = cleaned.lowercased()
        let inputLowered = input.lowercased()
        // A chatty opening the speaker didn't say means the model replied instead of cleaning.
        for opening in chattyOpenings where lowered.hasPrefix(opening) && !inputLowered.hasPrefix(opening) {
            return false
        }
        // Length must stay close to what was said. Fillers and "scratch that" shrink
        // text legitimately, so the lower bound is generous; very short inputs skip it.
        let inputWords = WordCounter.count(in: input)
        guard inputWords >= 8 else { return true }
        let ratio = Double(WordCounter.count(in: cleaned)) / Double(inputWords)
        if ratio > 1.35 { return false }
        if ratio >= 0.45 { return true }
        // Much shorter: fine for a short one when it only kept the speaker's own words (a
        // correction or "never mind" took the rest back), not when it answered in new ones.
        // A long dictation never legitimately loses over half; that is the model treating
        // one "scrap that" as "delete everything before it" (seen with Gemini 3.5 Flash-Lite).
        guard inputWords < 30 else { return false }
        return sharedWordFraction(of: cleaned, in: input) >= 0.8
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func sharedWordFraction(of output: String, in input: String) -> Double {
        let outputWords = words(output)
        guard !outputWords.isEmpty else { return 0 }
        let inputWords = Set(words(input))
        return Double(outputWords.filter { inputWords.contains($0) }.count) / Double(outputWords.count)
    }
}

// MARK: - Cursor context

/// Reads the focused text field through Accessibility, quickly, only at paste time.
@MainActor
enum ParleCaret {
    private static let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "Caret")

    /// Terminals report their whole scrollback as one value; leave them alone.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
    ]
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField",
    ]

    struct Context {
        let isEditable: Bool
        let isSecure: Bool
        /// Up to a few characters before and after the caret, when readable.
        let before: String?
        let after: String?
    }

    static var frontmostIsTerminal: Bool {
        guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return terminalBundleIDs.contains(id)
    }

    private static var prefetched: (context: Context?, pid: pid_t, at: Date)?

    /// Reads the caret context during the post-release tail (the app is idle then), so the
    /// paste doesn't pay 60-90 ms of Accessibility calls after cleanup returns.
    static func prefetch() {
        guard !frontmostIsTerminal, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            prefetched = nil
            return
        }
        prefetched = (focusedContext(), pid, Date())
    }

    /// The prefetched context while the same app is still in front (and it's recent), else a fresh read.
    static func contextForPaste() -> Context? {
        defer { prefetched = nil }
        if let cached = prefetched, Date().timeIntervalSince(cached.at) < 15,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == cached.pid
        {
            return cached.context
        }
        return focusedContext()
    }

    /// nil when Accessibility isn't available or nothing answered in time.
    static func focusedContext() -> Context? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
            let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return Context(isEditable: false, isSecure: false, before: nil, after: nil) }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)

        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute) ?? ""
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        var editableAncestor: CFTypeRef?
        let insideEditable = AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editableAncestor) == .success
            && editableAncestor != nil
        // Browsers and Electron apps (Chrome, Docs, Slack) mark typeable areas these ways.
        let editable = editableRoles.contains(role) || settable.boolValue || insideEditable
            || role == "AXWebArea" || (boolAttribute(element, "AXEditable") ?? false)
        // An element we can't identify is "unknown", not "nowhere to type".
        if role.isEmpty { return nil }

        guard editable, !isSecure, let value = stringAttribute(element, kAXValueAttribute) else {
            return Context(isEditable: editable, isSecure: isSecure, before: nil, after: nil)
        }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
            let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return Context(isEditable: true, isSecure: false, before: nil, after: nil) }
        var range = CFRange()
        AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)

        let ns = value as NSString
        let start = max(0, min(range.location, ns.length))
        let end = max(start, min(range.location + range.length, ns.length))
        let before = ns.substring(with: NSRange(location: max(0, start - 3), length: start - max(0, start - 3)))
        let after = ns.substring(with: NSRange(location: end, length: min(3, ns.length - end)))
        return Context(isEditable: true, isSecure: false, before: before, after: after)
    }

    /// Fits dictated text to the text around the caret: a space where words would
    /// touch, lowercase when continuing a sentence, no stray period before more text.
    static func fit(_ text: String, before: String?, after: String?, defaultTrailingSpace: Bool) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else { return text }

        if let before, let last = before.last {
            let lastMeaningful = before.trimmingCharacters(in: .whitespaces).last
            if !last.isWhitespace && !"([{\"'“‘/-".contains(last) {
                result = " " + result
            }
            if let lastMeaningful, !".!?:\n".contains(lastMeaningful) {
                result = lowercasingFirstWordIfCommon(result)
            }
        }

        if let after, let next = after.first {
            if next.isLetter || next.isNumber {
                if next.isLowercase, result.hasSuffix("."), !result.hasSuffix("..") {
                    result.removeLast()
                }
                result += " "
            }
            // Space, newline or punctuation already follows: add nothing.
        } else if defaultTrailingSpace {
            result += " "
        }
        return result
    }

    /// "Going" -> "going" mid-sentence, but never "I", acronyms, or names.
    private static func lowercasingFirstWordIfCommon(_ text: String) -> String {
        let leading = text.prefix { $0 == " " }
        let body = text.dropFirst(leading.count)
        let word = body.prefix { $0.isLetter || $0 == "'" || $0 == "’" }
        guard word.count > 1, let first = word.first, first.isUppercase,
            word.dropFirst().allSatisfy({ $0.isLowercase || $0 == "'" || $0 == "’" }),
            !word.hasPrefix("I'"), !word.hasPrefix("I’")
        else { return text }
        let lowered = word.lowercased()
        // Names aren't in the dictionary in lowercase, so they keep their capital.
        let misspelled = NSSpellChecker.shared.checkSpelling(of: lowered, startingAt: 0)
        guard misspelled.location == NSNotFound else { return text }
        return String(leading) + lowered + body.dropFirst(word.count)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }
}

// MARK: - Dead microphone

/// Warns when the microphone delivers pure digital silence (muted interface, dead
/// Bluetooth mic, wrong input), which real rooms never produce.
@MainActor
final class ParleMicWatch {
    private static let silenceFloorDb: Float = -115   // recorder floor is -120 dB; rooms sit well above -100
    private static let warnAfter: TimeInterval = 5
    /// Silence since the start of the dictation for this long: the microphone isn't working.
    private static let escalateAfter: TimeInterval = 15
    private static let pollInterval: Duration = .milliseconds(250)

    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - peak: Latest peak level in dBFS.
    ///   - onSilenceChange: true when the warning fires, false when audio comes back.
    func start(
        peak: @escaping @MainActor () -> Float?,
        onSilenceChange: (@MainActor (Bool) -> Void)? = nil
    ) {
        stop()
        task = Task { @MainActor in
            let startedAt = Date()
            var silentSince: Date?
            var heardAudio = false
            var warned = false
            var escalated = false
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                let level = peak() ?? -160
                if level <= Self.silenceFloorDb {
                    let since = silentSince ?? Date()
                    silentSince = since
                    if !warned, Date().timeIntervalSince(since) >= Self.warnAfter {
                        warned = true
                        onSilenceChange?(true)
                        FlowBarController.shared.showToast(
                            FlowBarToast(style: .mini, title: "No audio received", icon: .mic, duration: 4)
                        )
                    }
                    if !escalated, !heardAudio, Date().timeIntervalSince(startedAt) >= Self.escalateAfter {
                        escalated = true
                        FlowBarController.shared.showToast(
                            FlowBarToast(
                                style: .standard,
                                title: "Microphone is not working",
                                body: "We aren't receiving any audio. Check your mic or pick another one.",
                                isError: true,
                                actionTitle: "Choose microphone",
                                action: {
                                    FlowNavigator.shared.presentSettings(.general, dialog: .microphone)
                                },
                                duration: 8
                            )
                        )
                    }
                } else {
                    heardAudio = true
                    if warned {
                        warned = false
                        onSilenceChange?(false)
                    }
                    silentSince = nil
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
