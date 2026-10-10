import AppKit
import Foundation

/// Why a dictation was canceled. Only `.user` offers Undo.
enum FlowCancelReason {
    /// Esc, the pill's X, or the menu: the canceled audio can be recovered with Undo.
    case user
    /// Another key pressed during the first moment of push-to-talk: nothing is kept.
    case otherShortcut
    /// A lone tap of the dictation key (hold or double-tap is required): nothing is kept.
    case lonelyTap
    /// The app canceled on its own (for example before pasting the last transcript).
    case system
}

/// The one canceled dictation that Undo can still bring back.
@MainActor
enum FlowCancelUndo {
    struct Pending {
        let transcriptionID: UUID
        let audioURL: URL
        let targetPID: pid_t?
        let bundleID: String?
        let expires: Date
        let timing: FlowDictationTiming?
    }

    /// How long the cancel toast offers Undo.
    static let window: TimeInterval = 5
    /// Late clicks on a toast that is just finishing still count. Hovering the cancel toast
    /// pauses its timer, so the toast (not this clock) is what limits Undo; this only stops a
    /// stale cancel from being revived much later.
    private static let grace: TimeInterval = 60

    private(set) static var pending: Pending?

    static func register(
        transcriptionID: UUID,
        audioURL: URL,
        targetPID: pid_t?,
        bundleID: String?,
        timing: FlowDictationTiming?
    ) {
        pending = Pending(
            transcriptionID: transcriptionID,
            audioURL: audioURL,
            targetPID: targetPID,
            bundleID: bundleID,
            expires: Date().addingTimeInterval(window),
            timing: timing
        )
    }

    /// A new dictation started, so the old one can no longer be undone.
    static func discard() {
        pending = nil
    }

    /// Returns the pending cancel if it is still within the Undo window, and clears it.
    static func take() -> Pending? {
        guard let current = pending else { return nil }
        pending = nil
        guard Date() <= current.expires.addingTimeInterval(grace) else { return nil }
        return current
    }

    /// Brings the app the words were meant for back to the front, if it lost focus.
    static func reactivateTarget(_ pending: Pending) async {
        guard let pid = pending.targetPID,
            let app = NSRunningApplication(processIdentifier: pid),
            !app.isTerminated,
            NSWorkspace.shared.frontmostApplication?.processIdentifier != pid
        else { return }
        app.activate()
        try? await Task.sleep(for: .milliseconds(150))
    }
}
