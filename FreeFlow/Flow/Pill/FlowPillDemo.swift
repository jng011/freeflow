import Foundation

/// Plays every Flow Bar state on a loop with a synthetic voice level, for recording
/// the README animation. Nothing touches the microphone or the engine.
/// Launch with: open "Free Flow.app" --args -FlowPillDemo YES
@MainActor
enum FlowPillDemo {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "FlowPillDemo") }

    private static var levelTimer: Timer?
    private static var talking = false
    private static var tick = 0.0

    static func start() {
        guard isRequested else { return }
        let state = FlowDictationState.shared
        state.demoLevelDB = -160
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { updateLevel() }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            while true { await loop(state) }
        }
    }

    /// Speech-like envelope: syllables of 120 to 260 ms with short gaps.
    private static func updateLevel() {
        tick += 0.05
        guard talking else {
            FlowDictationState.shared.demoLevelDB = -70
            return
        }
        let syllable = abs(sin(tick * 9.5)) * (0.6 + 0.4 * abs(sin(tick * 2.3)))
        let jitter = Double.random(in: -3...3)
        FlowDictationState.shared.demoLevelDB = Float(-46 + 34 * syllable + jitter)
    }

    private static func loop(_ s: FlowDictationState) async {
        // 1. Hold fn and talk.
        await dictation(s, seconds: 2.8)
        await pause(1.4)
        // 2. Double tap: hands-free.
        s.setHandsFree(true)
        await dictation(s, seconds: 3.4, handsFree: true)
        await pause(1.4)
        // 3. Ctrl+fn: prompt mode.
        s.setModeBadge(.prompt)
        await dictation(s, seconds: 2.8, keepBadge: .prompt)
        await pause(1.4)
        // 4. "Ask Siri ..." shows the Siri badge once the words are heard.
        await dictation(s, seconds: 2.6, badgeAfter: (0.9, .siri))
        await pause(2.0)
    }

    private static func dictation(
        _ s: FlowDictationState, seconds: Double, handsFree: Bool = false,
        keepBadge: FlowModeBadge? = nil, badgeAfter: (Double, FlowModeBadge)? = nil
    ) async {
        s.recordingStateDidChange(to: .starting, from: .idle)
        if let keepBadge { s.setModeBadge(keepBadge) }
        try? await Task.sleep(for: .milliseconds(150))
        s.recordingStateDidChange(to: .recording, from: .starting)
        if handsFree { s.setHandsFree(true) }
        s.noteAudioReceived()
        talking = true
        if let badgeAfter {
            let (delay, badge) = badgeAfter
            try? await Task.sleep(for: .seconds(delay))
            s.setModeBadge(badge)
            try? await Task.sleep(for: .seconds(seconds - delay))
        } else {
            try? await Task.sleep(for: .seconds(seconds))
        }
        talking = false
        s.recordingStateDidChange(to: .transcribing, from: .recording)
        try? await Task.sleep(for: .seconds(1.1))
        s.recordingStateDidChange(to: .idle, from: .transcribing)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
