import AVFoundation
import Foundation
import OSLog

/// Plays one history row's recording at a time.
@MainActor
final class FlowRowAudioPlayer: NSObject, ObservableObject {
    static let shared = FlowRowAudioPlayer()

    /// Rows older than this no longer offer playback.
    static let playableAge: TimeInterval = 14 * 24 * 60 * 60

    @Published private(set) var playingID: UUID?

    private var player: AVAudioPlayer?
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowRowAudioPlayer")

    private override init() {
        super.init()
    }

    func isPlaying(_ id: UUID) -> Bool {
        playingID == id
    }

    /// Starts `url` for row `id`, or stops it when that row is already playing.
    func toggle(id: UUID, url: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                logger.error("Playback did not start for \(url.lastPathComponent, privacy: .public)")
                return
            }
            self.player = player
            playingID = id
        } catch {
            logger.error("Could not open recording: \(error.localizedDescription, privacy: .public)")
            FlowToastCenter.shared.show("This recording could not be played.", style: .error)
        }
    }

    func stop() {
        player?.stop()
        player?.delegate = nil
        player = nil
        playingID = nil
    }

    /// Stops playback if `id` is the row that is playing (used before deleting a row).
    func stopIfPlaying(_ id: UUID) {
        if playingID == id {
            stop()
        }
    }
}

extension FlowRowAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == finished else { return }
            self.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failed = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == failed else { return }
            self.stop()
        }
    }
}
