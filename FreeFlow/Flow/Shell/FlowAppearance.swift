import AppKit
import QuartzCore
import SwiftUI

/// Theme switching for the Flow window: Light, Dark or Auto (system), cross-faded over 0.2 s.
@MainActor
enum FlowAppearance {
    static var current: AppAppearancePreference {
        AppAppearancePreference.stored
    }

    static func set(_ preference: AppAppearancePreference) {
        guard preference != current else { return }

        if !FlowMotion.reduceMotion {
            for window in NSApp.windows where window.isVisible {
                guard let layerHost = window.contentView else { continue }
                layerHost.wantsLayer = true
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.2
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layerHost.layer?.add(fade, forKey: "flowThemeCrossfade")
            }
        }

        UserDefaults.standard.set(preference.rawValue, forKey: AppAppearancePreference.userDefaultsKey)
        preference.apply()
    }

    /// Menu labels: Light, Dark, Auto.
    static func menuTitle(for preference: AppAppearancePreference) -> String {
        switch preference {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "Auto"
        }
    }

    static func icon(for preference: AppAppearancePreference) -> FlowIconName {
        switch preference {
        case .light: return .sun
        case .dark: return .moon
        case .system: return .monitor
        }
    }
}
