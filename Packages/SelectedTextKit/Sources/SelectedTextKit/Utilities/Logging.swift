//
//  Logging.swift
//  SelectedTextKit
//
//  Created by tisfeng on 2025/9/5.
//

import Foundation
import os.log

private let logger = Logger(
    subsystem: "com.izual.SelectedTextKit", category: "main")

/// Shared date formatter for timestamps
private let sharedDateFormatter = DateFormatter()

/// Generate high precision timestamp with microseconds
public var logTimestamp: String {
    let now = Date()
    let timeInterval = now.timeIntervalSince1970
    let microseconds = Int((timeInterval.truncatingRemainder(dividingBy: 1)) * 1_000_000)

    sharedDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let dateString = sharedDateFormatter.string(from: now)

    return String(format: "%@.%06d", dateString, microseconds)
}

/// Truncate user text for logs while preserving enough context for debugging.
func truncatedTextForLog(
    _ text: String,
    leadingWordCount: Int = 10,
    trailingWordCount: Int = 10
) -> String {
    let words = text.split(whereSeparator: { $0.isWhitespace })
    let maximumWordCount = leadingWordCount + trailingWordCount

    guard words.count > maximumWordCount else {
        return text
    }

    let leadingWords = words.prefix(leadingWordCount).joined(separator: " ")
    let trailingWords = words.suffix(trailingWordCount).joined(separator: " ")

    return "\(leadingWords) … \(trailingWords)"
}

/// Log info message with timestamp
func logInfo(_ message: String) {
    logger.info("[\(logTimestamp)] \(message)")
}

/// Log error message with timestamp
func logError(_ message: String) {
    logger.error("[\(logTimestamp)] \(message)")
}
