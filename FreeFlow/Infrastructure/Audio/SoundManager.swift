import Foundation
import SwiftUI

@MainActor
class SoundManager: ObservableObject {
    static let shared = SoundManager()

    private let playbackEngine = SoundPlaybackEngine()
    private var loadedPack: FlowSoundPack

    private init() {
        loadedPack = FlowSoundSettings.pack
        setupSounds()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadCustomSounds),
            name: NSNotification.Name("CustomSoundsChanged"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reloadCustomSounds),
            name: .flowSoundPackChanged,
            object: nil
        )
    }

    // MARK: - Loading

    private func setupSounds() {
        let pack = FlowSoundSettings.pack
        loadedPack = pack

        var sources: [SoundPlaybackEngine.Key: SoundPlaybackEngine.Source] = [:]
        for slot in FlowSoundSlot.allCases {
            let url: URL?
            switch slot {
            case .start:
                url = recordingSoundURL(for: .start, pack: pack)
            case .stop:
                url = recordingSoundURL(for: .stop, pack: pack)
            default:
                url = pack.url(for: slot)
            }
            if let url {
                sources[.slot(slot)] = SoundPlaybackEngine.Source(url: url, volume: slot.volume)
            }
        }
        if let escURL = pack.url(for: .stop) {
            sources[.esc] = SoundPlaybackEngine.Source(url: escURL, volume: FlowSoundSlot.stop.volume)
        }
        playbackEngine.load(sources)
    }

    /// A custom start/stop file still wins; any built-in choice plays the Flow pack;
    /// `.none` leaves the slot silent.
    private func recordingSoundURL(for type: CustomSoundManager.SoundType, pack: FlowSoundPack) -> URL? {
        let manager = CustomSoundManager.shared
        let slot: FlowSoundSlot = type == .start ? .start : .stop
        switch manager.soundSelection(for: type) {
        case .none:
            return nil
        case .builtIn:
            return pack.url(for: slot)
        case .custom:
            if let customURL = manager.getCustomSoundURL(for: type),
                FileManager.default.fileExists(atPath: customURL.path)
            {
                return customURL
            }
            return pack.url(for: slot)
        }
    }

    @objc private func reloadCustomSounds() {
        setupSounds()
    }

    /// Picks up a pack change written straight to UserDefaults (without the notification).
    private func syncPackIfNeeded() {
        if FlowSoundSettings.pack != loadedPack {
            setupSounds()
        }
    }

    private var canPlayExtraSounds: Bool {
        FlowSoundSettings.isEnabled && !FlowSoundSettings.isSuspended
    }

    private func play(_ key: SoundPlaybackEngine.Key) {
        syncPackIfNeeded()
        playbackEngine.play(key)
    }

    // MARK: - Recording sounds

    func playStartSound() {
        guard !FlowSoundSettings.isSuspended,
            CustomSoundManager.shared.isSoundEnabled(for: .start)
        else { return }
        play(.slot(.start))
    }

    func playStopSound() {
        guard !FlowSoundSettings.isSuspended,
            CustomSoundManager.shared.isSoundEnabled(for: .stop)
        else { return }
        play(.slot(.stop))
    }

    /// Dismiss sound (user cancel). Plays the pack's stop sound.
    func playEscSound() {
        guard canPlayExtraSounds else { return }
        play(.esc)
    }

    // MARK: - Flow sounds

    func playLockSound() {
        guard canPlayExtraSounds else { return }
        play(.slot(.lock))
    }

    func playPasteSound() {
        guard canPlayExtraSounds else { return }
        play(.slot(.paste))
    }

    func playAchievementSound() {
        guard canPlayExtraSounds else { return }
        play(.slot(.achievement))
    }

    /// Notification sounds play at half volume.
    func playNotificationSound(_ kind: FlowNotificationSound) {
        guard canPlayExtraSounds else { return }
        play(.slot(kind.slot))
    }

    /// Plays `pack`'s start sound, for the settings picker.
    func preview(_ pack: FlowSoundPack) {
        guard canPlayExtraSounds, let url = pack.url(for: .start) else { return }
        playbackEngine.playOnce(url: url, volume: FlowSoundSlot.start.volume)
    }
}
