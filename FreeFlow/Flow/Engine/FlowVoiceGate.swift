import FluidAudio
import Foundation
import os

/// Settings for the two voice switches (Settings > General > Voice).
enum FlowVoiceSettings {
    /// "Only my voice": a dictation that doesn't sound like the owner isn't pasted.
    static let onlyMineKey = "FlowVoiceOnlyMine"
    /// "Drop other voices": stretches spoken by someone else are cut before transcribing.
    static let filterOthersKey = "FlowVoiceFilterOthers"
    static let voiceprintKey = "FlowVoiceprint"
    static let voiceprintDateKey = "FlowVoiceprintDate"

    static var onlyMine: Bool { UserDefaults.standard.bool(forKey: onlyMineKey) }
    static var filterOthers: Bool { UserDefaults.standard.bool(forKey: filterOthersKey) }
    static var anyEnabled: Bool { onlyMine || filterOthers }

    static var voiceprint: [Float]? {
        guard let data = UserDefaults.standard.data(forKey: voiceprintKey),
            data.count == FlowVoiceModel.embeddingDim * MemoryLayout<Float>.size
        else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static var voiceprintDate: Date? {
        UserDefaults.standard.object(forKey: voiceprintDateKey) as? Date
    }

    static func saveVoiceprint(_ vector: [Float]) {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        UserDefaults.standard.set(data, forKey: voiceprintKey)
        UserDefaults.standard.set(Date(), forKey: voiceprintDateKey)
    }

    static func clearVoiceprint() {
        UserDefaults.standard.removeObject(forKey: voiceprintKey)
        UserDefaults.standard.removeObject(forKey: voiceprintDateKey)
    }
}

/// The on-device speaker model: WeSpeaker (pyannote) via FluidAudio, on the Neural Engine.
/// About 100 MB while loaded, 40-50 ms per 3 s check. Loaded only while a voice switch is on.
/// Chosen over CAM++ after testing on the owner and a friend: CAM++ scored the friend
/// 0.62-0.74 (overlapping the owner), WeSpeaker 0.27-0.51 vs the owner's 0.59-0.86.
actor FlowVoiceModel {
    static let shared = FlowVoiceModel()
    static let embeddingDim = 256
    private var diarizer: DiarizerManager?
    private var loading: Task<DiarizerManager?, Never>?
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "VoiceGate")

    func load() async -> DiarizerManager? {
        if let diarizer { return diarizer }
        if let loading { return await loading.value }
        let task = Task<DiarizerManager?, Never> {
            do {
                let started = Date()
                let manager = DiarizerManager()
                manager.initialize(models: try await DiarizerModels.downloadIfNeeded())
                // The first prediction compiles the model (about 3 s); do it now, not mid-dictation.
                _ = try? manager.extractSpeakerEmbedding(from: [Float](repeating: 0.001, count: 48_000))
                self.logger.notice("voice model ready in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)ms")
                return manager
            } catch {
                self.logger.error("voice model failed to load: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        loading = task
        let manager = await task.value
        diarizer = manager
        loading = nil
        return manager
    }

    func unload() {
        diarizer = nil
    }

    /// L2-normalized speaker embedding of 16 kHz mono samples.
    func embed(_ samples: [Float]) async -> [Float]? {
        guard let manager = await load(), let raw = try? manager.extractSpeakerEmbedding(from: samples) else { return nil }
        return FlowVoiceMath.normalized(raw)
    }
}

enum FlowVoiceMath {
    static func normalized(_ v: [Float]) -> [Float] {
        let norm = max(sqrt(v.reduce(0) { $0 + $1 * $1 }), 1e-9)
        return v.map { $0 / norm }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors { for i in sum.indices { sum[i] += v[i] } }
        return normalized(sum)
    }

    static func rmsDB<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return -160 }
        let mean = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        return 10 * log10(max(mean, 1e-12))
    }
}

/// Live speaker check for one dictation. The recorder feeds 16 kHz audio while the person
/// talks; every 0.75 s a 1.5 s window is compared with the owner's voiceprint, so by
/// release the verdict is already known and nothing waits.
final class FlowVoiceGate: @unchecked Sendable {
    static let shared = FlowVoiceGate()

    struct Verdict {
        /// No speech window sounded like the owner.
        var notMine: Bool
        /// Best window similarity (for logs and tuning).
        var bestSimilarity: Float
        /// Audio with other voices removed, when some were found and some of the owner's remain.
        var filteredAudioURL: URL?
        var droppedSeconds: Double
    }

    // Measured with WeSpeaker on the owner's dictations vs a friend, 3 s windows:
    // owner's best window 0.59-0.85, friend's best 0.38-0.51; friend windows all <= 0.51,
    // owner windows >= 0.50. "Mine" needs one window >= 0.55; a window is dropped as someone
    // else only below 0.42, so a doubtful stretch is kept rather than cut.
    static let mineThreshold: Float = 0.55
    static let otherThreshold: Float = 0.42
    private static let sampleRate = 16_000
    private static let window = 48_000  // 3 s
    private static let hop = 24_000  // 1.5 s
    private static let speechDB: Float = -45

    private let queue = DispatchQueue(label: "com.jaydenghiyam.parle.voicegate")
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "VoiceGate")
    private var samples: [Float] = []
    private var nextWindow = 0
    /// End sample of the last window sent for scoring.
    private var scoredEnd = 0
    private var scores: [Int: (similarity: Float, speech: Bool)] = [:]
    private var pending: [Task<Void, Never>] = []
    private var voiceprint: [Float]?
    private var sessionID = UUID()
    private(set) var isActive = false

    /// Read on the recorder thread for every chunk: is a session listening?
    var wantsAudio: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return listening
    }
    private let stateLock = NSLock()
    private var listening = false

    private func setListening(_ value: Bool) {
        stateLock.lock(); listening = value; stateLock.unlock()
    }

    /// Starts a session when a switch is on and a voiceprint exists. Called at recording start.
    func begin() {
        guard FlowVoiceSettings.anyEnabled, let voiceprint = FlowVoiceSettings.voiceprint else {
            queue.sync { isActive = false }
            setListening(false)
            return
        }
        queue.sync {
            samples.removeAll(keepingCapacity: true)
            nextWindow = 0
            scoredEnd = 0
            scores = [:]
            pending.forEach { $0.cancel() }
            pending = []
            self.voiceprint = voiceprint
            sessionID = UUID()
            isActive = true
        }
        setListening(true)
        Task.detached(priority: .utility) { _ = await FlowVoiceModel.shared.load() }
    }

    func cancel() {
        setListening(false)
        queue.sync {
            isActive = false
            pending.forEach { $0.cancel() }
            pending = []
            samples = []
        }
    }

    /// 16-bit 16 kHz mono PCM from the recorder thread.
    func feed(_ data: Data) {
        queue.async { [self] in
            guard isActive else { return }
            data.withUnsafeBytes { raw in
                let ints = raw.bindMemory(to: Int16.self)
                samples.reserveCapacity(samples.count + ints.count)
                for value in ints { samples.append(Float(value) / 32_768) }
            }
            while nextWindow + Self.window <= samples.count {
                schedule(start: nextWindow, length: Self.window)
                nextWindow += Self.hop
            }
        }
    }

    /// Scores the last window(s) and decides. Usually instant: the windows were scored live.
    func finish() async -> Verdict? {
        setListening(false)
        let snapshot: (tasks: [Task<Void, Never>], id: UUID)? = queue.sync {
            guard isActive else { return nil }
            // A short dictation, or 0.5 s+ of tail after the last scored window.
            if samples.count - scoredEnd >= Self.sampleRate / 2 {
                let tailStart = max(0, samples.count - Self.window)
                schedule(start: tailStart, length: samples.count - tailStart)
            }
            return (pending, sessionID)
        }
        guard let snapshot else { return nil }
        for task in snapshot.tasks { await task.value }
        return queue.sync { () -> Verdict? in
            guard sessionID == snapshot.id else { return nil }
            isActive = false
            return decide()
        }
    }

    // MARK: - Private (on `queue`)

    private func schedule(start: Int, length: Int) {
        let slice = Array(samples[start..<(start + length)])
        scoredEnd = max(scoredEnd, start + length)
        let id = sessionID
        guard let voiceprint else { return }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let speech = FlowVoiceMath.rmsDB(slice) > Self.speechDB
            var similarity: Float = 0
            if speech, let embedding = await FlowVoiceModel.shared.embed(slice) {
                similarity = FlowVoiceMath.cosine(voiceprint, embedding)
            }
            self?.queue.async {
                guard let self, self.sessionID == id else { return }
                self.scores[start] = (similarity, speech)
            }
        }
        pending.append(task)
    }

    private func decide() -> Verdict {
        let speechWindows = scores.filter { $0.value.speech }
        let best = speechWindows.values.map(\.similarity).max() ?? 0
        defer { samples = [] }
        guard !speechWindows.isEmpty else {
            return Verdict(notMine: false, bestSimilarity: 0, filteredAudioURL: nil, droppedSeconds: 0)
        }
        // Too little voice to judge (a 1-2 s dictation scores low even for the owner):
        // never block it. Needs 3 s of speech before "not your voice" can fire.
        let speechSeconds = Double(speechWindows.count) * Double(Self.hop) / Double(Self.sampleRate)
        let enoughSpeech = samples.count >= Self.window && speechSeconds >= 3
        let notMine = enoughSpeech && best < Self.mineThreshold

        var filteredURL: URL?
        var dropped = 0.0
        if FlowVoiceSettings.filterOthers, !notMine {
            // Each 0.75 s step takes the mean score of the windows covering it.
            var keep = [Float]()
            keep.reserveCapacity(samples.count)
            var step = 0
            while step < samples.count {
                let end = min(step + Self.hop, samples.count)
                let covering = speechWindows.filter { $0.key <= step && $0.key + Self.window >= end }.map(\.value.similarity)
                let score = covering.isEmpty ? 1 : covering.reduce(0, +) / Float(covering.count)
                if score >= Self.otherThreshold {
                    keep.append(contentsOf: samples[step..<end])
                } else {
                    dropped += Double(end - step) / Double(Self.sampleRate)
                }
                step = end
            }
            if dropped > 0, !keep.isEmpty {
                filteredURL = Self.writeWAV(keep)
            }
        }
        let rounded = (best * 100).rounded() / 100
        logger.notice("voice verdict best=\(rounded, privacy: .public) windows=\(speechWindows.count, privacy: .public) notMine=\(notMine, privacy: .public) dropped=\(dropped, privacy: .public)s")
        return Verdict(notMine: notMine, bestSimilarity: best, filteredAudioURL: filteredURL, droppedSeconds: dropped)
    }

    private static func writeWAV(_ samples: [Float]) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-voice-filtered-\(UUID().uuidString).wav")
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(sampleRate).littleEndian); append(UInt32(sampleRate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(byteCount.littleEndian)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32_767).littleEndian)
        }
        return (try? data.write(to: url)) != nil ? url : nil
    }

    // MARK: - Enrollment

    /// Builds the owner's voiceprint from clean speech only. The first URL is the anchor (the
    /// longest recent dictation, e.g. the voice script); from every file only 3 s stretches
    /// within 6 dB of that file's loudest stretch and above -35 dB are used (no quiet tails or
    /// room noise), and stretches that don't match the anchor (someone else) are dropped.
    static func enroll(from urls: [URL]) async -> Int {
        let converter = AudioConverter(sampleRate: 16_000)
        var perFile: [[[Float]]] = []
        for url in urls {
            guard let audio = try? converter.resampleAudioFile(url), audio.count >= 48_000 else { continue }
            var stretches: [(db: Float, samples: [Float])] = []
            var start = 0
            while start + 48_000 <= audio.count {
                let chunk = Array(audio[start..<(start + 48_000)])
                stretches.append((FlowVoiceMath.rmsDB(chunk), chunk))
                start += 24_000
            }
            guard let loudest = stretches.map(\.db).max() else { continue }
            var embeddings: [[Float]] = []
            for stretch in stretches where stretch.db > max(loudest - 6, -35) {
                if let embedding = await FlowVoiceModel.shared.embed(stretch.samples) { embeddings.append(embedding) }
            }
            if !embeddings.isEmpty { perFile.append(embeddings) }
        }
        guard let anchorChunks = perFile.first, anchorChunks.count >= 2 else { return 0 }
        let anchor = FlowVoiceMath.mean(anchorChunks)
        let agreeing = perFile.flatMap { $0 }.filter { FlowVoiceMath.cosine(anchor, $0) >= 0.6 }
        FlowVoiceSettings.saveVoiceprint(FlowVoiceMath.mean(agreeing.count >= 2 ? agreeing : anchorChunks))
        return agreeing.count
    }
}
