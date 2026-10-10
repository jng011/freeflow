import Foundation

/// Turns the engine's input level (dBFS) into the 0...1 level L that scales the waveform.
///
/// 1. Poll `FlowDictationState.currentInputLevelDB()` at 20 Hz.
/// 2. Every 150 ms, average the samples into D.
/// 3. Adaptive floor F starts at 0 each session; whenever D < F, F = max(-60, D).
/// 4. target = clamp((D - F) / 20, 0, 1).
/// 5. Per display frame: L = floor(100 * (0.85 * L + 0.15 * target)) / 100.
///
/// Not observable on purpose: the waveform's TimelineView pulls `advance()` once per frame, so
/// nothing ticks while the bar is resting.
@MainActor
final class FlowBarLevelMeter {
    private var timer: Timer?
    private var samples: [Float] = []
    private var lastAverageAt = Date()
    private var floorDB: Float = 0
    private var target: Double = 0
    private var level: Double = 0

    var isRunning: Bool { timer != nil }

    /// Starts a session. No-op when already running (PTT to hands-free keeps the floor).
    func start() {
        guard timer == nil else { return }
        samples.removeAll(keepingCapacity: true)
        floorDB = 0
        target = 0
        level = 0
        lastAverageAt = Date()

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        samples.removeAll(keepingCapacity: true)
        target = 0
        level = 0
    }

    /// Advances the smoothed level by one display frame and returns it.
    func advance() -> Double {
        // Fast attack so the bars answer the voice at once, slower release so they don't flicker.
        let rate = target > level ? 0.35 : 0.15
        let next = (1 - rate) * level + rate * target
        level = (100 * next).rounded(.down) / 100
        return level
    }

    private func poll() {
        let db = FlowDictationState.shared.currentInputLevelDB()
        samples.append(db.isFinite ? db : -160)

        let now = Date()
        guard now.timeIntervalSince(lastAverageAt) >= 0.05, !samples.isEmpty else { return }
        lastAverageAt = now

        let average = samples.reduce(0, +) / Float(samples.count)
        samples.removeAll(keepingCapacity: true)

        if average < floorDB {
            floorDB = max(-60, average)
        }
        target = Double(min(1, max(0, (average - floorDB) / 20)))
    }
}
