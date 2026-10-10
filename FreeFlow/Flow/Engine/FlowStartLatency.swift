import Foundation
import os

/// Logs how long each step of starting a dictation takes, measured from the key press:
/// `log show --predicate 'category == "StartLatency"'`.
@MainActor
enum FlowStartLatency {
    private static let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "StartLatency")
    private static var pressedAt: TimeInterval?
    private static var marks: [String] = []

    static func keyDown(eventTime: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        pressedAt = eventTime
        marks = ["dispatched=\(ms(now - eventTime))"]
    }

    static func mark(_ step: String) {
        guard let pressedAt else { return }
        marks.append("\(step)=\(ms(ProcessInfo.processInfo.systemUptime - pressedAt))")
    }

    /// Writes the line once the first audio arrives (or the press ends without it).
    static func finish(_ step: String) {
        guard pressedAt != nil else { return }
        mark(step)
        logger.notice("\(marks.joined(separator: " "), privacy: .public)")
        pressedAt = nil
        marks = []
    }

    private static func ms(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }
}
