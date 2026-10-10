import SwiftUI

/// Original five-bar waveform mark, defined in a 21x20 box.
struct FlowLogoBarsShape: Shape {
    static let designSize = CGSize(width: 21, height: 20)
    static let barWidth: CGFloat = 2.6
    static let barXs: [CGFloat] = [1, 5.4, 9.2, 13, 17.4]
    static let barHeights: [CGFloat] = [9, 14, 19, 12, 16]
    static let centerY: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / Self.designSize.width, rect.height / Self.designSize.height)
        let offsetX = rect.minX + (rect.width - Self.designSize.width * scale) / 2
        let offsetY = rect.minY + (rect.height - Self.designSize.height * scale) / 2
        let radius = Self.barWidth / 2 * scale

        var path = Path()
        for (x, height) in zip(Self.barXs, Self.barHeights) {
            let bar = CGRect(
                x: offsetX + x * scale,
                y: offsetY + (Self.centerY - height / 2) * scale,
                width: Self.barWidth * scale,
                height: height * scale
            )
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}

/// The Flow logo mark. Default size is the sidebar's 21x20.
struct FlowLogoMark: View {
    var height: CGFloat = 20
    var color: Color = FlowColor.logoFill

    init(height: CGFloat = 20, color: Color = FlowColor.logoFill) {
        self.height = height
        self.color = color
    }

    var body: some View {
        FlowLogoBarsShape()
            .fill(color)
            .frame(
                width: height * FlowLogoBarsShape.designSize.width / FlowLogoBarsShape.designSize.height,
                height: height
            )
            .accessibilityLabel("Free Flow")
    }
}

/// The "Flow" wordmark: Figtree 22 weight 650, tracking -0.4.
struct FlowWordmark: View {
    var color: Color = FlowColor.logoFill

    var body: some View {
        Text("Flow")
            .font(FlowFont.sans(22, weight: 650))
            .tracking(-0.4)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}
