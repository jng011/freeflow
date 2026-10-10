import SwiftUI

/// 16 x 16 eight-bar activity spinner shown while processing.
struct FlowBarSpinner: View {
    var isAnimating: Bool = true

    private static let barCount = 8
    private static let period: Double = 1.1
    private static let step: Double = 0.1375
    private static let color = Color(red: 163 / 255, green: 148 / 255, blue: 199 / 255)

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isAnimating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Self.color)
                        .frame(width: 2, height: 5)
                        .opacity(Self.opacity(index: index, time: time))
                        .offset(y: -6)
                        .frame(width: 16, height: 16)
                        .rotationEffect(.degrees(45 * Double(index)))
                }
            }
            .frame(width: 16, height: 16)
        }
        .frame(width: 16, height: 16)
        .allowsHitTesting(false)
    }

    /// Each bar fades 0.88 to 0.15 over 1.1 s, bar i started 0.1375 * (7 - i) s earlier.
    static func opacity(index: Int, time: TimeInterval) -> Double {
        var phase = (time + step * Double(7 - index)).truncatingRemainder(dividingBy: period) / period
        if phase < 0 { phase += 1 }
        return 0.88 - 0.73 * phase
    }
}
