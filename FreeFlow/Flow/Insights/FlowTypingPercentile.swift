import Foundation

/// Share of keyboard typists slower than a given speed. Linear interpolation over a static table.
enum FlowTypingPercentile {
    static let tooltip = "Compared to typical keyboard typing speeds"

    private static let table: [(wpm: Double, percentile: Double)] = [
        (0, 0), (20, 13), (30, 30), (40, 52), (50, 70), (60, 84), (70, 92),
        (80, 96), (90, 98), (100, 99), (120, 99.7), (150, 99.95), (200, 99.99),
    ]

    /// Percentile (0...99.99) of typists slower than `wpm`.
    static func percentile(forWPM wpm: Int) -> Double {
        let value = Double(max(0, wpm))
        guard let last = table.last else { return 0 }
        if value >= last.wpm { return last.percentile }
        for index in 1..<table.count {
            let lower = table[index - 1]
            let upper = table[index]
            if value <= upper.wpm {
                let t = (value - lower.wpm) / (upper.wpm - lower.wpm)
                return lower.percentile + t * (upper.percentile - lower.percentile)
            }
        }
        return last.percentile
    }

    /// "Top N%" value: 100 minus the percentile.
    static func topPercent(forWPM wpm: Int) -> Double {
        100 - percentile(forWPM: wpm)
    }

    /// Below 1: one decimal (minimum 0.1). Otherwise a whole number capped at 99.
    static func displayTopPercent(_ top: Double) -> String {
        if top < 1 {
            let clamped = max(0.1, (top * 10).rounded() / 10)
            return String(format: "%.1f", clamped)
        }
        return String(min(99, Int(top.rounded())))
    }
}
