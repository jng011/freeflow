import Foundation

/// Style buckets used by AI cleanup style presets (Settings, AI Cleanup).
enum FlowStyleCategory: String, Codable, CaseIterable {
    case personal, work, email, other
}

/// Where a dictation landed, derived from the frontmost app and (for browsers) the page URL.
enum FlowAppCategory: String, Codable, CaseIterable {
    case ai, email, work, personal, document, other

    /// Style bucket for cleanup. AI apps get no style flourish.
    var styleCategory: FlowStyleCategory? {
        switch self {
        case .email: return .email
        case .work: return .work
        case .personal: return .personal
        case .document, .other: return .other
        case .ai: return nil
        }
    }

    /// True for the category that contains terminal apps. Use `FlowAppCategory.isTerminal(bundleID:)`
    /// to test a specific app.
    var isTerminal: Bool { self == .ai }

    static func isTerminal(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return Rules.terminalBundleIDs.contains(id)
    }

    static func classify(bundleID: String?, appName: String?, url: String?) -> FlowAppCategory {
        guard let rawBundle = bundleID, !rawBundle.isEmpty else { return .other }
        let bundle = rawBundle.lowercased()
        let name = (appName ?? "").lowercased()
        let (host, hostPath) = normalizedURL(url)

        func hostMatches(_ candidates: [String]) -> Bool {
            guard !host.isEmpty else { return false }
            for candidate in candidates {
                if candidate.contains("/") {
                    if hostPath.hasPrefix(candidate) || hostPath.hasPrefix("www." + candidate) { return true }
                } else if host == candidate || host.hasSuffix("." + candidate) || host.hasPrefix(candidate) {
                    return true
                }
            }
            return false
        }

        // 1. AI
        if Rules.aiBundleIDs.contains(bundle) || hostMatches(Rules.aiHosts) { return .ai }
        // 2. Email
        if Rules.emailBundleIDs.contains(bundle) || hostMatches(Rules.emailHosts) { return .email }
        // 3. Work (substring match on bundle id, app name and URL)
        for needle in Rules.workSubstrings {
            if bundle.contains(needle) || name.contains(needle) || (!hostPath.isEmpty && hostPath.contains(needle)) {
                return .work
            }
        }
        // 4. Personal
        if Rules.personalBundleIDs.contains(bundle) || hostMatches(Rules.personalHosts) { return .personal }
        // 5. Document
        if Rules.documentBundleIDs.contains(bundle)
            || Rules.documentBundlePrefixes.contains(where: { bundle.hasPrefix($0) })
            || hostMatches(Rules.documentHosts) {
            return .document
        }
        return .other
    }

    /// Returns the lowercased host and "host/path" for a URL string that may lack a scheme.
    private static func normalizedURL(_ string: String?) -> (host: String, hostPath: String) {
        guard var raw = string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return ("", "")
        }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let components = URLComponents(string: raw), let host = components.host, !host.isEmpty else {
            return ("", "")
        }
        let path = components.path
        return (host, host + path)
    }

    private enum Rules {
        static let terminalBundleIDs: Set<String> = [
            "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
        ]

        static let aiBundleIDs: Set<String> = [
            "com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop",
            "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.microsoft.vscode",
            "ai.perplexity.perplexity-mac", "dev.warp.warp-stable", "com.mitchellh.ghostty", "com.apple.terminal",
            "com.googlecode.iterm2", "net.kovidgoyal.kitty", "org.alacritty", "co.zeit.hyper",
        ]
        static let aiHosts: [String] = [
            "chatgpt.com", "claude.ai", "gemini.google.com", "perplexity.ai", "www.perplexity.ai", "cursor.com",
            "lovable.dev", "v0.dev", "bolt.new", "replit.com", "openrouter.ai", "t3.chat",
            "notebooklm.google.com", "aistudio.google.com", "copilot.microsoft.com", "chat.deepseek.com", "grok.com",
        ]

        static let emailBundleIDs: Set<String> = [
            "com.apple.mail", "com.microsoft.outlook", "com.google.gmail", "com.superhuman.electron",
            "com.mimestream.mimestream", "org.mozilla.thunderbird", "com.readdle.sparkdesktop",
            "com.readdle.smartemail-mac", "com.frontapp.front", "com.hey.app.desktop", "io.canarymail.mac",
            "it.bloop.airmail2",
        ]
        static let emailHosts: [String] = [
            "mail.google.com", "mail.superhuman.com", "outlook.live.com", "outlook.office.com",
            "outlook.office365.com", "app.hey.com", "app.fastmail.com", "mail.proton.me", "mail.yahoo.com",
        ]

        static let workSubstrings: [String] = [
            "com.tinyspeck.slackmacgap", "slack", "com.microsoft.teams", "teams.microsoft.com", "us.zoom.xos",
            "zoom.us", "webex", "linkedin.com", "chat.google.com", "meet.google.com", "loom.com", "intercom",
            "mattermost", "zulip",
        ]

        static let personalBundleIDs: Set<String> = [
            "com.apple.mobilesms", "net.whatsapp.whatsapp", "ru.keepcoder.telegram",
            "org.whispersystems.signal-desktop", "com.hnc.discord", "com.discordapp.discord",
            "com.facebook.archon", "im.beeper", "com.tencent.xinwechat",
        ]
        static let personalHosts: [String] = [
            "web.whatsapp.com", "messenger.com", "discord.com", "instagram.com", "x.com", "twitter.com",
            "facebook.com", "reddit.com", "messages.google.com", "web.telegram.org",
        ]

        static let documentBundleIDs: Set<String> = [
            "notion.id", "com.microsoft.word", "com.microsoft.excel", "com.microsoft.powerpoint",
            "com.apple.iwork.pages", "com.apple.iwork.numbers", "com.apple.iwork.keynote", "com.apple.notes",
            "md.obsidian", "net.shinyfrog.bear", "com.linear", "com.figma.desktop", "com.apple.dt.xcode",
            "com.apple.textedit", "com.craft.craft",
        ]
        static let documentBundlePrefixes: [String] = ["com.jetbrains"]
        static let documentHosts: [String] = [
            "notion.so", "docs.google.com", "sheets.google.com", "slides.google.com", "linear.app", "figma.com",
            "coda.io", "dropbox.com/paper",
        ]
    }
}
