import AppKit
import CoreText
import SwiftUI

// MARK: - Resource lookup

/// Bundle resources are copied flat into Contents/Resources. Older layouts keep the
/// folder, so fall back to "Resources/<Folder>".
enum FlowResources {
    static func url(_ name: String, ext: String, folder: String? = nil) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        if let folder {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/\(folder)") {
                return url
            }
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: folder) {
                return url
            }
        }
        return nil
    }
}

// MARK: - Font registration

enum FlowFonts {
    enum Face: String, CaseIterable {
        case sans = "Figtree-Variable"
        case sansItalic = "Figtree-Italic-Variable"
        case serif = "EBGaramond-Variable"
        case serifItalic = "EBGaramond-Italic-Variable"
        case mono = "GoogleSansCode-Variable"
    }

    private static let lock = NSLock()
    private static var didRegister = false
    private static var baseDescriptors: [Face: CTFontDescriptor] = [:]
    private static var missingFaces: Set<Face> = []
    private static var fontCache: [String: CTFont] = [:]

    /// Registers the bundled OFL fonts for this process. Idempotent; missing files are skipped.
    static func registerAll() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRegister else { return }
        didRegister = true

        for face in Face.allCases {
            guard let url = FlowResources.url(face.rawValue, ext: "ttf", folder: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Base descriptor read straight from the font file, so lookups never depend on family names.
    private static func baseDescriptor(for face: Face) -> CTFontDescriptor? {
        // Caller holds the lock.
        if let cached = baseDescriptors[face] { return cached }
        if missingFaces.contains(face) { return nil }
        guard let url = FlowResources.url(face.rawValue, ext: "ttf", folder: "Fonts"),
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let first = descriptors.first
        else {
            missingFaces.insert(face)
            return nil
        }
        baseDescriptors[face] = first
        return first
    }

    /// A CTFont for the face at the given size and 'wght' axis value, or nil when the file is missing.
    static func ctFont(_ face: Face, size: CGFloat, weight: CGFloat, stylisticAlternates: Bool) -> CTFont? {
        let key = "\(face.rawValue)|\(size)|\(weight)|\(stylisticAlternates)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = fontCache[key] { return cached }
        guard let base = baseDescriptor(for: face) else { return nil }

        let wghtTag: UInt32 = 0x7767_6874  // 'wght'
        var attributes: [CFString: Any] = [
            kCTFontVariationAttribute: [NSNumber(value: wghtTag): NSNumber(value: Double(weight))]
        ]
        if stylisticAlternates {
            attributes[kCTFontFeatureSettingsAttribute] = [
                [
                    kCTFontOpenTypeFeatureTag: "salt",
                    kCTFontOpenTypeFeatureValue: NSNumber(value: 1),
                ] as [CFString: Any]
            ]
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        fontCache[key] = font
        return font
    }
}

// MARK: - Fonts

enum FlowFont {
    /// Figtree with the 'wght' axis and stylistic alternates on.
    static func sans(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        if let font = FlowFonts.ctFont(.sans, size: size, weight: weight, stylisticAlternates: true) {
            return Font(font)
        }
        return .system(size: size, weight: systemWeight(weight))
    }

    /// EB Garamond. Titles use weight 400; heavier values are allowed for emphasis.
    static func serif(_ size: CGFloat, italic: Bool = false, weight: CGFloat = 400) -> Font {
        if let font = FlowFonts.ctFont(italic ? .serifItalic : .serif, size: size, weight: weight, stylisticAlternates: false)
        {
            return Font(font)
        }
        let base = Font.system(size: size, weight: systemWeight(weight), design: .serif)
        return italic ? base.italic() : base
    }

    /// Google Sans Code.
    static func mono(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        if let font = FlowFonts.ctFont(.mono, size: size, weight: weight, stylisticAlternates: false) {
            return Font(font)
        }
        return .system(size: size, weight: systemWeight(weight), design: .monospaced)
    }

    static func systemWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<540: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }
}

// MARK: - Text styles

enum FlowTextStyle: CaseIterable {
    case lg, lgEmph
    case md, mdEmph, mdStrong
    case sm, smEmph, smStrong
    case xs, xsEmph, xsStrong
    case xxs
    case time
    case h1, h2, h3, h4
    case label
    case serif28, serif36, serif48, serif65, serif72

    var size: CGFloat {
        switch self {
        case .lg, .lgEmph: return 18
        case .md, .mdEmph, .mdStrong: return 16
        case .sm, .smEmph, .smStrong: return 15
        case .xs, .xsEmph, .xsStrong: return 12
        case .xxs: return 10
        case .time: return 13
        case .h1: return 24
        case .h2: return 28
        case .h3: return 20
        case .h4: return 18
        case .label: return 12
        case .serif28: return 28
        case .serif36: return 36
        case .serif48: return 48
        case .serif65: return 65
        case .serif72: return 72
        }
    }

    var lineHeight: CGFloat {
        switch self {
        case .lg, .lgEmph: return 28
        case .md, .mdEmph, .mdStrong: return 24
        case .sm, .smEmph, .smStrong: return 20
        case .xs, .xsEmph, .xsStrong: return 20
        case .xxs: return 18
        case .time: return 20
        case .h1: return 32
        case .h2: return 34
        case .h3: return 28
        case .h4: return 24
        case .label: return 20
        case .serif28: return 28
        case .serif36: return 40
        case .serif48: return 48
        case .serif65: return 65
        case .serif72: return 72
        }
    }

    var weight: CGFloat {
        switch self {
        case .lgEmph, .mdEmph, .smEmph, .xsEmph: return 550
        case .mdStrong, .smStrong, .xsStrong: return 600
        case .h1, .h2, .h3, .h4, .label: return 600
        default: return 400
        }
    }

    var isSerif: Bool {
        switch self {
        case .serif28, .serif36, .serif48, .serif65, .serif72: return true
        default: return false
        }
    }

    var isUppercase: Bool { self == .label }

    /// Letter spacing in points.
    var tracking: CGFloat {
        switch self {
        case .label: return 0.9
        case .serif28, .serif36, .serif48, .serif65, .serif72: return -0.04 * size
        default: return 0
        }
    }

    var font: Font {
        isSerif ? FlowFont.serif(size) : FlowFont.sans(size, weight: weight)
    }

    var italicFont: Font {
        isSerif ? FlowFont.serif(size, italic: true) : FlowFont.sans(size, weight: weight).italic()
    }

    /// Extra spacing between lines so the line box matches the CSS line height.
    var lineSpacing: CGFloat {
        max(0, lineHeight - size * 1.2)
    }
}

private struct FlowTextModifier: ViewModifier {
    let style: FlowTextStyle

    func body(content: Content) -> some View {
        content
            .font(style.font)
            .lineSpacing(style.lineSpacing)
            .tracking(style.tracking)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}

extension View {
    /// Applies a Flow text style: font, line spacing, tracking and (for labels) uppercase.
    func flowText(_ style: FlowTextStyle) -> some View {
        modifier(FlowTextModifier(style: style))
    }
}

// MARK: - Rich text

enum FlowRichText {
    /// Builds a Text from light markdown: `*italic*` and `**bold**`.
    /// Italic uses `italicFont`, bold uses `boldFont`, the rest uses `font`.
    static func text(_ markdown: String, font: Font, italicFont: Font, boldFont: Font) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else {
            return Text(markdown).font(font)
        }

        var result = Text("")
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let runFont: Font
            if intent.contains(.stronglyEmphasized) {
                runFont = boldFont
            } else if intent.contains(.emphasized) {
                runFont = italicFont
            } else {
                runFont = font
            }
            result = result + Text(verbatim: piece).font(runFont)
        }
        return result
    }
}
