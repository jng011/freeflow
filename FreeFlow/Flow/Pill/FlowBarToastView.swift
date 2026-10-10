import SwiftUI

// MARK: - Morph host

/// Hosts one toast or card. The container starts at the pill's geometry, springs to the
/// content's size, fades the content in, and on dismissal collapses back to the resting pill.
struct FlowBarToastHost: View {
    @ObservedObject var controller: FlowBarController
    let presentation: FlowBarPresentation

    private enum Stage { case start, expanded, collapsing }

    @State private var stage: Stage = .start
    @State private var contentVisible = false
    @State private var measured: CGSize = .zero

    private static let morph = Animation.spring(duration: 0.42, bounce: 0)

    private var isDismissing: Bool {
        controller.dismissingPresentationID == presentation.id
    }

    private var isStandardToast: Bool {
        if case .toast(let toast) = presentation.kind { return toast.style == .standard }
        return false
    }

    private var chrome: FlowBarToastChrome {
        FlowBarToastChrome(kind: presentation.kind)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            shapeLayer
            contentLayer
        }
        .onAppear {
            // Let the first layout pass measure the content before springing open.
            DispatchQueue.main.async {
                withAnimation(Self.morph) {
                    stage = .expanded
                }
                withAnimation(.easeOut(duration: 0.18).delay(0.1)) {
                    contentVisible = true
                }
            }
        }
        .onChange(of: isDismissing) { _, dismissing in
            guard dismissing else { return }
            withAnimation(.easeOut(duration: 0.12)) {
                contentVisible = false
            }
            withAnimation(Self.morph.delay(0.12)) {
                stage = .collapsing
            }
        }
    }

    // MARK: Shape

    private var geometry: (size: CGSize, radius: CGFloat, fill: Color, border: Color, opacity: Double) {
        switch stage {
        case .start:
            let origin = presentation.originState
            return (
                FlowBarMetrics.pillSize(for: origin),
                FlowBarMetrics.cornerRadius(for: origin),
                FlowBarMetrics.fill(for: origin, pointerOverPill: false),
                FlowBarMetrics.border(for: origin, pointerOverPill: false),
                1
            )
        case .expanded:
            let size = measured == .zero ? FlowBarMetrics.pillSize(for: presentation.originState) : measured
            return (size, chrome.radius, chrome.fill, FlowBarPalette.border, 1)
        case .collapsing:
            return (
                FlowBarMetrics.pillSize(for: .resting),
                FlowBarMetrics.cornerRadius(for: .resting),
                FlowBarPalette.restingFill,
                FlowBarPalette.restingBorder,
                0
            )
        }
    }

    private var shapeLayer: some View {
        let geo = geometry
        let shape = RoundedRectangle(cornerRadius: geo.radius, style: .continuous)
        return ZStack(alignment: .bottom) {
            geo.fill
                .animation(.easeOut(duration: 0.22), value: stage)
            if presentation.showsProgress, !isStandardToast {
                FlowBarDrainingBar(controller: controller, isRunning: stage == .expanded && !isDismissing)
                    .opacity(contentVisible ? 1 : 0)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(geo.border, lineWidth: 1)
                .animation(.easeOut(duration: 0.22), value: stage)
        )
        .shadow(color: FlowBarPalette.shadow.opacity(chrome.hasShadow && stage == .expanded ? 0.1 : 0), radius: 7.5, x: 0, y: 10)
        .shadow(color: FlowBarPalette.shadow.opacity(chrome.hasShadow && stage == .expanded ? 0.1 : 0), radius: 3, x: 0, y: 4)
        .opacity(geo.opacity)
        .animation(Self.morph, value: measured)
        .allowsHitTesting(false)
    }

    // MARK: Content

    private var contentLayer: some View {
        content
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                measured = size
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(FlowBarMetrics.coordinateSpace))
            } action: { frame in
                controller.updatePresentationFrame(frame, id: presentation.id)
            }
            .opacity(contentVisible ? 1 : 0)
            .allowsHitTesting(stage == .expanded && !isDismissing)
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.kind {
        case .card(let text):
            FlowNoTextboxCard(
                text: text,
                copied: controller.cardCopied,
                onCopy: { controller.copyCardText() },
                onClose: { controller.dismissToast(ifCurrent: presentation.id) }
            )
        case .toast(let toast):
            switch toast.style {
            case .mini:
                FlowBarMiniToast(toast: toast) {
                    controller.performToastAction(primary: true)
                }
            case .condensed:
                FlowBarCondensedToast(toast: toast) {
                    controller.performToastAction(primary: true)
                }
            case .standard:
                FlowBarStandardToast(
                    toast: toast,
                    countdown: presentation.showsProgress ? controller : nil,
                    isCountdownRunning: stage == .expanded && !isDismissing,
                    onPrimary: { controller.performToastAction(primary: true) },
                    onSecondary: { controller.performToastAction(primary: false) },
                    onClose: { controller.dismissToast(ifCurrent: presentation.id) }
                )
            }
        }
    }
}

/// Container look per toast kind.
struct FlowBarToastChrome {
    let radius: CGFloat
    let fill: Color
    let hasShadow: Bool

    init(kind: FlowBarPresentation.Kind) {
        switch kind {
        case .card:
            radius = 24
            fill = FlowBarPalette.black
            hasShadow = false
        case .toast(let toast):
            switch toast.style {
            case .mini:
                radius = 20
                fill = FlowBarPalette.black
                hasShadow = false
            case .condensed:
                radius = 24
                fill = FlowBarPalette.condensedFill
                hasShadow = true
            case .standard:
                radius = 16
                fill = FlowBarPalette.black
                hasShadow = false
            }
        }
    }
}

// MARK: - Draining bar

/// 3 pt bar at the very bottom: lumen fill anchored left over a grey track, draining right to left.
struct FlowBarDrainingBar: View {
    @ObservedObject var controller: FlowBarController
    let isRunning: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isRunning || controller.isToastPaused)) { context in
            let fraction = controller.remainingFraction(at: context.date)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    FlowBarPalette.progressTrack
                    FlowBarPalette.lumen
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 3)
        }
        .frame(height: 3)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Width helper

/// Proposes the child's ideal width clamped to [minWidth, maxWidth] and hugs the result, so
/// short content stays narrow and long content truncates or wraps at the cap.
struct FlowBarClampedWidth: Layout {
    var minWidth: CGFloat = 0
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = resolvedWidth(child: child, proposal: proposal)
        let height = child.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        child.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }

    private func resolvedWidth(child: LayoutSubview, proposal: ProposedViewSize) -> CGFloat {
        let ideal = child.sizeThatFits(.unspecified).width
        var width = min(max(ideal, minWidth), maxWidth)
        if let available = proposal.width, available.isFinite {
            width = min(width, available)
        }
        return width.rounded(.up)
    }
}

// MARK: - Icon helper

struct FlowBarToastIcon: View {
    let name: FlowIconName
    let size: CGFloat
    let color: Color

    var body: some View {
        FlowIcon(name, size: size, stroke: 2, color: color)
            .frame(width: size, height: size)
    }
}

// MARK: - Mini

struct FlowBarMiniToast: View {
    let toast: FlowBarToast
    let onAction: () -> Void

    @State private var isHovered = false

    private var isClickable: Bool { toast.action != nil }

    var body: some View {
        FlowBarClampedWidth(maxWidth: 440) {
            HStack(spacing: 6) {
                if let icon = toast.icon {
                    FlowBarToastIcon(name: icon, size: 16, color: FlowBarPalette.light)
                }
                Text(toast.title)
                    .font(FlowFont.sans(15, weight: 400))
                    .foregroundStyle(FlowBarPalette.light)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let actionTitle = toast.actionTitle {
                    Text(actionTitle)
                        .font(FlowFont.sans(15, weight: 600))
                        .foregroundStyle(FlowBarPalette.secondaryText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, 4)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isClickable && isHovered ? FlowBarPalette.miniHover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture {
            if isClickable { onAction() }
        }
    }
}

// MARK: - Condensed

struct FlowBarCondensedToast: View {
    let toast: FlowBarToast
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            FlowBarClampedWidth(maxWidth: 300) {
                HStack(spacing: 6) {
                    if let icon = toast.icon {
                        FlowBarToastIcon(name: icon, size: 16, color: FlowBarPalette.light)
                    }
                    Text(toast.title)
                        .font(FlowFont.sans(15, weight: 550))
                        .foregroundStyle(FlowBarPalette.light)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let actionTitle = toast.actionTitle {
                FlowBarCondensedActionButton(title: actionTitle, action: onAction)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        // Keep the label clear of the 3 pt draining bar.
        .padding(.bottom, toast.showsProgress ? 3 : 0)
    }
}

struct FlowBarCondensedActionButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FlowFont.sans(15, weight: 400))
                .foregroundStyle(FlowBarPalette.light)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(FlowBarFillButtonStyle(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }
}

/// White 8% fill, 12% on hover, 16% pressed. Padding 6 x 10, radius 8.
struct FlowBarFillButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let alpha: Double = configuration.isPressed ? 0.16 : (isHovered ? 0.12 : 0.08)
        return configuration.label
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(alpha))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Standard

struct FlowBarStandardToast: View {
    let toast: FlowBarToast
    /// When set, the close button wears a ring that drains with the toast's time left.
    var countdown: FlowBarController? = nil
    var isCountdownRunning = false
    let onPrimary: () -> Void
    let onSecondary: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let badge = toast.badge {
                Text(badge)
                    .font(FlowFont.sans(12, weight: 550))
                    .foregroundStyle(FlowBarPalette.dark)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(FlowBarPalette.badgeFill)
                    )
                    .padding(.bottom, 10)
            }

            HStack(alignment: .top, spacing: 8) {
                if toast.isError, let alert = FlowIconName(rawValue: "circle-alert") {
                    FlowBarToastIcon(name: alert, size: 16, color: FlowBarPalette.errorBorder)
                        .padding(.top, 2)
                } else if toast.isWarning {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(FlowBarPalette.warning)
                        .frame(width: 18, height: 18)
                        .padding(.top, 1)
                }
                Text(toast.title)
                    .font(FlowFont.sans(15, weight: 600))
                    .foregroundStyle(FlowBarPalette.light)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.trailing, countdown == nil ? 24 : 40)

            if let bodyText = toast.body, !bodyText.isEmpty {
                Text(bodyText)
                    .font(FlowFont.sans(15, weight: 400))
                    .foregroundStyle(FlowBarPalette.mutedText)
                    .lineSpacing(3)
                    .lineLimit(8)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            if toast.actionTitle != nil || toast.secondaryActionTitle != nil {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if let secondary = toast.secondaryActionTitle {
                        FlowBarSecondaryActionButton(title: secondary, action: onSecondary)
                    }
                    if let primary = toast.actionTitle {
                        FlowBarPrimaryActionButton(title: primary, action: onPrimary)
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(20)
        .frame(width: countdown == nil ? 400 : nil, alignment: .leading)
        .modifier(FlowBarHugWidth(enabled: countdown != nil, maxWidth: 400))
        .overlay(alignment: .topTrailing) {
            if let countdown {
                FlowBarCountdownCloseButton(controller: countdown, isRunning: isCountdownRunning, action: onClose)
                    .padding(.top, 15)
                    .padding(.trailing, 17)
            } else {
                FlowBarSmallCloseButton(action: onClose)
                    .padding(.top, 12)
                    .padding(.trailing, 12)
            }
        }
    }
}

struct FlowBarPrimaryActionButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FlowFont.sans(15, weight: 600))
                .foregroundStyle(FlowBarPalette.light)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? FlowBarPalette.primaryActionHover : FlowBarPalette.primaryAction)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct FlowBarSecondaryActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FlowFont.sans(15, weight: 600))
                .foregroundStyle(FlowBarPalette.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Hugs the content's ideal width up to `maxWidth` (text wraps past it).
struct FlowBarHugWidth: ViewModifier {
    let enabled: Bool
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            FlowBarClampedWidth(maxWidth: maxWidth) { content }
        } else {
            content
        }
    }
}

/// 30 pt round close button whose ring drains clockwise as the toast's time runs out.
struct FlowBarCountdownCloseButton: View {
    @ObservedObject var controller: FlowBarController
    let isRunning: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: nil, paused: !isRunning || controller.isToastPaused)) { context in
                let fraction = controller.remainingFraction(at: context.date)
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                    Circle()
                        .stroke(FlowBarPalette.progressTrack, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    FlowBarGlyphShape(kind: .cross)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                        .frame(width: 11, height: 11)
                }
                .frame(width: 30, height: 30)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Close")
    }
}

/// 20 pt "x" used by standard toasts.
struct FlowBarSmallCloseButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            FlowBarGlyphShape(kind: .cross)
                .stroke(
                    Color.white.opacity(isHovered ? 0.9 : 0.6),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .frame(width: 12, height: 12)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Close")
    }
}
