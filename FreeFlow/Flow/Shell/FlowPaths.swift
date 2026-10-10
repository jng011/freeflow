import Foundation

/// Locations for Flow sidecar files. Nonisolated; safe from any thread.
enum FlowPaths {
    static let bundleFolderName = "com.jaydenghiyam.FreeFlow"

    /// ~/Library/Application Support/com.jaydenghiyam.FreeFlow, created on first access.
    static var appSupport: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent(bundleFolderName, isDirectory: true)
        ensureDirectory(url)
        return url
    }

    /// A file directly inside appSupport.
    static func file(_ name: String) -> URL {
        appSupport.appendingPathComponent(name, isDirectory: false)
    }

    /// appSupport/Recordings, created on first access.
    static var recordings: URL {
        let url = appSupport.appendingPathComponent("Recordings", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    private static func ensureDirectory(_ url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

/// The name used in greetings.
enum FlowUser {
    static let displayNameKey = "dashboardDisplayName"

    /// dashboardDisplayName if set, else the first word of the macOS full name, else "there".
    static var firstName: String {
        let stored = (UserDefaults.standard.string(forKey: displayNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            return stored
        }
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = full.split(whereSeparator: { $0.isWhitespace }).first, !first.isEmpty {
            return String(first)
        }
        return "there"
    }
}
