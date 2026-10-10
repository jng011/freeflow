import AppKit
import CoreAudio
import Foundation
import os

extension Notification.Name {
    /// The microphone in use went away mid-dictation and no other one could take over.
    static let flowMicrophoneDisconnected = Notification.Name("flowMicrophoneDisconnected")
}

extension Recorder {
    func setupRecordingDeviceChangeObserver() {
        recordingDeviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .recordingDeviceChangeRequired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task {
                await self?.handleRecordingDeviceChange(notification)
            }
        }
    }

    func startHardwareRecording(
        _ recorder: CoreAudioRecorder,
        to url: URL,
        deviceID: AudioDeviceID
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioSetupQueue.async {
                do {
                    try recorder.startRecording(toOutputFile: url, deviceID: deviceID)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func showRecordingDeviceNotification(
        for deviceID: AudioDeviceID,
        resolution: RecordingDeviceResolution
    ) {
        guard let deviceName = deviceManager.availableDevices.first(where: { $0.id == deviceID })?.name else {
            return
        }

        // AirPods tip replaces the "Using: X" notice so the two never collide.
        // AirPods only: the tip names them, and other Bluetooth headsets vary.
        if deviceName.localizedCaseInsensitiveContains("AirPods"),
            FlowTipLedger.isEligible(.airPods)
        {
            scheduleAirPodsTip()
            return
        }

        if resolution.fellBackFromClosedInternalMicrophone {
            NotificationManager.shared.showNotification(
                title: String(format: String(localized: "Using: %@"), deviceName),
                type: .info
            )
            return
        }

        let lastDeviceID = UserDefaults.standard.string(forKey: "lastUsedMicrophoneDeviceID")
        guard String(deviceID) != lastDeviceID else { return }
        NotificationManager.shared.showNotification(
            title: String(format: String(localized: "Using: %@"), deviceName),
            type: .info
        )
    }

    /// Shown just after the mic opens so it never delays the start. Rate limited by
    /// FlowTipLedger (once an hour, off with Suggestions or "Don't show again").
    private func scheduleAirPodsTip() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            let phase = FlowDictationState.shared.phase
            guard phase == .listening || phase == .initializing,
                FlowTipLedger.isEligible(.airPods)
            else { return }
            FlowTipLedger.markShown(.airPods)
            var toast = FlowBarToast(
                style: .standard,
                badge: "Tip",
                title: "AirPods aren't great for dictation",
                body: "They can add delay and lower accuracy. Your Mac's mic usually works better."
            )
            toast.actionTitle = "Microphone"
            toast.action = {
                FlowNavigator.shared.presentSettings(.general, dialog: .microphone)
                NSApp.activate()
            }
            toast.secondaryActionTitle = "Don't show again"
            toast.secondaryAction = { FlowTipLedger.markDismissed(.airPods) }
            toast.duration = 6
            FlowBarController.shared.showToast(toast)
        }
    }

    private func handleRecordingDeviceChange(_ notification: Notification) async {
        guard let request = notification.object as? RecordingDeviceChangeRequest else { return }
        guard let fallbackDeviceID = request.fallbackDeviceID else {
            deviceManager.recordingDeviceChangeFinished()
            if FlowDictationState.shared.phase == .listening {
                // The engine stops, keeps what was captured, and says so on the Flow Bar.
                NotificationCenter.default.post(name: .flowMicrophoneDisconnected, object: nil)
            } else {
                showNoFallbackNotification(reason: request.reason)
            }
            return
        }
        guard let recorder else {
            deviceManager.recordingDeviceChangeFinished()
            return
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioSetupQueue.async {
                    do {
                        try recorder.switchDevice(to: fallbackDeviceID)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            deviceManager.recordingDeviceChangeFinished(activeDeviceID: fallbackDeviceID)
            UserDefaults.standard.set(
                String(fallbackDeviceID),
                forKey: "lastUsedMicrophoneDeviceID"
            )
            if let deviceName = deviceManager.availableDevices.first(where: { $0.id == fallbackDeviceID })?.name {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Switched to: %@"), deviceName),
                    type: .info
                )
            }
        } catch {
            deviceManager.recordingDeviceChangeFinished()
            logger.error("Failed to switch recording devices: \(error, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: String(localized: "Free Flow could not switch to another microphone."),
                type: .error,
                duration: 7.0
            )
        }
    }

    private func showNoFallbackNotification(reason: RecordingDeviceChangeReason) {
        let presentation = AudioInputFailurePresentation.noUsableMicrophone(
            internalMicrophoneBlockedByClosedLid: reason == .closedLid
        )
        NotificationManager.shared.showNotification(
            title: presentation.title,
            type: .error,
            duration: 7.0,
            actionButton: (presentation.actionLabel, presentation.action)
        )
    }

}
