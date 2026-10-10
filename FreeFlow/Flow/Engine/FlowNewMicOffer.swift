import CoreAudio
import Foundation

/// "New microphone" offer: when an input device appears while idle, the Flow Bar
/// asks whether to use it. Fed by AudioDeviceManager's existing device-list listener.
enum FlowNewMicOffer {
    /// Input device UIDs seen since launch. nil until the launch snapshot is taken.
    private static var knownUIDs: Set<String>?

    static func tip(for uid: String) -> FlowTipLedger.Tip {
        FlowTipLedger.Tip(id: "newMic.\(uid)", maxShows: 3, minInterval: FlowTipLedger.Tip.hour)
    }

    /// Records the devices present at launch so they are never offered. Main queue only.
    static func seed(with manager: AudioDeviceManager) {
        knownUIDs = Set(manager.availableDevices.map(\.uid))
    }

    /// Called on the main queue after the device list reloads.
    static func deviceListDidChange(_ manager: AudioDeviceManager) {
        let current = manager.availableDevices
        guard let known = knownUIDs else {
            knownUIDs = Set(current.map(\.uid))
            return
        }
        let added = current.filter { !known.contains($0.uid) }
        knownUIDs = known.union(current.map(\.uid))

        guard !manager.isRecordingActive else { return }
        guard let device = added.first(where: { isOfferable($0.id, manager: manager) }) else { return }

        let tip = tip(for: device.uid)
        guard FlowTipLedger.isEligible(tip) else { return }

        MainActor.assumeIsolated {
            guard !FlowBarController.shared.state.isActive else { return }
            FlowTipLedger.markShown(tip)
            let name = device.name
            let id = device.id
            FlowBarController.shared.showToast(FlowBarToast(
                style: .standard,
                title: "\(name) connected",
                body: "Use it for dictation?",
                actionTitle: "Switch",
                action: {
                    let manager = AudioDeviceManager.shared
                    guard manager.availableDevices.contains(where: { $0.id == id }) else { return }
                    // Same path as the Flow microphone dialog, so the choice persists.
                    manager.selectDeviceAndSwitchToCustomMode(id: id)
                    FlowBarController.shared.showToast(
                        FlowBarToast(style: .mini, title: "Using \(name)", icon: .mic, duration: 3))
                },
                secondaryActionTitle: "Dismiss",
                duration: 10
            ))
        }
    }

    private static func isOfferable(_ deviceID: AudioDeviceID, manager: AudioDeviceManager) -> Bool {
        // Already the mic in use.
        let inUse = manager.inputMode == .systemDefault ? manager.getSystemDefaultDevice() : manager.selectedDeviceID
        if deviceID == inUse { return false }

        // Built-in, aggregate and virtual inputs are never "plugged in".
        let transport = manager.getUInt32DeviceProperty(deviceID: deviceID, selector: kAudioDevicePropertyTransportType)
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeVirtual:
            return false
        default:
            return manager.isDeviceUsableForRecording(deviceID)
        }
    }
}
