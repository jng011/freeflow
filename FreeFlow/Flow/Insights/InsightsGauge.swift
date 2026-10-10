import SwiftUI

/// Half circle speed gauge: track plus a fathom fill trimmed to the typing percentile.
struct InsightsGauge: View {
    /// 0...100
    var percentile: Double
    /// Display value for the "Top N%" label.
    var topPercentText: String
    var animated: Bool = true
    var trackColor: Color = FlowColor.gaugeTrack
    var fillColor: Color = FlowColor.fathom900
    var labelColor: Color = FlowColor.foreground
    var secondaryLabelColor: Color = FlowColor.foregroundTertiary

    @State private var shownFraction: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var targetFraction: Double { min(1, max(0, percentile / 100)) }

    var body: some View {
        ZStack(alignment: .bottom) {
            InsightsGaugeArc()
                .stroke(trackColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
            InsightsGaugeArc()
                .trim(from: 0, to: animated ? shownFraction : targetFraction)
                .stroke(fillColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))

            VStack(spacing: 0) {
                Text("Top")
                    .font(FlowFont.sans(16))
                    .foregroundStyle(secondaryLabelColor)
                Text("\(topPercentText)%")
                    .flowText(.h3)
                    .foregroundStyle(labelColor)
                    .monospacedDigit()
            }
            .padding(.bottom, 2)
        }
        .frame(width: 156, height: 86)
        .onAppear { animate(to: targetFraction) }
        .onChange(of: targetFraction) { _, newValue in animate(to: newValue) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Top \(topPercentText) percent of typing speeds")
    }

    private func animate(to value: Double) {
        if !animated || reduceMotion {
            shownFraction = value
        } else {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { shownFraction = value }
        }
    }
}

/// The arc M 8 78 A 70 70 0 0 1 148 78 in a 156x86 box, drawn left to right over the top.
struct InsightsGaugeArc: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 156
        let sy = rect.height / 86
        let center = CGPoint(x: 78, y: 78)
        let radius: CGFloat = 70
        var path = Path()
        let steps = 96
        for step in 0...steps {
            let angle = Double.pi + Double.pi * Double(step) / Double(steps)
            let point = CGPoint(
                x: rect.minX + (center.x + radius * CGFloat(cos(angle))) * sx,
                y: rect.minY + (center.y + radius * CGFloat(sin(angle))) * sy
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
