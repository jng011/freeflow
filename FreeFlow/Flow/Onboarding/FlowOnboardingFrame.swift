import AppKit
import SwiftUI

// Layout pieces of the onboarding window: draggable header with the section
// tracker, the 2 pt progress bar, and the left (text + CTA) / right (demo) split.

/// The four sections shown in the header tracker.
enum FlowOnboardingSection: Int, CaseIterable, Identifiable {
    case getStarted, permissions, setUp, learn

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .getStarted: return "Get started"
        case .permissions: return "Permissions"
        case .setUp: return "Set up"
        case .learn: return "Learn"
        }
    }
}

/// Animation used by the onboarding: cubic-bezier(0.05, 0.6, 0.4, 0.95).
enum FlowOnboardingMotion {
    static let expand = Animation.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.2)
    static let progress = Animation.easeInOut(duration: 0.3)
    static let page = Animation.easeInOut(duration: 0.2)
}

// MARK: - Header

/// 52 pt draggable header with the centered section tracker.
struct FlowOnboardingHeader: View {
    let current: FlowOnboardingSection

    var body: some View {
        ZStack {
            FlowWindowDragArea()
            HStack(spacing: 0) {
                ForEach(FlowOnboardingSection.allCases) { section in
                    if section.rawValue > 0 {
                        FlowIcon(.chevronRight, size: 16, stroke: 1.75, color: FlowColor.neutral500)
                            .padding(.horizontal, 16)
                    }
                    Text(section.title.uppercased())
                        .flowText(.label)
                        .foregroundStyle(section == current ? FlowColor.foreground : FlowColor.neutral500)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .allowsHitTesting(false)
            .animation(FlowMotion.standard, value: current)
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
    }
}

/// 2 pt neutral200 track with a dawn700 fill.
struct FlowOnboardingProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(FlowColor.neutral200)
                Rectangle()
                    .fill(FlowColor.dawn700)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 2)
        .animation(FlowOnboardingMotion.progress, value: fraction)
    }
}

// MARK: - Split layout

/// One onboarding page: text and actions on the left, a demo panel on the right.
struct FlowOnboardingSplit<Header: View, Content: View, Right: View>: View {
    var showsBack: Bool
    var onBack: () -> Void
    var ctaTitle: String?
    var ctaEnabled: Bool = true
    var onCTA: () -> Void
    var rightFill: Color = FlowColor.neutral200
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var right: Right

    var body: some View {
        GeometryReader { proxy in
            let leftWidth = min(577, max(420, proxy.size.width * 0.6))
            let horizontalPadding: CGFloat = leftWidth >= 577 ? 108 : 48
            HStack(spacing: 0) {
                leftPanel(horizontalPadding: horizontalPadding)
                    .frame(width: leftWidth)
                    .frame(maxHeight: .infinity)
                    .background(FlowColor.background)

                ZStack {
                    rightFill
                    // Centered vertically; scrolls only when the window is too short.
                    ScrollView {
                        right
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: max(0, proxy.size.height - 48), alignment: .center)
                            .padding(24)
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func leftPanel(horizontalPadding: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if showsBack {
                    FlowOnboardingBackButton(action: onBack)
                }
                VStack(alignment: .leading, spacing: 12) {
                    header
                }
                .frame(maxWidth: 360, alignment: .leading)

                content

                if let ctaTitle {
                    Button(ctaTitle, action: onCTA)
                        .buttonStyle(FlowButtonStyle(variant: .primary, size: .lg, fullWidth: true))
                        .disabled(!ctaEnabled)
                }
            }
            .padding(.vertical, 40)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

/// Title (32/40 weight 600) and description (18/28 weight 550) used at the top of each page.
struct FlowOnboardingTitle: View {
    let title: String
    var description: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(FlowFont.sans(32, weight: 600))
                .lineSpacing(max(0, 40 - 32 * 1.2))
                .foregroundStyle(FlowColor.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if let description {
                Text(description)
                    .flowText(.lgEmph)
                    .foregroundStyle(FlowColor.foregroundTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Link-style "Back" with a 16 pt chevron-left.
struct FlowOnboardingBackButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                FlowIcon(.chevronLeft, size: 16, stroke: 1.75, color: color)
                Text("Back")
                    .flowText(.smEmph)
                    .foregroundStyle(color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyleLink()
    }

    private var color: Color {
        isHovered ? FlowColor.foreground : FlowColor.foregroundTertiary
    }
}

/// White card used for the demo widgets on the right panel (padding 24, gap 24, lg shadow).
struct FlowOnboardingWidgetCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            content
        }
        .padding(24)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FlowColor.background))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(FlowColor.border, lineWidth: 1))
        .flowShadow(.lg)
    }
}
