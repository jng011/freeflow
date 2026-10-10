import AppKit
import SwiftUI

// MARK: - Spinner

struct FlowSpinner: View {
    var size: CGFloat = 14
    var color: Color? = nil

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            FlowIcon(.loaderCircle, size: size, color: color)
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Buttons

struct FlowButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost, outline, destructive, dawn }
    enum Size { case xs, sm, md, lg }

    var variant: Variant
    var size: Size
    var capsule: Bool
    var isLoading: Bool
    var fullWidth: Bool

    init(
        variant: Variant = .primary,
        size: Size = .md,
        capsule: Bool = false,
        isLoading: Bool = false,
        fullWidth: Bool = false
    ) {
        self.variant = variant
        self.size = size
        self.capsule = capsule
        self.isLoading = isLoading
        self.fullWidth = fullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        FlowButtonBody(configuration: configuration, style: self)
    }
}

private struct FlowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: FlowButtonStyle
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var padding: EdgeInsets {
        switch style.size {
        case .xs: return EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        case .sm: return EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        case .md: return EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        case .lg: return EdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24)
        }
    }

    private var textStyle: FlowTextStyle {
        switch (style.size, style.variant) {
        case (.xs, .secondary): return .xsStrong
        case (.xs, _): return .xsEmph
        case (_, .secondary): return .smStrong
        default: return .smEmph
        }
    }

    private var foreground: Color {
        switch style.variant {
        case .primary: return FlowColor.primaryForeground
        case .secondary, .ghost, .outline: return FlowColor.foreground
        case .destructive: return .white
        case .dawn: return FlowColor.vast950
        }
    }

    private var fill: Color {
        let hover = hovering && isEnabled
        switch style.variant {
        case .primary:
            return hover ? FlowColor.primary.mix(with: FlowColor.background, by: 0.1) : FlowColor.primary
        case .secondary:
            return hover
                ? FlowColor.backgroundSecondary.mix(with: FlowColor.foreground, by: 0.06)
                : FlowColor.backgroundSecondary
        case .ghost:
            return hover ? FlowColor.ghostHover : .clear
        case .outline:
            return hover ? FlowColor.backgroundTertiary : FlowColor.background
        case .destructive:
            return hover ? FlowColor.destructiveHover : FlowColor.destructive500
        case .dawn:
            return hover ? FlowColor.dawn400 : FlowColor.dawn300
        }
    }

    private var border: Color? {
        switch style.variant {
        case .outline: return FlowColor.border
        case .dawn: return FlowColor.dawn500
        default: return nil
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.capsule ? 999 : FlowRadius.sm, style: .continuous)
        HStack(spacing: 8) {
            if style.isLoading {
                FlowSpinner(size: 14, color: foreground)
            }
            configuration.label
        }
        .flowText(textStyle)
        .lineLimit(1)
        .foregroundStyle(foreground)
        .padding(padding)
        .frame(minHeight: style.size == .xs ? 32 : nil)
        .frame(maxWidth: style.fullWidth ? .infinity : nil)
        .background(shape.fill(fill))
        .overlay {
            if let border {
                shape.strokeBorder(border, lineWidth: 1)
            }
        }
        .contentShape(shape)
        .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
        .onHover { inside in
            withAnimation(FlowMotion.standard) { hovering = inside }
        }
    }
}

extension ButtonStyle where Self == FlowButtonStyle {
    static func flow(_ variant: FlowButtonStyle.Variant = .primary, size: FlowButtonStyle.Size = .md) -> FlowButtonStyle {
        FlowButtonStyle(variant: variant, size: size)
    }
}

// MARK: - Icon buttons

enum FlowIconButtonSize { case sm, md, lg }
enum FlowIconButtonVariant { case standard, toolbar, rowAction, frosted }

/// Visual face shared by FlowIconButton and FlowMenuButton (no gesture of its own).
struct FlowIconButtonFace: View {
    let icon: FlowIconName
    var size: FlowIconButtonSize = .md
    var variant: FlowIconButtonVariant = .standard
    var color: Color? = nil
    var isActive: Bool = false
    var hovering: Bool = false

    @Environment(\.isEnabled) private var isEnabled

    private var box: CGFloat {
        switch variant {
        case .toolbar: return 28
        case .frosted: return 24
        default:
            switch size {
            case .sm: return 24
            case .md: return 28
            case .lg: return 32
            }
        }
    }

    private var radius: CGFloat {
        switch variant {
        case .toolbar: return 6
        case .frosted: return 12
        default:
            switch size {
            case .sm: return 6
            case .md: return 8
            case .lg: return 6
            }
        }
    }

    private var iconSize: CGFloat {
        switch variant {
        case .toolbar: return 16
        case .frosted: return 14
        default:
            switch size {
            case .sm: return 14
            case .md: return 18
            case .lg: return 20
            }
        }
    }

    private var stroke: CGFloat {
        variant == .toolbar ? 1.5 : 2
    }

    private var iconColor: Color {
        if let color { return color }
        switch variant {
        case .toolbar: return FlowColor.neutral600
        case .frosted: return .white
        default: return FlowColor.foreground
        }
    }

    private var fill: Color {
        let lit = (hovering || isActive) && isEnabled
        switch variant {
        case .standard: return lit ? FlowColor.neutral200 : .clear
        case .toolbar: return lit ? FlowColor.backgroundTertiary : .clear
        case .rowAction: return lit ? FlowColor.foreground.opacity(0.08) : .clear
        case .frosted: return Color.white.opacity(lit ? 0.25 : 0.15)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        FlowIcon(icon, size: iconSize, stroke: stroke, color: iconColor)
            .opacity(hovering && isEnabled ? 0.8 : 1)
            .frame(width: box, height: box)
            .background {
                if variant == .frosted {
                    shape.fill(.ultraThinMaterial)
                }
            }
            .background(shape.fill(fill))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.3)
    }
}

struct FlowIconButton: View {
    let icon: FlowIconName
    var size: FlowIconButtonSize = .md
    var variant: FlowIconButtonVariant = .standard
    var color: Color? = nil
    var isActive: Bool = false
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    init(
        icon: FlowIconName,
        size: FlowIconButtonSize = .md,
        variant: FlowIconButtonVariant = .standard,
        color: Color? = nil,
        isActive: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.size = size
        self.variant = variant
        self.color = color
        self.isActive = isActive
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            FlowIconButtonFace(
                icon: icon, size: size, variant: variant, color: color, isActive: isActive, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(FlowMotion.standard) { hovering = inside }
        }
        .flowHint(help ?? "", isEnabled: help != nil)
        .accessibilityLabel(help ?? icon.rawValue)
    }
}

// MARK: - Switch

struct FlowSwitchStyle: ToggleStyle {
    enum Size { case regular, small }
    var size: Size

    init(size: Size = .regular) {
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        FlowSwitchBody(configuration: configuration, size: size)
    }
}

private struct FlowSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    let size: FlowSwitchStyle.Size
    @Environment(\.isEnabled) private var isEnabled

    private var trackSize: CGSize {
        size == .regular ? CGSize(width: 42, height: 25) : CGSize(width: 24, height: 16)
    }

    private var thumb: CGFloat { size == .regular ? 21 : 12 }
    private let inset: CGFloat = 2

    var body: some View {
        HStack(spacing: 8) {
            configuration.label
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(configuration.isOn ? (size == .regular ? FlowColor.primary : FlowColor.dawn600) : FlowColor.switchOff)
                // On: the knob takes the contrast color so it never vanishes into a light track (dark mode).
                Circle()
                    .fill(configuration.isOn && size == .regular ? FlowColor.primaryForeground : Color.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
                    .offset(x: configuration.isOn ? trackSize.width - inset - thumb : inset)
            }
            .frame(width: trackSize.width, height: trackSize.height)
            .contentShape(Capsule())
            .onTapGesture {
                guard isEnabled else { return }
                withAnimation(FlowMotion.standard) {
                    configuration.isOn.toggle()
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}

// MARK: - Checkbox and chips

struct FlowCheckbox: View {
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack {
            shape.fill(isOn ? FlowColor.primary : FlowColor.background)
            if isOn {
                FlowIcon(.check, size: 14, stroke: 3, color: FlowColor.primaryForeground)
            } else {
                shape.strokeBorder(FlowColor.chipBorder, lineWidth: 1)
            }
        }
        .frame(width: 20, height: 20)
    }
}

struct FlowChip<Label: View>: View {
    let isSelected: Bool
    let showsCheckbox: Bool
    let action: () -> Void
    let label: Label

    @State private var hovering = false

    init(
        isSelected: Bool,
        showsCheckbox: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.isSelected = isSelected
        self.showsCheckbox = showsCheckbox
        self.action = action
        self.label = label()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FlowRadius.sm, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                if showsCheckbox {
                    FlowCheckbox(isOn: isSelected)
                }
                label
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foreground)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(shape.fill(isSelected ? FlowColor.chipActiveFill : Color.clear))
            .overlay(
                shape.strokeBorder(
                    isSelected || hovering ? FlowColor.foreground : FlowColor.chipBorder, lineWidth: 1)
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(FlowMotion.standard) { hovering = inside }
        }
    }
}

extension FlowChip where Label == Text {
    init(_ title: String, isSelected: Bool, showsCheckbox: Bool = false, action: @escaping () -> Void) {
        self.init(isSelected: isSelected, showsCheckbox: showsCheckbox, action: action) {
            Text(title)
        }
    }
}

// MARK: - Tabs

struct FlowTabItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String

    init(_ id: ID, title: String) {
        self.id = id
        self.title = title
    }
}

struct FlowTabs<ID: Hashable, Trailing: View>: View {
    let items: [FlowTabItem<ID>]
    @Binding var selection: ID
    let trailing: Trailing

    @Namespace private var underline
    @State private var hovered: ID?

    init(items: [FlowTabItem<ID>], selection: Binding<ID>, @ViewBuilder trailing: () -> Trailing) {
        self.items = items
        self._selection = selection
        self.trailing = trailing()
    }

    private func color(for id: ID) -> Color {
        if id == selection { return FlowColor.foreground }
        if id == hovered { return FlowColor.neutral600 }
        return FlowColor.neutral500
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        withAnimation(FlowMotion.standard) { selection = item.id }
                    } label: {
                        Text(item.title)
                            .flowText(.smStrong)
                            .foregroundStyle(color(for: item.id))
                            .padding(12)
                            .overlay(alignment: .bottom) {
                                if item.id == selection {
                                    Rectangle()
                                        .fill(FlowColor.neutral800)
                                        .frame(height: 2)
                                        .matchedGeometryEffect(id: "flowTabUnderline", in: underline)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        withAnimation(FlowMotion.standard) {
                            if inside {
                                hovered = item.id
                            } else if hovered == item.id {
                                hovered = nil
                            }
                        }
                    }
                }
            }
            .offset(x: -12)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                trailing
            }
        }
        .background(alignment: .bottom) {
            Rectangle().fill(FlowColor.border).frame(height: 1)
        }
    }
}

extension FlowTabs where Trailing == EmptyView {
    init(items: [FlowTabItem<ID>], selection: Binding<ID>) {
        self.init(items: items, selection: selection) { EmptyView() }
    }
}

extension FlowTabs where ID == Int {
    init(items: [String], selection: Binding<Int>, @ViewBuilder trailing: () -> Trailing) {
        self.init(
            items: items.enumerated().map { FlowTabItem($0.offset, title: $0.element) },
            selection: selection,
            trailing: trailing
        )
    }
}

extension FlowTabs where ID == Int, Trailing == EmptyView {
    init(items: [String], selection: Binding<Int>) {
        self.init(items: items, selection: selection) { EmptyView() }
    }
}

// MARK: - Badge

struct FlowBadge: View {
    enum Variant { case dark, brand, light, brandLight, success, glow }

    let text: String
    let variant: Variant

    init(_ text: String, variant: Variant = .dark) {
        self.text = text
        self.variant = variant
    }

    private var colors: (fill: Color, text: Color) {
        switch variant {
        case .dark: return (FlowColor.primary, FlowColor.primaryForeground)
        case .brand: return (FlowColor.dawn500, FlowColor.vast950)
        case .light: return (FlowColor.backgroundTertiary, FlowColor.foregroundTertiary)
        case .brandLight: return (FlowColor.dawn200, FlowColor.dawn700)
        case .success: return (FlowColor.green100, FlowColor.green800)
        case .glow: return (FlowColor.glow300, FlowColor.vast950)
        }
    }

    var body: some View {
        Text(text)
            .flowText(.xsEmph)
            .lineLimit(1)
            .foregroundStyle(colors.text)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(colors.fill))
    }
}

// MARK: - Tooltip

enum FlowHintEdge { case bottom, trailing }

private struct FlowHintModifier: ViewModifier {
    let edge: FlowHintEdge
    let isEnabled: Bool
    let tip: AnyView

    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                pending?.cancel()
                guard isEnabled else { return }
                if inside {
                    pending = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(FlowMotion.hintIn) { shown = true }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { shown = false }
                }
            }
            .onDisappear {
                pending?.cancel()
                shown = false
            }
            .overlay(alignment: edge == .bottom ? .bottom : .trailing) {
                if shown && isEnabled {
                    positionedTip
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .zIndex(shown ? 100 : 0)
    }

    @ViewBuilder
    private var positionedTip: some View {
        switch edge {
        case .bottom:
            tip.fixedSize().alignmentGuide(.bottom) { d in d[.top] - 4 }
        case .trailing:
            tip.fixedSize().alignmentGuide(.trailing) { d in d[.leading] - 4 }
        }
    }
}

extension View {
    /// Dark text tooltip that appears after 300 ms of hover.
    func flowHint(_ text: String, edge: FlowHintEdge = .bottom, isEnabled: Bool = true) -> some View {
        modifier(
            FlowHintModifier(
                edge: edge,
                isEnabled: isEnabled && !text.isEmpty,
                tip: AnyView(
                    Text(text)
                        .flowText(.xs)
                        .foregroundStyle(FlowColor.shadeWhite)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowColor.neutral800))
                )
            )
        )
    }

    /// Card tooltip: background fill, radius 10, padding 12, md shadow.
    func flowHintCard<Card: View>(edge: FlowHintEdge = .bottom, @ViewBuilder _ card: () -> Card) -> some View {
        modifier(
            FlowHintModifier(
                edge: edge,
                isEnabled: true,
                tip: AnyView(
                    card()
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FlowColor.background)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(FlowColor.border, lineWidth: 1)
                        )
                        .flowShadow(.md)
                )
            )
        )
    }
}

// MARK: - Keycaps and shortcut pill

struct FlowKeycap: View {
    let keys: [String]
    var inline: Bool = false
    var fontSize: CGFloat = 14

    init(keys: [String], inline: Bool = false, fontSize: CGFloat = 14) {
        self.keys = keys
        self.inline = inline
        self.fontSize = fontSize
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text("+")
                        .font(FlowFont.sans(fontSize))
                        .foregroundStyle(FlowColor.neutral600)
                }
                cap(key)
            }
        }
    }

    @ViewBuilder
    private func cap(_ key: String) -> some View {
        if inline {
            let shape = RoundedRectangle(cornerRadius: 5.5, style: .continuous)
            Text(key)
                .font(FlowFont.sans(fontSize, weight: 550))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 4)
                // Face first, then the hard (-0.8, 0.8) edge behind it.
                .background(shape.fill(FlowColor.glow300).overlay(shape.strokeBorder(FlowColor.foreground, lineWidth: 1)))
                .background(
                    shape.fill(FlowColor.foreground)
                        .offset(x: -0.8, y: 0.8)
                )
        } else {
            let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
            Text(key)
                .font(FlowFont.sans(fontSize))
                .foregroundStyle(FlowColor.neutral600)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .frame(minHeight: 22)
                .background(
                    shape.fill(FlowColor.keycapFill)
                        .overlay(shape.strokeBorder(FlowColor.border, lineWidth: 1))
                )
                .background(shape.fill(FlowColor.keycapEdge).offset(y: 2))
        }
    }
}

struct FlowShortcutPill: View {
    let title: String
    var action: (() -> Void)? = nil

    @State private var hovering = false

    init(_ title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let content = Text(title)
            .flowText(.smEmph)
            .foregroundStyle(FlowColor.vast800)
            .lineLimit(1)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(shape.fill(FlowColor.sand300))
            .overlay(
                shape.strokeBorder(
                    hovering ? FlowColor.sand700 : FlowColor.sand600, lineWidth: hovering ? 2 : 1)
            )
            .contentShape(shape)
            .onHover { inside in
                withAnimation(FlowMotion.standard) { hovering = inside }
            }

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Card stack and list container

/// Sections stacked in a rounded container, divided by 2 pt lines.
struct FlowCardStack<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FlowRadius.lg, style: .continuous)
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews.indices, id: \.self) { index in
                    if index > 0 {
                        Rectangle().fill(FlowColor.border).frame(height: 2)
                    }
                    subviews[index]
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(FlowColor.border, lineWidth: 1))
    }
}

/// One FlowCardStack section: padding 24 on backgroundTertiary; hover neutral200 when clickable.
struct FlowCardSection<Content: View>: View {
    var padding: CGFloat = 24
    var action: (() -> Void)? = nil
    let content: Content

    @State private var hovering = false

    init(padding: CGFloat = 24, action: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.action = action
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && action != nil ? FlowColor.neutral200 : FlowColor.backgroundTertiary)
            .contentShape(Rectangle())
            .onHover { inside in
                guard action != nil else { return }
                withAnimation(FlowMotion.standard) { hovering = inside }
            }
            .onTapGesture {
                action?()
            }
            .accessibilityAddTraits(action != nil ? .isButton : [])
    }
}

/// History and dictionary tables: radius 16, 1 pt border, rows divided by 1 pt lines.
struct FlowListContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FlowRadius.lg, style: .continuous)
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews.indices, id: \.self) { index in
                    if index > 0 {
                        Rectangle().fill(FlowColor.border).frame(height: 1)
                    }
                    subviews[index]
                }
            }
        }
        .background(FlowColor.background)
        .clipShape(shape)
        .overlay(shape.strokeBorder(FlowColor.border, lineWidth: 1))
    }
}

// MARK: - Empty state

struct FlowEmptyState<Actions: View>: View {
    let icon: FlowIconName
    let title: String
    let message: String
    let actions: Actions

    init(icon: FlowIconName, title: String, body: String, @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.message = body
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 24) {
            FlowIcon(icon, size: 20, color: FlowColor.foregroundTertiary)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(FlowColor.backgroundTertiary))
            VStack(spacing: 8) {
                Text(title)
                    .flowText(.h3)
                    .foregroundStyle(FlowColor.foreground)
                    .multilineTextAlignment(.center)
                Text(message)
                    .flowText(.sm)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 377)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

extension FlowEmptyState where Actions == EmptyView {
    init(icon: FlowIconName, title: String, body: String) {
        self.init(icon: icon, title: title, body: body) { EmptyView() }
    }
}

// MARK: - Key monitor

/// Installs a local keyDown monitor while the view is in a window. The handler only sees
/// events for that window and returns true to consume the event.
struct FlowKeyMonitor: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.handler = handler
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class MonitorView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let window = self.window, event.window === window, let handler = self.handler
                    else {
                        return event
                    }
                    return handler(event) ? nil : event
                }
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

enum FlowKeyboard {
    /// True while a text field or text view in the key window is editing.
    static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    static let escapeKeyCode: UInt16 = 53
    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76
}

// MARK: - Search field

/// Collapsible search: a 28 pt toolbar button that expands into a 200 pt field.
/// `/` or Cmd+F focuses it; Esc clears and collapses it. The binding updates after 300 ms.
struct FlowSearchField: View {
    @Binding var text: String
    let placeholder: String
    var width: CGFloat

    @State private var draft = ""
    @State private var expanded = false
    @State private var debounce: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(text: Binding<String>, placeholder: String = "Search", width: CGFloat = 200) {
        self._text = text
        self.placeholder = placeholder
        self.width = width
    }

    var body: some View {
        HStack(spacing: 4) {
            FlowIconButton(icon: .search, variant: .toolbar, color: FlowColor.vast300) {
                if expanded {
                    focused = true
                } else {
                    expand()
                }
            }
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .flowText(.sm)
                .foregroundStyle(FlowColor.foreground)
                .focused($focused)
                .frame(width: expanded ? width : 0)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .onSubmit { commit(draft) }
            if expanded && !draft.isEmpty {
                FlowIconButton(icon: .x, size: .sm, color: FlowColor.foregroundTertiary) {
                    draft = ""
                    commit("")
                    focused = true
                }
                .transition(.opacity)
            }
        }
        .frame(height: 28)
        .onChange(of: draft) { _, newValue in
            debounce?.cancel()
            debounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                if text != newValue { text = newValue }
            }
        }
        .onChange(of: text) { _, newValue in
            if newValue != draft {
                draft = newValue
                if !newValue.isEmpty { expanded = true }
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && draft.isEmpty {
                withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
            }
        }
        .onAppear {
            draft = text
            expanded = !text.isEmpty
        }
        .background(
            FlowKeyMonitor { event in
                handleKey(event)
            }
            .frame(width: 0, height: 0)
        )
    }

    private func expand() {
        withAnimation(.easeInOut(duration: 0.2)) { expanded = true }
        DispatchQueue.main.async { focused = true }
    }

    private func commit(_ value: String) {
        debounce?.cancel()
        if text != value { text = value }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == FlowKeyboard.escapeKeyCode, focused {
            draft = ""
            commit("")
            focused = false
            withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
            return true
        }
        if modifiers == .command, characters == "f" {
            expand()
            return true
        }
        if characters == "/", modifiers.subtracting([.shift, .numericPad, .function]).isEmpty,
            !FlowKeyboard.isEditingText
        {
            expand()
            return true
        }
        return false
    }
}

// MARK: - Menu

struct FlowMenuItem: Identifiable {
    enum Kind { case action, divider, section }

    let id = UUID()
    let kind: Kind
    let title: String
    let icon: FlowIconName?
    let isDestructive: Bool
    /// nil hides the check column.
    let isChecked: Bool?
    let isEnabled: Bool
    let shortcut: String?
    let action: () -> Void

    private init(
        kind: Kind,
        title: String = "",
        icon: FlowIconName? = nil,
        isDestructive: Bool = false,
        isChecked: Bool? = nil,
        isEnabled: Bool = true,
        shortcut: String? = nil,
        action: @escaping () -> Void = {}
    ) {
        self.kind = kind
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.isChecked = isChecked
        self.isEnabled = isEnabled
        self.shortcut = shortcut
        self.action = action
    }

    static func button(
        _ title: String,
        icon: FlowIconName? = nil,
        destructive: Bool = false,
        checked: Bool? = nil,
        enabled: Bool = true,
        shortcut: String? = nil,
        action: @escaping () -> Void
    ) -> FlowMenuItem {
        FlowMenuItem(
            kind: .action, title: title, icon: icon, isDestructive: destructive, isChecked: checked,
            isEnabled: enabled, shortcut: shortcut, action: action)
    }

    static var divider: FlowMenuItem {
        FlowMenuItem(kind: .divider)
    }

    static func section(_ title: String) -> FlowMenuItem {
        FlowMenuItem(kind: .section, title: title)
    }
}

enum FlowMenuAlignment { case leading, trailing }

/// The rendered menu surface. Normally shown by FlowMenuButton or FlowMenuPresenter.
struct FlowMenu: View {
    let items: [FlowMenuItem]
    var minWidth: CGFloat = 160
    var onSelect: (FlowMenuItem) -> Void = { _ in }

    @State private var appeared = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                switch item.kind {
                case .divider:
                    Rectangle()
                        .fill(FlowColor.border)
                        .frame(height: 1)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                case .section:
                    Text(item.title)
                        .flowText(.label)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                case .action:
                    FlowMenuRow(item: item, showsCheckColumn: items.contains { $0.isChecked != nil }) {
                        onSelect(item)
                    }
                }
            }
        }
        .padding(6)
        .frame(minWidth: minWidth, alignment: .leading)
        .fixedSize()
        .background(shape.fill(FlowColor.background))
        .overlay(shape.strokeBorder(FlowColor.border, lineWidth: 1))
        .flowShadow(.lg)
        .offset(y: appeared || FlowMotion.reduceMotion ? 0 : -4)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(FlowMotion.menuIn) { appeared = true }
        }
    }
}

private struct FlowMenuRow: View {
    let item: FlowMenuItem
    let showsCheckColumn: Bool
    let select: () -> Void

    @State private var hovering = false

    private var textColor: Color {
        item.isDestructive ? FlowColor.destructive500 : FlowColor.foreground
    }

    private var hoverFill: Color {
        item.isDestructive ? FlowColor.destructive.opacity(0.1) : FlowColor.backgroundTertiary
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                if showsCheckColumn {
                    FlowIcon(.check, size: 14, color: textColor)
                        .opacity(item.isChecked == true ? 1 : 0)
                }
                if let icon = item.icon {
                    FlowIcon(icon, size: 16, stroke: 1.75, color: textColor)
                }
                Text(item.title)
                    .flowText(.sm)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .flowText(.xs)
                        .foregroundStyle(FlowColor.foregroundTertiary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && item.isEnabled ? hoverFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .opacity(item.isEnabled ? 1 : 0.5)
        .onHover { inside in hovering = inside }
    }
}

/// Shows FlowMenu in a borderless child panel so it is never clipped by scroll views.
@MainActor
final class FlowMenuPresenter {
    static let shared = FlowMenuPresenter()

    private final class HostingView<Root: View>: NSHostingView<Root> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private var panel: NSPanel?
    private weak var parentWindow: NSWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onClose: (() -> Void)?

    private let shadowRoom: CGFloat = 20

    var isOpen: Bool { panel != nil }

    /// Opens a menu below `anchorView`. Calling it again for an open menu closes it.
    func show(
        items: [FlowMenuItem],
        from anchorView: NSView,
        alignment: FlowMenuAlignment = .leading,
        minWidth: CGFloat = 160,
        onClose: (() -> Void)? = nil
    ) {
        close()
        guard let window = anchorView.window else { return }
        let anchor = window.convertToScreen(anchorView.convert(anchorView.bounds, to: nil))
        show(items: items, anchorRect: anchor, in: window, alignment: alignment, minWidth: minWidth, onClose: onClose)
        currentAnchor = anchorView
    }

    func show(
        items: [FlowMenuItem],
        anchorRect: NSRect,
        in window: NSWindow,
        alignment: FlowMenuAlignment = .leading,
        minWidth: CGFloat = 160,
        onClose: (() -> Void)? = nil
    ) {
        close()

        let menu = FlowMenu(items: items, minWidth: minWidth) { [weak self] item in
            self?.close()
            DispatchQueue.main.async {
                item.action()
            }
        }
        .padding(shadowRoom)

        let hosting = HostingView(rootView: menu)
        let size = hosting.fittingSize

        var origin = NSPoint.zero
        switch alignment {
        case .leading:
            origin.x = anchorRect.minX - shadowRoom
        case .trailing:
            origin.x = anchorRect.maxX - size.width + shadowRoom
        }
        origin.y = anchorRect.minY - 4 + shadowRoom - size.height

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX - shadowRoom), visible.maxX - size.width + shadowRoom)
            if origin.y + shadowRoom < visible.minY {
                // Not enough room below: open above the anchor instead.
                origin.y = anchorRect.maxY + 4 - shadowRoom
            }
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.appearance = window.effectiveAppearance
        panel.contentView = hosting

        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)

        self.panel = panel
        self.parentWindow = window
        self.onClose = onClose
        installMonitors(panel: panel, window: window)
    }

    /// When the last menu closed. A click on the button that opened it closes the menu
    /// (outside-click monitor) before the button's own action runs; this lets that action
    /// tell "just closed" apart from "open again".
    private(set) var lastClosedAt: Date = .distantPast
    private(set) weak var lastClosedAnchor: NSView?
    private weak var currentAnchor: NSView?

    /// True when the menu anchored to `view` closed a moment ago.
    func didJustClose(anchoredTo view: NSView) -> Bool {
        lastClosedAnchor === view && Date().timeIntervalSince(lastClosedAt) < 0.3
    }

    func close() {
        guard let panel else { return }
        lastClosedAt = Date()
        lastClosedAnchor = currentAnchor
        currentAnchor = nil
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        self.parentWindow = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    private func installMonitors(panel: NSPanel, window: NSWindow) {
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown],
            handler: { [weak self] event in
                guard let self, let panel = self.panel else { return event }
                if event.type == .keyDown {
                    if event.keyCode == FlowKeyboard.escapeKeyCode {
                        self.close()
                        return nil
                    }
                    return event
                }
                if event.window !== panel {
                    self.close()
                }
                return event
            })
        {
            monitors.append(local)
        }

        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                Task { @MainActor in self?.close() }
            })
        {
            monitors.append(global)
        }

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.close() }
            })
        observers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.close() }
            })
        observers.append(
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.close() }
            })
    }
}

/// Weak handle to the NSView behind a SwiftUI view, used to anchor panels.
final class FlowAnchorBox {
    weak var view: NSView?
}

struct FlowAnchorReader: NSViewRepresentable {
    let box: FlowAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

/// A button that opens a FlowMenu below itself.
struct FlowMenuButton<Label: View>: View {
    let alignment: FlowMenuAlignment
    let minWidth: CGFloat
    let items: () -> [FlowMenuItem]
    let label: (Bool) -> Label

    @State private var anchor = FlowAnchorBox()
    @State private var isOpen = false

    init(
        alignment: FlowMenuAlignment = .leading,
        minWidth: CGFloat = 160,
        items: @escaping () -> [FlowMenuItem],
        @ViewBuilder label: @escaping (_ isOpen: Bool) -> Label
    ) {
        self.alignment = alignment
        self.minWidth = minWidth
        self.items = items
        self.label = label
    }

    var body: some View {
        Button {
            toggle()
        } label: {
            label(isOpen)
        }
        .buttonStyle(.plain)
        .background(FlowAnchorReader(box: anchor))
    }

    private func toggle() {
        if isOpen {
            FlowMenuPresenter.shared.close()
            return
        }
        guard let view = anchor.view else { return }
        // The outside-click monitor already closed this menu on mouse down.
        if FlowMenuPresenter.shared.didJustClose(anchoredTo: view) { return }
        isOpen = true
        FlowMenuPresenter.shared.show(items: items(), from: view, alignment: alignment, minWidth: minWidth) {
            isOpen = false
        }
    }
}

extension FlowMenuButton where Label == FlowMenuIconLabel {
    /// An icon button (for example the row "more" menu) that opens a FlowMenu.
    init(
        icon: FlowIconName,
        size: FlowIconButtonSize = .md,
        variant: FlowIconButtonVariant = .standard,
        color: Color? = nil,
        alignment: FlowMenuAlignment = .trailing,
        minWidth: CGFloat = 160,
        items: @escaping () -> [FlowMenuItem]
    ) {
        self.init(alignment: alignment, minWidth: minWidth, items: items) { isOpen in
            FlowMenuIconLabel(icon: icon, size: size, variant: variant, color: color, isOpen: isOpen)
        }
    }
}

struct FlowMenuIconLabel: View {
    let icon: FlowIconName
    let size: FlowIconButtonSize
    let variant: FlowIconButtonVariant
    let color: Color?
    let isOpen: Bool

    @State private var hovering = false

    var body: some View {
        FlowIconButtonFace(
            icon: icon, size: size, variant: variant, color: color, isActive: isOpen, hovering: hovering)
            .onHover { inside in
                withAnimation(FlowMotion.standard) { hovering = inside }
            }
    }
}
