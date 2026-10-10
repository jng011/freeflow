import Foundation

/// Every new UserDefaults key used by the Flow UI. Existing keys keep their old names.
enum FlowKeys {
    static let showBarAlways = "FlowShowBarAlways"  // Bool, default true
    static let barSnoozeUntil = "FlowBarSnoozeUntil"  // Double epoch seconds, default 0
    static let barEdge = "FlowBarEdge"  // String "bottom" (only bottom implemented)
    static let selectedLanguages = "FlowSelectedLanguages"  // [String] whisper codes, default [] (= follow SelectedLanguage)
    static let notifySuggestions = "FlowNotifySuggestions"  // Bool true
    static let notifyMilestones = "FlowNotifyMilestones"  // Bool true
    static let processingDelayNotice = "FlowProcessingDelayNotice"  // Bool true
    static let autoCleanupLevel = "FlowAutoCleanupLevel"  // String none|light|medium|high, default "light"
    static let stylePreferences = "FlowStylePreferences"  // JSON [FlowStyleCategory.rawValue: FlowStylePreset.rawValue]
    static let cleanupCustomRules = "FlowCleanupCustomRules"  // String, default ""
    static let pressEnterCommand = "FlowPressEnterCommand"  // Bool false
    static let pressEnterPromptShown = "FlowPressEnterPromptShown"  // Bool false
    static let contextAwareness = "FlowContextAwareness"  // Bool true
    static let dictionarySort = "FlowDictionarySort"  // String starred|newest|oldest|alpha, default "newest"
    static let soundPack = "FlowSoundPack"  // String FlowSoundPack.rawValue, default "default"
}

/// Keys used only by the settings and onboarding screens.
enum FlowSettingsPrivateKeys {
    /// Value of ParleCleanupAutoEnabled before the cleanup level was set to None.
    static let previousLiveCleanup = "FlowPrevLiveCleanup"
    /// Last onboarding page the person reached, so a relaunch resumes there.
    static let onboardingPage = "FlowOnboardingPage"
}

/// Existing keys (owned by older code) that the Flow settings read and write.
enum FlowLegacyKeys {
    static let selectedLanguage = "SelectedLanguage"
    static let liveCleanup = "ParleCleanupAutoEnabled"
    static let displayName = "dashboardDisplayName"
    static let skipShortEnhancement = "SkipShortEnhancement"
    static let shortEnhancementWordThreshold = "ShortEnhancementWordThreshold"
    static let openRouterSelectedModel = "OpenRouterSelectedModel"
    static let restoreClipboard = "restoreClipboardAfterPaste"
    static let clipboardRestoreDelay = "clipboardRestoreDelay"
    static let vadEnabled = "IsVADEnabled"
    static let prewarmOnWake = "PrewarmModelOnWake"
    static let transcriptionPrompt = "TranscriptionPrompt"
    static let primaryShortcutMode = "primaryRecordingShortcutMode"
    static let secondaryShortcutMode = "secondaryRecordingShortcutMode"
    static let statsSnapshotStale = "dashboardStatsSnapshotStale"
}

/// Rows the owner chose to hide (SETTINGS-DECISIONS.md section 10). The code behind
/// them is built and compiled; flip a flag to bring a row back.
enum FlowSettingsFeatures {
    /// Owner answer 1: English only, so no multi-select Languages dialog and no auto-detect row.
    static let multiLanguage = false
    /// Owner answer 11: the App Language dropdown is dropped.
    static let appLanguageRow = false
}

enum FlowStylePreset: String, Codable, CaseIterable {
    case formal, casual, veryCasual, excited
}

enum FlowDefaults {
    /// Registers defaults for every Flow key. Safe to call more than once.
    static func register() {
        let defaultStyles = Dictionary(
            uniqueKeysWithValues: FlowStyleCategory.allCases.map { ($0.rawValue, FlowStylePreset.formal.rawValue) }
        )
        let stylesJSON =
            (try? JSONEncoder().encode(defaultStyles)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        UserDefaults.standard.register(defaults: [
            FlowKeys.showBarAlways: true,
            FlowKeys.barSnoozeUntil: 0.0,
            FlowKeys.barEdge: "bottom",
            FlowKeys.selectedLanguages: [String](),
            FlowKeys.notifySuggestions: true,
            FlowKeys.notifyMilestones: true,
            FlowKeys.processingDelayNotice: true,
            FlowKeys.autoCleanupLevel: "light",
            FlowKeys.stylePreferences: stylesJSON,
            FlowKeys.cleanupCustomRules: "",
            FlowKeys.pressEnterCommand: false,
            FlowKeys.pressEnterPromptShown: false,
            FlowKeys.contextAwareness: true,
            FlowKeys.dictionarySort: "newest",
            FlowKeys.soundPack: "default",
            // Owner answer 4 (SETTINGS-DECISIONS.md section 10): restore the clipboard after 500 ms.
            // Registered here so it only applies when the person never picked a delay.
            FlowLegacyKeys.clipboardRestoreDelay: 0.5,
        ])
    }

    static func stylePreset(for category: FlowStyleCategory) -> FlowStylePreset {
        stylePreferences()[category.rawValue].flatMap(FlowStylePreset.init(rawValue:)) ?? .formal
    }

    static func setStylePreset(_ preset: FlowStylePreset, for category: FlowStyleCategory) {
        var preferences = stylePreferences()
        preferences[category.rawValue] = preset.rawValue
        if let data = try? JSONEncoder().encode(preferences), let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: FlowKeys.stylePreferences)
        }
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    private static func stylePreferences() -> [String: String] {
        let defaults = UserDefaults.standard
        let data: Data?
        if let json = defaults.string(forKey: FlowKeys.stylePreferences) {
            data = json.data(using: .utf8)
        } else {
            data = defaults.data(forKey: FlowKeys.stylePreferences)
        }
        guard let data, let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }
}

/// Writes a setting and tells the rest of the app about it.
enum FlowSettingsWriter {
    static func set(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }
}

// MARK: - Dictation languages

struct FlowLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    let nativeName: String
    var id: String { code }
}

enum FlowLanguageCatalog {
    /// Whisper languages the app already knows (LanguageDictionary), sorted by English name.
    static let all: [FlowLanguage] = {
        let dictionary = LanguageDictionary.forProvider(isMultilingual: true, provider: .whisper)
        return dictionary
            .filter { $0.key != "auto" }
            .map { code, name in
                let native = Locale(identifier: code).localizedString(forLanguageCode: code) ?? name
                return FlowLanguage(code: code, name: name, nativeName: native.capitalized(with: Locale(identifier: code)))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static var autoDetectCount: Int { 99 }

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name ?? LanguageDictionary.all[code] ?? code
    }

    /// The languages the person picked. Falls back to SelectedLanguage when the Flow list is empty.
    static var storedSelection: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: FlowKeys.selectedLanguages) ?? []
        if !stored.isEmpty { return stored }
        let single = UserDefaults.standard.string(forKey: FlowLegacyKeys.selectedLanguage) ?? "en"
        return single == "auto" ? [] : [single]
    }

    static var isAutoDetect: Bool {
        UserDefaults.standard.string(forKey: FlowLegacyKeys.selectedLanguage) == "auto"
            && (UserDefaults.standard.stringArray(forKey: FlowKeys.selectedLanguages) ?? []).count < 2
    }

    /// One language forces that code. Two or more, or auto-detect, send "auto".
    static func save(selection: [String], autoDetect: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(selection, forKey: FlowKeys.selectedLanguages)
        let code: String
        if autoDetect || selection.count != 1 {
            code = "auto"
        } else {
            code = selection[0]
        }
        defaults.set(code, forKey: FlowLegacyKeys.selectedLanguage)
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    /// "Auto-detect (99 languages)", "English · Spanish", or "English, Spanish and 2 more".
    static func summary() -> String {
        if isAutoDetect {
            return "Auto-detect (\(autoDetectCount) languages)"
        }
        let names = storedSelection.map(name(for:))
        if names.isEmpty { return "Auto-detect (\(autoDetectCount) languages)" }
        if names.count <= 3 { return names.joined(separator: " · ") }
        return "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }
}
