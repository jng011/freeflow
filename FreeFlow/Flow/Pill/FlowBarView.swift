import SwiftUI

// MARK: - Fixed palette (the bar looks the same in light and dark mode)

enum FlowBarPalette {
    static func rgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    static let black = rgb(0x000000)
    static let border = rgb(0x30302F)
    static let hoverFill = rgb(0x30302F)
    static let hoverBorder = rgb(0x5B5B59)
    static let cancelFill = rgb(0x4D4A42)
    static let light = rgb(0xFCFCFB)
    static let dark = rgb(0x1A1A1A)
    static let errorBorder = rgb(0xEE6A6A)
    static let warning = rgb(0xF2C94C)
    static let idleBar = Color.white.opacity(0.4)
    static let activeBar = Color.white
    /// Prompt mode waveform and badge (soft violet).
    static let promptAccent = Color(red: 0.72, green: 0.6, blue: 1.0)
    static let restingFill = Color.black.opacity(0.5)
    static let restingBorder = Color.white.opacity(0.5)

    // Toasts and cards
    static let condensedFill = rgb(0x1A1A1A)
    static let mutedText = rgb(0xB3B2AD)
    static let progressTrack = rgb(0x71716E)
    static let lumen = rgb(0xFFFFEB)
    static let primaryAction = rgb(0x71716E)
    static let primaryActionHover = rgb(0x5B5B59)
    static let secondaryText = rgb(0xEEEBE3)
    static let badgeFill = rgb(0xF0D7FF)
    static let miniHover = rgb(0x464544)
    static let shadow = rgb(0x1A1A1A)
}

// MARK: - Geometry

enum FlowBarMetrics {
    static let bottomInset: CGFloat = 14
    static let coordinateSpace = "FlowBarRoot"
    static let buttonSize: CGFloat = 18
    static let buttonSpacing: CGFloat = 4
    /// cancel + gap + waveform + gap + finish
    static let popoContentWidth: CGFloat = buttonSize * 2 + buttonSpacing * 2 + FlowBarWaveform.width

    /// cubic-bezier(0.05, 0.6, 0.4, 0.95), 100 ms
    static let morph = Animation.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.1)

    static func pillSize(for state: FlowBarState) -> CGSize {
        switch state {
        case .hidden, .resting: return CGSize(width: 40, height: 8)
        case .ready: return CGSize(width: 50, height: 30)
        case .initializing, .activePTT: return CGSize(width: 73, height: 30)
        case .activeHandsFree: return CGSize(width: 102.5, height: 30)
        case .processing: return CGSize(width: 98, height: 30)
        case .error: return CGSize(width: 91, height: 30)
        }
    }

    static func cornerRadius(for state: FlowBarState) -> CGFloat {
        switch state {
        case .hidden, .resting: return 6
        default: return 22.5
        }
    }

    static func fill(for state: FlowBarState, pointerOverPill: Bool) -> Color {
        switch state {
        case .hidden, .resting: return FlowBarPalette.restingFill
        case .ready: return pointerOverPill ? FlowBarPalette.hoverFill : FlowBarPalette.black
        default: return FlowBarPalette.black
        }
    }

    static func border(for state: FlowBarState, pointerOverPill: Bool) -> Color {
        switch state {
        case .hidden, .resting: return FlowBarPalette.restingBorder
        case .ready: return pointerOverPill ? FlowBarPalette.hoverBorder : FlowBarPalette.border
        case .error: return FlowBarPalette.errorBorder
        default: return FlowBarPalette.border
        }
    }

    static func borderWidth(for state: FlowBarState) -> CGFloat {
        state == .error ? 1.5 : 1
    }
}

// MARK: - Root view

/// Fills the 520 x 340 panel. The pill, its tooltip and any toast anchor bottom-center 14 pt up.
struct FlowBarView: View {
    @ObservedObject var controller: FlowBarController
    @ObservedObject var dictation: FlowDictationState

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)

            tooltipLayer

            FlowBarPill(
                state: controller.state,
                isPointerOverPill: controller.isPointerOverPill,
                micActive: dictation.micActive,
                micSilent: dictation.micSilent,
                isListening: dictation.phase == .listening,
                meter: controller.levelMeter,
                accent: dictation.modeBadge == .prompt ? FlowBarPalette.promptAccent : nil,
                onTap: { controller.pillTapped() },
                onCancel: { controller.cancelTapped() },
                onFinish: { controller.finishTapped() }
            )
            .overlay(alignment: .leading) {
                if let badge = dictation.modeBadge, controller.state != .hidden, controller.state != .resting {
                    FlowBarModeBadge(badge: badge)
                        .offset(x: -(FlowBarModeBadge.size + 6))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.25, bounce: 0.2), value: dictation.modeBadge)
            .opacity(controller.state == .hidden ? 0 : 1)
            .animation(.easeOut(duration: 0.1), value: controller.state == .hidden)
            .opacity(controller.isPillSuppressed ? 0 : 1)
            .animation(controller.isPillSuppressed ? nil : .easeOut(duration: 0.2), value: controller.isPillSuppressed)
            .allowsHitTesting(!controller.isPillSuppressed && controller.state != .hidden)
            .padding(.bottom, FlowBarMetrics.bottomInset)

            if let presentation = controller.presentation {
                FlowBarToastHost(controller: controller, presentation: presentation)
                    .id(presentation.id)
                    .padding(.bottom, FlowBarMetrics.bottomInset)
            }
        }
        .frame(width: FlowBarPanel.panelSize.width, height: FlowBarPanel.panelSize.height)
        .coordinateSpace(.named(FlowBarMetrics.coordinateSpace))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var tooltipLayer: some View {
        let pillHeight = FlowBarMetrics.pillSize(for: controller.state).height
        ZStack(alignment: .bottom) {
            if let tooltip = controller.tooltip, controller.presentation == nil {
                FlowBarTooltip(content: tooltip)
                    .padding(.bottom, FlowBarMetrics.bottomInset + pillHeight + (tooltip.isButton ? 10 : 4))
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: controller.tooltip)
        .animation(.easeOut(duration: 0.18), value: pillHeight)
        .allowsHitTesting(false)
    }
}

// MARK: - Pill

struct FlowBarPill: View {
    let state: FlowBarState
    let isPointerOverPill: Bool
    let micActive: Bool
    let micSilent: Bool
    let isListening: Bool
    let meter: FlowBarLevelMeter
    /// Tints the waveform (purple in prompt mode).
    var accent: Color? = nil
    let onTap: () -> Void
    let onCancel: () -> Void
    let onFinish: () -> Void

    private var isHandsFree: Bool { state == .activeHandsFree }
    private var isProcessing: Bool { state == .processing }
    private var showsWaveform: Bool {
        switch state {
        case .initializing, .activePTT, .activeHandsFree, .processing, .error: return true
        case .hidden, .resting, .ready: return false
        }
    }
    /// Bars turn bright the moment the key goes down, and wiggle once the recorder is running
    /// (not after the mic's first buffer: that wait read as lag). Animating during start-up
    /// competed with it on the main thread. A dead mic still greys them.
    private var isBright: Bool { (state.isActive || state == .initializing) && !micSilent }
    private var isLive: Bool { state.isActive && !micSilent }

    var body: some View {
        let size = FlowBarMetrics.pillSize(for: state)
        let radius = FlowBarMetrics.cornerRadius(for: state)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack {
            micGlyph
                .opacity(state == .ready ? 1 : 0)

            HStack(spacing: 0) {
                FlowBarCircleButton(kind: .cancel, isEnabled: isListening, action: onCancel)
                    .frame(width: isHandsFree ? FlowBarMetrics.buttonSize : 0)
                    .scaleEffect(isHandsFree ? 1 : 0.01)
                    .opacity(isHandsFree ? 1 : 0)
                    .allowsHitTesting(isHandsFree)
                Color.clear.frame(width: isHandsFree ? FlowBarMetrics.buttonSpacing : 0, height: 1)

                FlowBarWaveform(meter: meter, isLive: isLive, isBright: isBright)
                    .colorMultiply(accent ?? .white)

                Color.clear.frame(width: isHandsFree ? FlowBarMetrics.buttonSpacing : 0, height: 1)
                FlowBarCircleButton(kind: .finish, isEnabled: isListening, action: onFinish)
                    .frame(width: isHandsFree ? FlowBarMetrics.buttonSize : 0)
                    .scaleEffect(isHandsFree ? 1 : 0.01)
                    .opacity(isHandsFree ? 1 : 0)
                    .allowsHitTesting(isHandsFree)

                Color.clear.frame(width: isProcessing ? 6 : 0, height: 1)
                FlowBarSpinner(isAnimating: isProcessing)
                    .frame(width: isProcessing ? 16 : 0, height: 16)
                    .opacity(isProcessing ? 1 : 0)
            }
            .opacity(showsWaveform ? 1 : 0)
        }
        // Hidden children (waveform, buttons) must not stretch the pill: the background is
        // pinned to the state's exact size and everything outside it is clipped.
        .frame(width: size.width, height: size.height)
        .background(
            ZStack {
                shape.fill(FlowBarMetrics.fill(for: state, pointerOverPill: isPointerOverPill))
                shape.strokeBorder(
                    FlowBarMetrics.border(for: state, pointerOverPill: isPointerOverPill),
                    lineWidth: FlowBarMetrics.borderWidth(for: state)
                )
            }
            .frame(width: size.width, height: size.height)
        )
        .clipShape(shape)
        .frame(width: size.width, height: size.height)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .animation(FlowBarMetrics.morph, value: state)
        .animation(FlowBarMetrics.morph, value: isPointerOverPill)
    }

    @ViewBuilder
    private var micGlyph: some View {
        if let mic = FlowIconName(rawValue: "mic") {
            FlowIcon(mic, size: 16, stroke: 2, color: .white)
                .frame(width: 12, height: 16)
                .allowsHitTesting(false)
        } else {
            Image(systemName: "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: 12, height: 16)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Hands-free buttons

struct FlowBarCircleButton: View {
    enum Kind { case cancel, finish }

    let kind: Kind
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(kind == .cancel ? FlowBarPalette.cancelFill : FlowBarPalette.light)
                glyph
                    .stroke(
                        kind == .cancel ? FlowBarPalette.light : FlowBarPalette.dark,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 12, height: 12)
            }
            .frame(width: FlowBarMetrics.buttonSize, height: FlowBarMetrics.buttonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(kind == .cancel ? "Cancel" : "Finish and paste")
    }

    private var glyph: FlowBarGlyphShape {
        FlowBarGlyphShape(kind: kind == .cancel ? .cross : .check)
    }
}

/// Lucide-style "x" and check glyphs drawn in a 24 pt box and scaled to the frame.
struct FlowBarGlyphShape: Shape {
    enum Kind { case cross, check }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        var path = Path()
        switch kind {
        case .cross:
            path.move(to: point(6, 6))
            path.addLine(to: point(18, 18))
            path.move(to: point(18, 6))
            path.addLine(to: point(6, 18))
        case .check:
            path.move(to: point(20, 6))
            path.addLine(to: point(9, 17))
            path.addLine(to: point(4, 12))
        }
        return path
    }
}


/// Round badge beside the pill for a special dictation mode (prompt mode, Ask Siri).
struct FlowBarModeBadge: View {
    let badge: FlowModeBadge
    static let size: CGFloat = 30

    var body: some View {
        Image(systemName: badge.systemImage)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(badge == .siri ? .multicolor : .monochrome)
            .foregroundStyle(badge == .prompt ? FlowBarPalette.promptAccent : FlowBarPalette.activeBar)
            .frame(width: Self.size, height: Self.size)
            .background(Circle().fill(Color.black.opacity(0.85)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .accessibilityLabel(badge == .prompt ? "Prompt mode" : "Asking Siri")
    }
}
