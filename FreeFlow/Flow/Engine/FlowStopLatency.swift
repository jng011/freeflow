import Foundation
import os

/// Logs each step from releasing the key to the text landing, measured from the stop:
/// `log show --predicate 'category == "StopLatency"'`.
@MainActor
enum FlowStopLatency {
    private static let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "StopLatency")
    private static var stoppedAt: TimeInterval?
    private static var marks: [String] = []

    static func stopped() {
        stoppedAt = ProcessInfo.processInfo.systemUptime
        marks = []
    }

    static func mark(_ step: String) {
        guard let stoppedAt else { return }
        marks.append("\(step)=\(Int(((ProcessInfo.processInfo.systemUptime - stoppedAt) * 1000).rounded()))ms")
    }

    /// Writes the line when the paste is posted (or the dictation ends without one).
    static func finish(_ step: String) {
        guard stoppedAt != nil else { return }
        mark(step)
        logger.notice("\(marks.joined(separator: " "), privacy: .public)")
        stoppedAt = nil
        marks = []
    }
}
