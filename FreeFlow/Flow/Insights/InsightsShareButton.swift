import SwiftUI

/// 56 pt round share button with "SHARE · SHARE · SHARE · " circling it.
struct InsightsShareButton: View {
    /// 0 usage, 1 voice (ring color).
    var tab: Int
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private static let ringText = Array("SHARE \u{00B7} SHARE \u{00B7} SHARE \u{00B7} ")
    private static let period: Double = 12

    private var ringColor: Color {
        let dark = colorScheme == .dark
        if tab == 1 { return dark ? FlowColor.chord300 : FlowColor.chord600 }
        return dark ? FlowColor.fathom400 : FlowColor.fathom950
    }

    private var isPaused: Bool { reduceMotion || controlActiveState != .key }

    var body: some View {
        Button(action: action) {
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { context in
                    let seconds = context.date.timeIntervalSinceReferenceDate
                    let angle = reduceMotion ? 0 : (seconds.truncatingRemainder(dividingBy: Self.period) / Self.period) * 360
                    ring.rotationEffect(.degrees(angle))
                }
                Circle()
                    .fill(isHovered ? FlowColor.backgroundTertiary : FlowColor.shadeWhite)
                    .overlay(Circle().stroke(FlowColor.border, lineWidth: 1))
                    .frame(width: 56, height: 56)
                InsightsIcon("share", fallback: "square.and.arrow.up", size: 20, color: FlowColor.foreground)
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(FlowMotion.standard, value: isHovered)
        .accessibilityLabel("Share your insights")
    }

    private var ring: some View {
        let characters = Self.ringText
        let radius: CGFloat = 36
        return ZStack {
            ForEach(characters.indices, id: \.self) { index in
                Text(String(characters[index]))
                    .font(FlowFont.sans(10, weight: 600))
                    .foregroundStyle(ringColor)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(Double(index) / Double(characters.count) * 360))
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityHidden(true)
    }
}
