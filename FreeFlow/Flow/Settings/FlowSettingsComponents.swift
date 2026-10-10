import AppKit
import SwiftUI

// Building blocks shared by the Settings modal, its dialogs and onboarding.
// Colors come from FlowColor tokens; the few fixed brand ramps used here are
// re-declared locally so these screens only depend on the documented tokens.

// MARK: - Palette

enum FlowSettingsPalette {
    static func hex(_ value: UInt32, alpha: Double = 1) -> Color {
        Color(nsColor: nsHex(value, alpha: alpha))
    }

    static func dynamic(light: UInt32, dark: UInt32, alpha: Double = 1) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return nsHex(isDark ? dark : light, alpha: alpha)
            })
    }

    private static func nsHex(_ value: UInt32, alpha: Double) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }

    static let dawn100 = hex(0xFCF7FF)
    static let dawn200 = hex(0xFAF1FF)
    static let dawn500 = hex(0xF0D7FF)
    static let dawn600 = hex(0xD2ACE9)
    static let dawn700 = hex(0xA26EC1)
    static let dawn900 = hex(0x502B66)
    static let chord600 = hex(0x7232A6)
    static let fathom900 = hex(0x1A5C5C)
    static let glow300 = hex(0xFFA946)
    static let lumen = hex(0xFFFFEB)
    static let sand300 = hex(0xF7F6F2)
    static let sand700 = hex(0xC5C0B3)
    static let vast300 = hex(0xB3B2AD)
    static let vast800 = hex(0x464544)
    static let destructive500 = hex(0xEE6A6A)
    static let badgeRed = hex(0xEF4444)
    static let recordingBorder = hex(0xA88ED5)
    static let scrim = hex(0x1A1A1A, alpha: 0.3)

    /// Selected tile/card fill: dawn100 in light mode, a deep dawn in dark mode.
    static let selectedFill = dynamic(light: 0xFCF7FF, dark: 0x3C2947)
    /// Language tile selected fill: dawn200 in light mode.
    static let selectedTileFill = dynamic(light: 0xFAF1FF, dark: 0x502B66)
    /// Row deep-link pulse.
    static let highlight = dynamic(light: 0xFCF7FF, dark: 0x3C2947)
    /// Keyboard key face in the onboarding shortcut test.
    static let keyFace = dynamic(light: 0xFFFFFF, dark: 0x464544)
}

// MARK: - Icon

/// FlowIcon by lucide name, with an SF Symbol fallback when the name is unknown.
struct FlowSettingsIcon: View {
    let name: String
    var size: CGFloat = 18
    var stroke: CGFloat = 1.75
    var color: Color? = nil
    var fallback: String = "circle"

    var body: some View {
        if let icon = FlowIconName(rawValue: name) {
            FlowIcon(icon, size: size, stroke: stroke, color: color)
        } else {
            Image(systemName: fallback)
                .font(.system(size: size * 0.8, weight: .regular))
                .foregroundStyle(color ?? .primary)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Layout

let flowSettingsControlWidth: CGFloat = 164

/// Section title (smStrong) with 16 below it, then its card.
struct FlowSettingsSection<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title {
                        Text(title)
                            .flowText(.smStrong)
                            .foregroundStyle(FlowColor.foreground)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .flowText(.sm)
                            .foregroundStyle(FlowColor.foregroundTertiary)
                    }
                }
            }
            content
        }
    }
}

/// Settings card: padding 20, radius 12, backgroundTertiary, rows split by 1 pt lines.
struct FlowSettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 {
                        Rectangle()
                            .fill(FlowColor.border)
                            .frame(height: 1)
                            .padding(.vertical, 6)
                    }
                    subview
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.backgroundTertiary))
    }
}

/// Small heading inside the content column ("Advanced").
struct FlowSettingsHeading: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .flowText(.label)
            .foregroundStyle(FlowColor.neutral500)
    }
}

private struct FlowSettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Anchor of the row that should pulse (deep link).
    var flowSettingsHighlight: String? {
        get { self[FlowSettingsHighlightKey.self] }
        set { self[FlowSettingsHighlightKey.self] = newValue }
    }
}

/// Title + description on the left, a 164 pt control column on the right.
struct FlowSettingsRow<Description: View, Control: View>: View {
    let title: String
    var anchor: String? = nil
    var controlWidth: CGFloat? = flowSettingsControlWidth
    @ViewBuilder var description: Description
    @ViewBuilder var control: Control

    @Environment(\.flowSettingsHighlight) private var highlight
    @State private var isHovered = false
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                description
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let controlWidth {
                control
                    .frame(width: controlWidth, alignment: .trailing)
            } else {
                control
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(pulse ? FlowSettingsPalette.highlight : Color.clear)
        )
        .padding(.horizontal, -12)
        .onHover { isHovered = $0 }
        .onAppear { pulseIfNeeded(highlight) }
        .onChange(of: highlight) { _, newValue in pulseIfNeeded(newValue) }
    }

    private func pulseIfNeeded(_ value: String?) {
        guard let anchor, value == anchor else { return }
        withAnimation(.easeInOut(duration: 0.4)) { pulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.4)) { pulse = false }
        }
    }
}

extension FlowSettingsRow where Description == FlowSettingsDescriptionText {
    init(
        title: String,
        description: String? = nil,
        anchor: String? = nil,
        controlWidth: CGFloat? = flowSettingsControlWidth,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.anchor = anchor
        self.controlWidth = controlWidth
        self.description = FlowSettingsDescriptionText(text: description)
        self.control = control()
    }
}

struct FlowSettingsDescriptionText: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .flowText(.sm)
                .foregroundStyle(FlowColor.foregroundTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Buttons

struct FlowSettingsButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, outline, destructive, destructiveSecondary, link }
    enum Size { case xs, sm, md, lg }

    var kind: Kind = .secondary
    var size: Size = .md
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        FlowSettingsButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }
}

private struct FlowSettingsButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: FlowSettingsButtonStyle.Kind
    let size: FlowSettingsButtonStyle.Size
    let fullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, kind == .link ? 0 : horizontalPadding)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(kind == .outline ? FlowColor.border : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .onHover { isHovered = $0 }
            .animation(FlowMotion.standard, value: isHovered)
    }

    private var font: Font {
        switch size {
        case .xs: return FlowFont.sans(12, weight: 550)
        default: return FlowFont.sans(15, weight: kind == .secondary ? 600 : 550)
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .xs: return 0
        case .sm: return 6
        case .md: return 8
        case .lg: return 10
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .xs, .sm: return 12
        case .md: return 16
        case .lg: return 24
        }
    }

    private var minHeight: CGFloat? {
        switch size {
        case .xs: return 32
        case .sm: return 32
        case .md: return 36
        case .lg: return 44
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return FlowColor.primaryForeground
        case .secondary, .ghost, .outline: return FlowColor.foreground
        case .destructive: return .white
        case .destructiveSecondary: return FlowColor.destructive
        case .link: return isHovered ? FlowColor.foregroundTertiary : FlowColor.foreground
        }
    }

    private var fill: Color {
        let hover = isHovered && isEnabled
        switch kind {
        case .primary: return hover ? FlowColor.primary.opacity(0.9) : FlowColor.primary
        case .secondary, .destructiveSecondary:
            return hover ? FlowColor.neutral200 : FlowColor.backgroundSecondary
        case .ghost: return hover ? FlowSettingsPalette.sand700.opacity(0.2) : .clear
        case .outline: return hover ? FlowColor.backgroundTertiary : FlowColor.background
        case .destructive: return hover ? FlowSettingsPalette.hex(0xF87171) : FlowSettingsPalette.destructive500
        case .link: return .clear
        }
    }
}

extension View {
    func flowSettingsButton(
        _ kind: FlowSettingsButtonStyle.Kind = .secondary,
        size: FlowSettingsButtonStyle.Size = .md,
        fullWidth: Bool = false
    ) -> some View {
        buttonStyle(FlowSettingsButtonStyle(kind: kind, size: size, fullWidth: fullWidth))
    }
}

/// Full-width secondary "Change"-style button used in the control column.
struct FlowSettingsActionButton: View {
    let title: String
    var kind: FlowSettingsButtonStyle.Kind = .secondary
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .flowSettingsButton(kind, size: .md, fullWidth: true)
    }
}

/// Inline bold link ("Learn more →", "Show now", "Open").
struct FlowSettingsInlineLink: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .flowText(.smStrong)
                .foregroundStyle(isHovered ? FlowColor.foregroundTertiary : FlowColor.foreground)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyleLink()
    }
}

extension View {
    @ViewBuilder
    func pointerStyleLink() -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(.link)
        } else {
            self
        }
    }
}

// MARK: - Switch

struct FlowSettingsSwitchStyle: ToggleStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        FlowSettingsSwitchBody(configuration: configuration, small: small)
    }
}

private struct FlowSettingsSwitchBody: View {
    let configuration: ToggleStyle.Configuration
    let small: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let width: CGFloat = small ? 24 : 42
        let height: CGFloat = small ? 16 : 25
        let thumb: CGFloat = small ? 12 : 21
        let inset: CGFloat = 2
        let onColor = small ? FlowSettingsPalette.dawn600 : FlowColor.primary

        HStack(spacing: 8) {
            configuration.label
            Capsule()
                .fill(configuration.isOn ? onColor : FlowColor.switchOff)
                .frame(width: width, height: height)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    // On: the knob takes the contrast color so it never vanishes into a light track (dark mode).
                    Circle()
                        .fill(configuration.isOn && !small ? FlowColor.primaryForeground : Color.white)
                        .frame(width: thumb, height: thumb)
                        .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
                        .padding(inset)
                }
                .contentShape(Capsule())
                .onTapGesture {
                    guard isEnabled else { return }
                    withAnimation(FlowMotion.standard) { configuration.isOn.toggle() }
                }
                .opacity(isEnabled ? 1 : 0.5)
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityValue(configuration.isOn ? "On" : "Off")
        }
    }
}

/// A right-aligned switch for the control column.
struct FlowSettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(FlowSettingsSwitchStyle())
        }
    }
}

// MARK: - Chip

struct FlowSettingsChip: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                if let subtitle {
                    Text(subtitle)
                        .flowText(.xs)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? FlowColor.chipActiveFill : FlowColor.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected || isHovered ? FlowColor.foreground : FlowColor.chipBorder,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(FlowMotion.standard, value: isHovered)
        .animation(FlowMotion.standard, value: isSelected)
    }
}

// MARK: - Dropdown

struct FlowSettingsOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var subtitle: String? = nil
    var id: String { title }
}

/// A 48 pt-style menu button (background fill, 1 pt border, radius 8, chevron-down)
/// that opens a Flow menu in a popover.
struct FlowSettingsDropdown<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [FlowSettingsOption<Value>]
    var width: CGFloat = flowSettingsControlWidth
    var placeholder = "Select"
    var onSelect: ((Value) -> Void)? = nil

    @State private var isOpen = false
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(currentTitle)
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                FlowSettingsIcon(
                    name: "chevron-down", size: 16, stroke: 1.75, color: FlowColor.foregroundTertiary,
                    fallback: "chevron.down")
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: 36)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.background))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isHovered ? FlowColor.neutral500 : FlowColor.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FlowSettingsMenuList(
                options: options,
                selection: selection,
                onSelect: { value in
                    isOpen = false
                    selection = value
                    onSelect?(value)
                }
            )
        }
    }

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? placeholder
    }
}

private struct FlowSettingsMenuList<Value: Hashable>: View {
    let options: [FlowSettingsOption<Value>]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options) { option in
                    FlowSettingsMenuItem(
                        title: option.title,
                        subtitle: option.subtitle,
                        isSelected: option.value == selection
                    ) {
                        onSelect(option.value)
                    }
                }
            }
            .padding(6)
        }
        .frame(minWidth: 200)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: options.count <= 8)
        .background(FlowColor.background)
    }
}

private struct FlowSettingsMenuItem: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.foreground)
                    if let subtitle {
                        Text(subtitle)
                            .flowText(.xs)
                            .foregroundStyle(FlowColor.foregroundTertiary)
                    }
                }
                Spacer(minLength: 12)
                if isSelected {
                    FlowSettingsIcon(name: "check", size: 14, stroke: 2, color: FlowColor.foreground, fallback: "checkmark")
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? FlowColor.backgroundTertiary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Text field

struct FlowSettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    var width: CGFloat? = nil
    var onSubmit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(FlowColor.foregroundTertiary))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(FlowColor.foregroundTertiary))
            }
        }
        .textFieldStyle(.plain)
        .font(FlowFont.sans(15))
        .foregroundStyle(FlowColor.foreground)
        .focused($isFocused)
        .onSubmit { onSubmit?() }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.background))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFocused || isHovered ? FlowColor.neutral500 : FlowColor.neutral300,
                    lineWidth: isFocused || isHovered ? 2 : 1
                )
        )
        .onHover { isHovered = $0 }
    }
}

/// Multiline field with a placeholder (TextEditor has none of its own).
struct FlowSettingsTextArea: View {
    let placeholder: String
    @Binding var text: String
    var height: CGFloat = 120

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(FlowFont.sans(15))
                .foregroundStyle(FlowColor.foreground)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
            if text.isEmpty {
                Text(placeholder)
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.background))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isFocused ? FlowColor.neutral500 : FlowColor.neutral300, lineWidth: isFocused ? 2 : 1)
        )
    }
}

// MARK: - Stepper

/// "Up to N words" style stepper: minus, value, plus.
struct FlowSettingsStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let label: (Int) -> String

    var body: some View {
        HStack(spacing: 6) {
            stepButton("minus", fallback: "minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - step)
            }
            Text(label(value))
                .flowText(.sm)
                .monospacedDigit()
                .foregroundStyle(FlowColor.foreground)
                .frame(minWidth: 80)
            stepButton("plus", fallback: "plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func stepButton(_ icon: String, fallback: String, enabled: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            FlowSettingsIcon(name: icon, size: 14, stroke: 2, color: FlowColor.foreground, fallback: fallback)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(FlowColor.backgroundSecondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - Inline keycap

/// Keys shown inside running text ("Hold fn and speak.").
struct FlowSettingsInlineKeys: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .flowText(.smStrong)
                    .foregroundStyle(FlowColor.foreground)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(FlowColor.backgroundSecondary.opacity(0.6))
                    )
            }
        }
    }
}

// MARK: - Badge

struct FlowSettingsCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(FlowFont.sans(9, weight: 650))
            .foregroundStyle(Color.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(FlowSettingsPalette.badgeRed))
    }
}

struct FlowSettingsPillBadge: View {
    let title: String
    var fill: Color = FlowColor.backgroundTertiary
    var foreground: Color = FlowColor.foregroundTertiary

    var body: some View {
        Text(title)
            .flowText(.xsEmph)
            .foregroundStyle(foreground)
            .padding(.vertical, 1)
            .padding(.horizontal, 8)
            .frame(minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
    }
}

// MARK: - Dialog frame

/// The FlowDialog look (padding 24, radius 12, 1 pt border, xl shadow, gap 32).
struct FlowSettingsDialogFrame<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var maxWidth: CGFloat = 650
    var minWidth: CGFloat = 200
    var spacing: CGFloat = 32
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .flowText(.h4)
                    .foregroundStyle(FlowColor.foreground)
                if let subtitle {
                    Text(subtitle)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.neutral500)
                        .lineLimit(4)
                        .frame(maxWidth: 416, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack(spacing: 12) {
                actions
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.background))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(FlowColor.border, lineWidth: 1))
        .flowShadow(.xl)
    }
}

// MARK: - Confirmation

struct FlowSettingsConfirmation: Identifiable {
    let id = UUID()
    let title: String
    var message: String? = nil
    var confirmTitle: String = "Confirm"
    var isDestructive = true
    let action: () -> Void
}

struct FlowSettingsConfirmView: View {
    let confirmation: FlowSettingsConfirmation
    let onDismiss: () -> Void

    var body: some View {
        FlowSettingsDialogFrame(title: confirmation.title, subtitle: confirmation.message, maxWidth: 464) {
            EmptyView()
        } actions: {
            Button("Cancel", action: onDismiss)
                .flowSettingsButton(.secondary)
                .keyboardShortcut(.cancelAction)
            Button(confirmation.confirmTitle) {
                onDismiss()
                confirmation.action()
            }
            .flowSettingsButton(confirmation.isDestructive ? .destructive : .primary)
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Presenter

enum FlowSettingsSheet: String, Identifiable {
    case modes, diagnostics, tryIt
    var id: String { rawValue }
}

/// Shared presentation state for the Settings modal (and onboarding): which dialog,
/// confirmation or sheet is open, plus the row to pulse.
@MainActor
final class FlowSettingsPresenter: ObservableObject {
    @Published var dialog: FlowSettingsDialog?
    @Published var confirmation: FlowSettingsConfirmation?
    @Published var sheet: FlowSettingsSheet?
    @Published var highlight: String?
    /// Set by the modal so panes can jump to another pane ("Open" links).
    var selectPane: ((FlowSettingsPane) -> Void)?
    /// Set by the modal so panes can close Settings.
    var close: (() -> Void)?

    func confirm(
        _ title: String,
        message: String? = nil,
        confirmTitle: String = "Confirm",
        destructive: Bool = true,
        action: @escaping () -> Void
    ) {
        confirmation = FlowSettingsConfirmation(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            isDestructive: destructive,
            action: action
        )
    }

    func open(_ dialog: FlowSettingsDialog) {
        self.dialog = dialog
    }

    func pulse(_ anchor: String) {
        highlight = nil
        DispatchQueue.main.async { [weak self] in
            self?.highlight = anchor
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                if self?.highlight == anchor { self?.highlight = nil }
            }
        }
    }
}

/// Renders the presenter's dialogs, confirmations and sheets over `content`.
struct FlowSettingsOverlayHost: ViewModifier {
    @ObservedObject var presenter: FlowSettingsPresenter

    func body(content: Content) -> some View {
        content
            .environment(\.flowSettingsHighlight, presenter.highlight)
            .overlay {
                ZStack {
                    if let dialog = presenter.dialog {
                        FlowSettingsPalette.scrim
                            .contentShape(Rectangle())
                            .onTapGesture { presenter.dialog = nil }
                        dialogView(dialog)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                    if let confirmation = presenter.confirmation {
                        FlowSettingsPalette.scrim
                            .contentShape(Rectangle())
                            .onTapGesture { presenter.confirmation = nil }
                        FlowSettingsConfirmView(confirmation: confirmation) {
                            presenter.confirmation = nil
                        }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.15, bounce: 0), value: presenter.dialog)
                .animation(.spring(duration: 0.15, bounce: 0), value: presenter.confirmation?.id)
            }
            .sheet(item: $presenter.sheet) { sheet in
                sheetView(sheet)
            }
    }

    @ViewBuilder
    private func dialogView(_ dialog: FlowSettingsDialog) -> some View {
        switch dialog {
        case .shortcuts:
            FlowShortcutsDialog(onClose: { presenter.dialog = nil })
        case .microphone:
            FlowMicrophoneDialog(onClose: { presenter.dialog = nil })
        case .languages:
            FlowLanguagesDialog(onClose: { presenter.dialog = nil })
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: FlowSettingsSheet) -> some View {
        switch sheet {
        case .modes:
            VStack(spacing: 0) {
                ModeView()
                FlowSettingsSheetFooter { presenter.sheet = nil }
            }
            .frame(width: 900, height: 640)
        case .diagnostics:
            VStack(alignment: .leading, spacing: 24) {
                Text("Diagnostics")
                    .flowText(.h4)
                    .foregroundStyle(FlowColor.foreground)
                Form {
                    DiagnosticsSettingsView()
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                FlowSettingsSheetFooter { presenter.sheet = nil }
            }
            .padding(24)
            .frame(width: 560, height: 320)
            .background(FlowColor.background)
        case .tryIt:
            FlowTryItSheet()
        }
    }
}

private struct FlowSettingsSheetFooter: View {
    let onDone: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Done", action: onDone)
                .flowSettingsButton(.primary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}

extension View {
    func flowSettingsOverlays(_ presenter: FlowSettingsPresenter) -> some View {
        modifier(FlowSettingsOverlayHost(presenter: presenter))
    }
}
