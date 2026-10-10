@preconcurrency import AVFoundation
import Foundation
import os

final class SoundPlaybackEngine: @unchecked Sendable {
    enum Key: Hashable {
        case slot(FlowSoundSlot)
        /// Dismiss sound (Esc / user cancel). Always the pack's stop file.
        case esc
    }

    struct Source {
        let url: URL
        let volume: Float
    }

    private let queue = DispatchQueue(label: "com.jaydenghiyam.parle.soundPlayback", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "SoundPlaybackEngine")

    private var players: [Key: AVAudioPlayer] = [:]
    private var loadedSources: [Key: URL] = [:]
    private var previewPlayer: AVAudioPlayer?

    /// Replaces the preloaded players. Players whose URL did not change are kept.
    func load(_ sources: [Key: Source]) {
        queue.async { [weak self] in
            guard let self else { return }

            var next: [Key: AVAudioPlayer] = [:]
            var nextURLs: [Key: URL] = [:]
            for (key, source) in sources {
                if let existing = self.players[key], self.loadedSources[key] == source.url {
                    existing.volume = source.volume
                    next[key] = existing
                } else if let player = self.makePlayer(from: source.url, volume: source.volume) {
                    next[key] = player
                } else {
                    continue
                }
                nextURLs[key] = source.url
            }
            for (key, player) in self.players where next[key] !== player {
                if player.isPlaying { player.stop() }
            }
            self.players = next
            self.loadedSources = nextURLs
        }
    }

    /// Plays a preloaded sound. If it is already playing it restarts from 0.
    func play(_ key: Key) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let player = self.players[key] else {
                self.logger.debug("No player loaded for sound \(String(describing: key), privacy: .public)")
                return
            }
            // pause(), not stop(): stop() undoes prepareToPlay, so the next sound would
            // start the audio output from cold and land late.
            if player.isPlaying {
                player.pause()
            }
            player.currentTime = 0
            player.play()
            let rearm = player.duration + 0.05
            self.queue.asyncAfter(deadline: .now() + rearm) { [weak player] in
                guard let player, !player.isPlaying else { return }
                player.currentTime = 0
                player.prepareToPlay()
            }
        }
    }

    /// Plays a one-off file (settings preview) without touching the preloaded players.
    func playOnce(url: URL, volume: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.previewPlayer?.stop()
            self.previewPlayer = self.makePlayer(from: url, volume: volume)
            self.previewPlayer?.play()
        }
    }

    private func makePlayer(from url: URL, volume: Float) -> AVAudioPlayer? {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = volume
            player.prepareToPlay()
            return player
        } catch {
            logger.error(
                "Failed to load sound \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }
}
