import Foundation

/// Estimates a smooth 0...1 progress value for a file job from the manager's
/// coarse phases. Each phase owns a slice of the bar and fills it with an
/// exponential approach towards 95% of the slice, so the bar keeps moving
/// without ever claiming to be done early.
enum FlowFileProgressEstimator {
    enum Phase: Equatable {
        case pending
        case loading
        case processingAudio
        case transcribing
        case enhancing
        case completed
    }

    /// Slice of the overall bar owned by each phase.
    static func range(for phase: Phase) -> ClosedRange<Double> {
        switch phase {
        case .pending: return 0...0
        case .loading: return 0...0.05
        case .processingAudio: return 0.05...0.15
        case .transcribing: return 0.15...0.85
        case .enhancing: return 0.85...0.98
        case .completed: return 1...1
        }
    }

    /// Expected number of seconds a phase takes.
    static func expectedSeconds(
        for phase: Phase,
        audioDuration: TimeInterval?,
        usingPC: Bool
    ) -> TimeInterval {
        let duration = max(0, audioDuration ?? 0)
        switch phase {
        case .pending, .completed:
            return 1
        case .loading:
            return 1
        case .processingAudio:
            return 1.5 + 0.01 * duration
        case .transcribing:
            return usingPC ? 2 + 0.08 * duration : 3 + 0.35 * duration
        case .enhancing:
            guard let audioDuration, audioDuration > 0 else { return 5 }
            // Roughly 150 spoken words per minute.
            let words = audioDuration / 60 * 150
            return 2 + words / 150
        }
    }

    /// Overall progress for a job that has been in `phase` for `elapsed` seconds.
    static func progress(
        phase: Phase,
        elapsed: TimeInterval,
        audioDuration: TimeInterval?,
        usingPC: Bool
    ) -> Double {
        let slice = range(for: phase)
        guard slice.upperBound > slice.lowerBound else { return slice.lowerBound }
        let expected = max(0.5, expectedSeconds(for: phase, audioDuration: audioDuration, usingPC: usingPC))
        let fraction = min(0.95, 1 - exp(-max(0, elapsed) / expected))
        return slice.lowerBound + (slice.upperBound - slice.lowerBound) * fraction
    }

    static func phaseText(_ phase: Phase) -> String {
        switch phase {
        case .pending: return "Waiting..."
        case .loading: return "Loading..."
        case .processingAudio: return "Preparing audio..."
        case .transcribing: return "Transcribing..."
        case .enhancing: return "Cleaning up..."
        case .completed: return "Done"
        }
    }

    static func phase(for status: QueueItemStatus) -> Phase? {
        switch status {
        case .pending: return .pending
        case .processing(let processingPhase):
            switch processingPhase {
            case .loading: return .loading
            case .processingAudio: return .processingAudio
            case .transcribing: return .transcribing
            case .enhancing: return .enhancing
            }
        case .completed: return .completed
        case .failed: return nil
        }
    }
}
