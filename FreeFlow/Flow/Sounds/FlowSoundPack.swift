import Foundation
import os

/// One event that can make a sound. Raw values match the generated file names
/// (`flow_<pack>_<slot>.wav`).
enum FlowSoundSlot: String, CaseIterable {
    case start
    case stop
    case lock
    case paste
    case achievement
    case notifySuccess = "notify_success"
    case notifyError = "notify_error"
    case notifyAlert = "notify_alert"

    /// Playback volume for this slot. Notifications sit at half volume.
    var volume: Float {
        switch self {
        case .start, .stop, .lock, .paste, .achievement:
            return 1.0
        case .notifySuccess, .notifyError, .notifyAlert:
            return 0.5
        }
    }
}

enum FlowNotificationSound {
    case success
    case error
    case alert

    var slot: FlowSoundSlot {
        switch self {
        case .success: return .notifySuccess
        case .error: return .notifyError
        case .alert: return .notifyAlert
        }
    }
}

extension Notification.Name {
    /// Posted by FlowSoundSettings.pack when the selected pack changes.
    static let flowSoundPackChanged = Notification.Name("FlowSoundPackChanged")
}

/// The synthesized sound packs bundled in Resources/Sounds. Every file is original
/// (scripts/sounds/generate_flow_sounds.py); packs share files per the table in `source(for:)`.
enum FlowSoundPack: String, CaseIterable, Identifiable {
    case `default`, v1, v2, v3, v4, v5, v6, v7, v7_2, v8, v8_2, v9, v10, v11, v11_2, v11_3, v11_4, v12, t1, notifv1, notifv2

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .t1: return "T1"
        case .notifv1: return "Notif v1"
        case .notifv2: return "Notif v2"
        default:
            return "V" + rawValue.dropFirst().replacingOccurrences(of: "_", with: ".")
        }
    }

    var subtitle: String {
        switch self {
        case .default: return "Soft bloops"
        case .v1: return "Crisp click"
        case .v2: return "Tonal pop"
        case .v3: return "Bright click"
        case .v4: return "Quiet chime"
        case .v5: return "Gentle swell"
        case .v6: return "Warm marimba"
        case .v7: return "Wooden tap"
        case .v7_2: return "Double tap"
        case .v8: return "Hollow knock"
        case .v8_2: return "Deep knock"
        case .v9: return "Woody knock"
        case .v10: return "Soft swell"
        case .v11: return "Single click"
        case .v11_2: return "Short tick"
        case .v11_3: return "Light tick"
        case .v11_4: return "Chime click"
        case .v12: return "Tight click"
        case .t1: return "Sparkle run"
        case .notifv1: return "Classic alerts"
        case .notifv2: return "Warm alerts"
        }
    }

    /// The pack whose file is actually used for `slot` (the sharing table).
    func source(for slot: FlowSoundSlot) -> FlowSoundPack {
        switch slot {
        case .start:
            switch self {
            case .v3: return .v1
            case .notifv1, .notifv2: return .default
            default: return self
            }
        case .stop, .lock:
            switch self {
            case .v11, .v11_2, .v11_3, .v11_4: return .v7
            case .t1, .notifv1, .notifv2: return .default
            default: return self
            }
        case .achievement:
            switch self {
            case .v1, .v2, .v3, .v4, .v5, .v6: return .v1
            default: return .default
            }
        case .paste:
            return self == .v12 ? .v12 : .default
        case .notifySuccess, .notifyError, .notifyAlert:
            return self == .notifv2 ? .notifv2 : .default
        }
    }

    /// Resolves the shared-file table, then the bundle. Falls back to the default
    /// pack, then to the legacy sounds. Never crashes on a missing file.
    func url(for slot: FlowSoundSlot) -> URL? {
        let primary = source(for: slot)
        if let url = Self.bundledURL(named: "flow_\(primary.rawValue)_\(slot.rawValue)", ext: "wav") {
            return url
        }
        Self.logger.warning(
            "Missing sound file for pack \(self.rawValue, privacy: .public) slot \(slot.rawValue, privacy: .public)")
        if primary != .default,
            let url = Self.bundledURL(named: "flow_default_\(slot.rawValue)", ext: "wav")
        {
            return url
        }
        return Self.legacyURL(for: slot)
    }

    private static let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowSoundPack")

    static func bundledURL(named name: String, ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/Sounds")
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Sounds")
    }

    private static func legacyURL(for slot: FlowSoundSlot) -> URL? {
        switch slot {
        case .start: return CustomSoundManager.BuiltInSound.sound5.bundleURL
        case .stop: return CustomSoundManager.BuiltInSound.sound6.bundleURL
        default: return CustomSoundManager.BuiltInSound.sound7.bundleURL
        }
    }
}
