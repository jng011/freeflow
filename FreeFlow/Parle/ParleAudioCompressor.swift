import AVFoundation

/// Shrinks a recording before it is sent to the server. FLAC is lossless, so the
/// transcript is identical to sending the WAV (lossy AAC changed words in testing),
/// at about 60% of the size.
enum ParleAudioCompressor {
    /// FLAC at the recording's own sample rate and channel count.
    /// Returns nil if anything fails, and the caller sends the WAV instead.
    static func flac(from wavURL: URL) -> Data? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("parle-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        guard encode(wavURL, to: outputURL) else { return nil }
        return try? Data(contentsOf: outputURL)
    }

    /// Separate function so the output file is closed (deinit) before it is read.
    private static func encode(_ inputURL: URL, to outputURL: URL) -> Bool {
        do {
            let input = try AVAudioFile(forReading: inputURL)
            let format = input.processingFormat
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitDepthHintKey: 16,
            ]
            let output = try AVAudioFile(
                forWriting: outputURL, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else { return false }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            return true
        } catch {
            return false
        }
    }
}
