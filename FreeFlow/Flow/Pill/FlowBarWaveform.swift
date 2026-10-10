import AppKit
import SwiftUI

/// Ten-bar level waveform inside the pill. 46 x 18 including 4 pt side padding; bars may overflow
/// the box vertically.
struct FlowBarWaveform: View {
    let meter: FlowBarLevelMeter
    /// Bars react to audio and wiggle (active state, mic delivering sound, not silent).
    let isLive: Bool
    /// White bars once the mic is active; grey otherwise.
    let isBright: Bool

    static let width: CGFloat = 46
    static let height: CGFloat = 18

    private static let barCount = 10
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 2
    private static let minHeight: CGFloat = 2
    private static let phaseSteps: [Double] = [0, 1, 2, 3, 4, -5, -4, -3, -2, -1]
    private static let keyframes: [(t: Double, v: Double)] = [
        (0.0, 1.0), (0.2, 1.2), (0.4, 1.5), (0.8, 1.1), (0.9, 1.3), (1.0, 1.0),
    ]

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isLive)) { context in
            let level = isLive ? meter.advance() : 0
            let time = context.date.timeIntervalSinceReferenceDate
            let wiggle = isLive && !reduceMotion

            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                        .fill(isBright ? FlowBarPalette.activeBar : FlowBarPalette.idleBar)
                        .frame(
                            width: Self.barWidth,
                            height: Self.barHeight(index: index, level: level, time: time, wiggle: wiggle)
                        )
                }
            }
            .frame(width: Self.width, height: Self.height)
        }
        .frame(width: Self.width, height: Self.height)
        .animation(FlowBarMetrics.morph, value: isBright)
        .allowsHitTesting(false)
    }

    static func bulge(_ index: Int) -> Double {
        let distance = abs(4.5 - Double(index))
        return max(0, 1 - distance * distance / 48)
    }

    static func barHeight(index: Int, level: Double, time: TimeInterval, wiggle: Bool) -> CGFloat {
        let audioScale = max(1, 5 * level)
        let mult = wiggle ? waveMultiplier(index: index, time: time) : 1
        return max(minHeight, CGFloat(2 * audioScale * bulge(index) * mult))
    }

    /// 1 s loop through the keyframes with smoothstep easing, offset 0.1 s per step.
    static func waveMultiplier(index: Int, time: TimeInterval) -> Double {
        var phase = (time + 0.1 * phaseSteps[index]).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }

        for segment in 0..<(keyframes.count - 1) {
            let a = keyframes[segment]
            let b = keyframes[segment + 1]
            if phase >= a.t && phase <= b.t {
                let u = (phase - a.t) / (b.t - a.t)
                let eased = u * u * (3 - 2 * u)
                return a.v + (b.v - a.v) * eased
            }
        }
        return 1
    }
}
