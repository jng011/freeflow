import AppKit
import Carbon
import CoreGraphics
import Foundation

extension FlowTipLedger.Tip {
    /// Warning shown when another app's Secure Keyboard Entry blocks our event tap.
    static let secureInputBlocked = FlowTipLedger.Tip(id: "secureInputBlocked", maxShows: nil, minInterval: 10 * 60)
}

/// Watches for Secure Keyboard Entry (password fields, 1Password, Terminal). While it is on,
/// macOS stops delivering key events to our global event tap, so the fn shortcut silently
/// does nothing. Polls every ~2 s and shows a Flow Bar warning naming the app that holds it.
@MainActor
final class FlowSecureInputMonitor {
    static let shared = FlowSecureInputMonitor()

    private let pollInterval: UInt64 = 2_000_000_000
    /// Consecutive "on" polls required before warning (ignores brief password-field focus).
    private let requiredOnPolls = 2

    private var pollTask: Task<Void, Never>?
    private var consecutiveOnPolls = 0
    /// PID we already warned about (or skipped due to rate limit) for the current secure session.
    private var handledPID: pid_t?

    private init() {}

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(nanoseconds: self?.pollInterval ?? 2_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        consecutiveOnPolls = 0
        handledPID = nil
    }

    private func poll() {
        guard IsSecureEventInputEnabled() else {
            consecutiveOnPolls = 0
            handledPID = nil
            return
        }

        consecutiveOnPolls += 1
        guard consecutiveOnPolls >= requiredOnPolls else { return }

        let pid = Self.secureInputOwnerPID()
        // Same holder as last time: already handled for this session.
        if let pid, pid == handledPID { return }
        if pid == nil, handledPID != nil { return }
        // Our own app holding it (e.g. our own secure field) can't block our tap meaningfully.
        if let pid, pid == ProcessInfo.processInfo.processIdentifier { return }

        handledPID = pid ?? -1

        let tip = FlowTipLedger.Tip.secureInputBlocked
        guard FlowTipLedger.isEligible(tip, respectingSuggestions: false) else { return }
        FlowTipLedger.markShown(tip)

        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "Another app"
        FlowBarController.shared.showToast(FlowBarToast(
            style: .standard,
            title: "Shortcuts are blocked",
            body: "\(app) has Secure Keyboard Entry on, so Free Flow can't hear your key. Close it or quit and reopen \(app).",
            isWarning: true,
            duration: 10
        ))
    }

    /// PID of the process holding Secure Event Input, from the window server session dictionary.
    private static func secureInputOwnerPID() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        if let pid = session["kCGSSessionSecureInputPID"] as? Int, pid > 0 { return pid_t(pid) }
        if let pid = session["kCGSSessionSecureInputPID"] as? NSNumber, pid.intValue > 0 { return pid_t(pid.intValue) }
        return nil
    }
}
