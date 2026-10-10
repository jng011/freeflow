import AVFoundation
import AppKit
import ApplicationServices

/// The two permissions Free Flow needs before it can dictate.
enum FlowPermission: String, CaseIterable, Identifiable {
    case microphone
    case accessibility

    var id: String { rawValue }

    static let required: [FlowPermission] = [.microphone, .accessibility]

    /// The matching page in System Settings > Privacy & Security.
    var settingsURL: URL? {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

enum FlowPermissionStatus: Equatable {
    case granted, needsAccess, denied, restricted

    var isGranted: Bool { self == .granted }
    /// Already refused once: only System Settings can change it now.
    var requiresSettings: Bool { self == .denied || self == .restricted }
}

/// Permission state for onboarding: reads it, asks for it, and polls while the
/// person is off in System Settings.
@MainActor
final class FlowPermissions: ObservableObject {
    @Published private(set) var statuses: [FlowPermission: FlowPermissionStatus] = [:]
    @Published private(set) var activePermission: FlowPermission = .microphone

    private var pollTask: Task<Void, Never>?

    init() { refresh() }

    var allGranted: Bool { FlowPermission.required.allSatisfy { status(for: $0).isGranted } }

    func status(for permission: FlowPermission) -> FlowPermissionStatus {
        statuses[permission] ?? Self.read(permission)
    }

    func select(_ permission: FlowPermission) { activePermission = permission }

    /// A permission waits its turn until the ones before it are granted.
    func isLocked(_ permission: FlowPermission) -> Bool {
        FlowPermission.allCases.prefix { $0 != permission }.contains { !status(for: $0).isGranted }
    }

    func refresh() {
        statuses = Dictionary(uniqueKeysWithValues: FlowPermission.allCases.map { ($0, Self.read($0)) })
        if status(for: activePermission).isGranted,
            let next = FlowPermission.required.first(where: { !status(for: $0).isGranted })
        {
            activePermission = next
        }
    }

    func request(_ permission: FlowPermission) {
        guard !isLocked(permission) else { return }
        activePermission = permission
        guard !status(for: permission).isGranted else {
            refresh()
            return
        }
        switch permission {
        case .microphone where status(for: .microphone).requiresSettings:
            openSettings(for: .microphone)
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        case .accessibility:
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(prompt)
            openSettings(for: .accessibility)
        }
        pollUntilGranted()
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func openSettings(for permission: FlowPermission) {
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }

    /// Checks once a second for up to a minute; System Settings sends no callback.
    private func pollUntilGranted() {
        stopPolling()
        pollTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                guard let self, !Task.isCancelled else { return }
                self.refresh()
                if self.allGranted { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func read(_ permission: FlowPermission) -> FlowPermissionStatus {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .denied: .denied
            case .restricted: .restricted
            default: .needsAccess
            }
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .needsAccess
        }
    }
}
