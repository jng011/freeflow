import AppKit
import SwiftUI

/// Flow color tokens. Semantic tokens follow the window's light or dark appearance;
/// palette ramps are fixed in both modes.
enum FlowColor {
    // MARK: - Builders

    static func nsHex(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func nsDynamic(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsHex(isDark ? dark : light, alpha: alpha)
        }
    }

    /// A fixed sRGB color.
    static func hex(_ hex: UInt32, alpha: Double = 1) -> Color {
        Color(nsColor: nsHex(hex, alpha: CGFloat(alpha)))
    }

    /// A color that resolves per appearance.
    static func dynamic(light: UInt32, dark: UInt32, alpha: Double = 1) -> Color {
        Color(nsColor: nsDynamic(light: light, dark: dark, alpha: CGFloat(alpha)))
    }

    // MARK: - Semantic tokens

    static let background = dynamic(light: 0xFCFCFB, dark: 0x1A1A1A)
    static let backgroundSecondary = dynamic(light: 0xEEEBE3, dark: 0x30302F)
    static let backgroundTertiary = dynamic(light: 0xF5F4F0, dark: 0x202020)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let primary = dynamic(light: 0x1A1A1A, dark: 0xFCFCFB)
    static let primaryForeground = dynamic(light: 0xFCFCFB, dark: 0x1A1A1A)
    static let foreground = dynamic(light: 0x1A1A1A, dark: 0xE9E8E1)
    static let foregroundSecondary = dynamic(light: 0x1A1A1A, dark: 0xDEDDD7)
    static let foregroundTertiary = dynamic(light: 0x71716E, dark: 0x9D9C98)
    static let border = dynamic(light: 0xEEEBE3, dark: 0x30302F)
    static let ring = dynamic(light: 0x4D4A42, dark: 0xEEEBE3)
    static let neutral200 = dynamic(light: 0xEEEBE3, dark: 0x30302F)
    static let neutral300 = dynamic(light: 0xEEEBE3, dark: 0x30302F)
    static let neutral500 = dynamic(light: 0x4D4A42, dark: 0x9D9C98)
    static let neutral600 = dynamic(light: 0x30302F, dark: 0xDEDDD7)
    static let neutral800 = dynamic(light: 0x1A1A1A, dark: 0xE9E8E1)
    static let shadeWhite = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)
    static let shadeBlack = dynamic(light: 0x000000, dark: 0xE9E8E1)
    static let mutedHover = dynamic(light: 0xF1EBE1, dark: 0x30302F)
    static let destructive = dynamic(light: 0xDC2626, dark: 0xFF5757)
    static let success = dynamic(light: 0x059669, dark: 0x34D399)
    static let warning = dynamic(light: 0xEA580C, dark: 0xF97316)
    static let info = dynamic(light: 0x2563EB, dark: 0x60A5FA)
    static let switchOff = dynamic(light: 0xC5C0B3, dark: 0x5B5B59)
    static let heatEmpty = dynamic(light: 0xC5C0B3, dark: 0x5B5B59)
    static let heatPreAccount = dynamic(light: 0xEEEBE3, dark: 0x464544)
    static let gaugeTrack = dynamic(light: 0xC5C0B3, dark: 0x464544)
    static let chipBorder = dynamic(light: 0xC5C0B3, dark: 0x5B5B59)
    static let chipActiveFill = dynamic(light: 0xF7EBFF, dark: 0x502B66)
    static let dictSelected = dynamic(light: 0xFCF7FF, dark: 0x3C2947)
    static let logoFill = dynamic(light: 0x312D37, dark: 0xE9E8E1)

    /// Keycap face and hard edge (used by FlowKeycap).
    static let keycapFill = dynamic(light: 0xFFFFFF, dark: 0x464544)
    static let keycapEdge = dynamic(light: 0xD3CED6, dark: 0x5B5B59)

    /// Modal and dialog scrim: rgba(26,26,26,0.30).
    static let scrim = hex(0x1A1A1A, alpha: 0.30)

    // MARK: - AppKit variants used by window chrome

    static let nsBackgroundTertiary = nsDynamic(light: 0xF5F4F0, dark: 0x202020)
    static let nsBackground = nsDynamic(light: 0xFCFCFB, dark: 0x1A1A1A)

    // MARK: - Sand

    static let sand50 = hex(0xFCFCFB)
    static let sand100 = hex(0xFAF9F7)
    static let sand200 = hex(0xF8F7F3)
    static let sand300 = hex(0xF7F6F2)
    static let sand500 = hex(0xF5F4F0)
    static let sand600 = hex(0xEEEBE3)
    static let sand700 = hex(0xC5C0B3)
    static let sand800 = hex(0xA39D8E)
    static let sand900 = hex(0x736E62)
    static let sand950 = hex(0x4D4A42)

    // MARK: - Vast

    static let vast50 = hex(0xE9E8E1)
    static let vast100 = hex(0xDEDDD7)
    static let vast300 = hex(0xB3B2AD)
    static let vast400 = hex(0x9D9C98)
    static let vast600 = hex(0x71716E)
    static let vast700 = hex(0x5B5B59)
    static let vast800 = hex(0x464544)
    static let vast900 = hex(0x30302F)
    static let vast925 = hex(0x202020)
    static let vast950 = hex(0x1A1A1A)

    // MARK: - Dawn

    static let dawn100 = hex(0xFCF7FF)
    static let dawn200 = hex(0xFAF1FF)
    static let dawn300 = hex(0xF7EBFF)
    static let dawn400 = hex(0xF4E1FF)
    static let dawn500 = hex(0xF0D7FF)
    static let dawn600 = hex(0xD2ACE9)
    static let dawn700 = hex(0xA26EC1)
    static let dawn800 = hex(0x6C358C)
    static let dawn900 = hex(0x502B66)
    static let dawn950 = hex(0x3C2947)

    // MARK: - Fathom

    static let fathom100 = hex(0xCEEDEA)
    static let fathom300 = hex(0x9FD9CF)
    static let fathom400 = hex(0x84CDC1)
    static let fathom500 = hex(0x68BDB0)
    static let fathom700 = hex(0x369489)
    static let fathom800 = hex(0x247872)
    static let fathom900 = hex(0x1A5C5C)
    static let fathom950 = hex(0x034F46)

    // MARK: - Accents

    static let chord300 = hex(0xCEA8F8)
    static let chord600 = hex(0x7232A6)
    static let glow300 = hex(0xFFA946)
    static let lumen = hex(0xFFFFEB)
    static let signal500 = hex(0xFFBCF2)
    static let pulse700 = hex(0x7F1C34)
    static let flare400 = hex(0xFF6C4C)
    static let searchHighlight = hex(0xFFE788)
    static let destructive500 = hex(0xEE6A6A)
    static let destructiveHover = hex(0xF87171)
    static let green100 = hex(0xD1FAE5)
    static let green800 = hex(0x065F46)
    static let warning400 = hex(0xFFD467)
    static let badgeRed = hex(0xEF4444)

    /// Ghost button hover: rgba(197,192,179,0.2).
    static let ghostHover = hex(0xC5C0B3, alpha: 0.2)
}
