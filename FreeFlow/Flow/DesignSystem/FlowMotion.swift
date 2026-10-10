import AppKit
import SwiftUI

// MARK: - Motion

enum FlowMotion {
    /// Hovers, background changes, tab underline, switch thumb.
    static let standard = Animation.spring(duration: 0.15, bounce: 0)
    /// Theme cross-fade.
    static let theme = Animation.easeInOut(duration: 0.2)
    /// Dialog entrance (scale 0.9 to 1 plus opacity).
    static let dialogIn = Animation.spring(duration: 0.15, bounce: 0)
    /// In-app toast entrance.
    static let toastIn = Animation.spring(duration: 0.15, bounce: 0.1)
    /// In-app toast exit (moves up and fades).
    static let toastOut = Animation.easeOut(duration: 0.8)
    /// Menus drop 4 pt over 80 ms.
    static let menuIn = Animation.easeOut(duration: 0.08)
    /// Tooltip entrance.
    static let hintIn = Animation.easeOut(duration: 0.15)
    /// Flow Bar morph: 100 ms, cubic-bezier(0.05, 0.6, 0.4, 0.95).
    static let barMorph = Animation.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.1)
    /// Flow Bar toast morph: 420 ms spring with no overshoot.
    static let toastMorph = Animation.spring(duration: 0.42, bounce: 0)

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `animation` unless Reduce Motion is on.
    static func respecting(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Shadows

enum FlowShadow {
    case xs, sm, md, lg, xl

    fileprivate struct Layer {
        let y: CGFloat
        let blur: CGFloat
        let opacity: Double
    }

    fileprivate var layers: (Layer, Layer?) {
        switch self {
        case .xs: return (Layer(y: 1, blur: 2, opacity: 0.05), nil)
        case .sm: return (Layer(y: 1, blur: 3, opacity: 0.1), Layer(y: 1, blur: 2, opacity: 0.1))
        case .md: return (Layer(y: 4, blur: 6, opacity: 0.1), Layer(y: 2, blur: 4, opacity: 0.1))
        case .lg: return (Layer(y: 10, blur: 15, opacity: 0.1), Layer(y: 4, blur: 6, opacity: 0.1))
        case .xl: return (Layer(y: 20, blur: 25, opacity: 0.1), Layer(y: 8, blur: 10, opacity: 0.1))
        }
    }
}

private struct FlowShadowModifier: ViewModifier {
    let shadow: FlowShadow

    func body(content: Content) -> some View {
        let (first, second) = shadow.layers
        // CSS blur radius is roughly twice SwiftUI's shadow radius.
        content
            .shadow(color: FlowColor.hex(0x1A1A1A, alpha: first.opacity), radius: first.blur / 2, x: 0, y: first.y)
            .shadow(
                color: FlowColor.hex(0x1A1A1A, alpha: second?.opacity ?? 0),
                radius: (second?.blur ?? 0) / 2,
                x: 0,
                y: second?.y ?? 0
            )
    }
}

extension View {
    func flowShadow(_ shadow: FlowShadow) -> some View {
        modifier(FlowShadowModifier(shadow: shadow))
    }
}

// MARK: - Radii and spacing

enum FlowRadius {
    static let xxs: CGFloat = 4
    /// Nav items, small icon buttons.
    static let xs: CGFloat = 6
    /// Buttons, inputs, tiles.
    static let sm: CGFloat = 8
    /// Menus.
    static let menu: CGFloat = 10
    /// Cards, modals.
    static let md: CGFloat = 12
    /// List containers, banners, card stacks.
    static let lg: CGFloat = 16
    /// Shortcut pill.
    static let pill: CGFloat = 18
    /// Page card top corners.
    static let page: CGFloat = 24
}

enum FlowSpacing {
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s8: CGFloat = 8
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s40: CGFloat = 40
    static let s48: CGFloat = 48
}
