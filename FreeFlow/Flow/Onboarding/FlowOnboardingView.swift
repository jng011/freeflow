import AVFoundation
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shared onboarding flags other parts of the app may read.
@MainActor
enum FlowOnboardingState {
    /// True while the shortcut test page listens for the dictation key. The recording
    /// shortcut handler can skip starting a dictation while this is set.
    static var isTestingShortcut = false
}

enum FlowOnboardingPage: String, CaseIterable, Identifiable {
    case welcome, permissions, micTest, shortcutTest, language, tryIt, features, agents

    var id: String { rawValue }

    var section: FlowOnboardingSection {
        switch self {
        case .welcome: return .getStarted
        case .permissions: return .permissions
        case .micTest, .shortcutTest, .language: return .setUp
        case .tryIt, .features, .agents: return .learn
        }
    }

    /// Pages in order. The language page only appears when multi-language dictation is on.
    static var flow: [FlowOnboardingPage] {
        allCases.filter { $0 != .language || FlowSettingsFeatures.multiLanguage }
    }

    /// Pages from here on need the microphone and accessibility permissions.
    var needsPermissions: Bool {
        switch self {
        case .welcome, .permissions: return false
        case .micTest, .shortcutTest, .language, .tryIt, .features, .agents: return true
        }
    }
}

/// State and navigation for the onboarding window.
@MainActor
final class FlowOnboardingModel: ObservableObject {
    @Published private(set) var page: FlowOnboardingPage
    @Published var name: String
    @Published var languages: [String] {
        didSet { languageError = nil }
    }
    @Published var autoDetect: Bool {
        didSet { languageError = nil }
    }
    @Published var languageError: String?
    @Published var practiceText = ""
    @Published var practiceSucceeded = false

    let coordinator = FlowPermissions()
    let presenter = FlowSettingsPresenter()

    private var grantedPermissions: Set<FlowPermission> = []
    private var timeoutTasks: [FlowPermission: Task<Void, Never>] = [:]

    init() {
        let defaults = UserDefaults.standard
        let pages = FlowOnboardingPage.flow
        let storedIndex = defaults.integer(forKey: FlowSettingsPrivateKeys.onboardingPage)
        let restored = pages[min(max(storedIndex, 0), pages.count - 1)]

        let storedName = (defaults.string(forKey: FlowLegacyKeys.displayName) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let firstName = FlowUser.firstName
        page = restored
        name = storedName.isEmpty ? (firstName == "there" ? "" : firstName) : storedName
        languages = FlowLanguageCatalog.storedSelection
        autoDetect = FlowLanguageCatalog.isAutoDetect

        // A relaunch never skips past missing permissions.
        coordinator.refresh()
        if restored.needsPermissions && !coordinator.allGranted {
            page = .permissions
        }
        grantedPermissions = Set(FlowPermission.required.filter { isGranted($0) })
    }

    var pages: [FlowOnboardingPage] { FlowOnboardingPage.flow }
    var index: Int { pages.firstIndex(of: page) ?? 0 }
    var progress: Double { Double(index + 1) / Double(max(pages.count, 1)) }

    // MARK: Navigation

    func go(to newPage: FlowOnboardingPage) {
        guard newPage != page else { return }
        withAnimation(FlowOnboardingMotion.page) { page = newPage }
        UserDefaults.standard.set(pages.firstIndex(of: newPage) ?? 0, forKey: FlowSettingsPrivateKeys.onboardingPage)
    }

    func goNext() {
        let next = index + 1
        guard next < pages.count else {
            finish()
            return
        }
        go(to: pages[next])
    }

    func goBack() {
        guard index > 0 else { return }
        go(to: pages[index - 1])
    }

    /// The page's primary action (also run by Return).
    func performPrimary() {
        switch page {
        case .welcome:
            saveName()
            goNext()
        case .permissions:
            refreshPermissions(coordinator)
            guard coordinator.allGranted else { return }
            goNext()
        case .micTest, .shortcutTest, .features:
            goNext()
        case .agents:
            finish()
        case .language:
            guard autoDetect || !languages.isEmpty else {
                languageError = "Please select at least one language or turn on auto-detect"
                return
            }
            FlowLanguageCatalog.save(selection: languages, autoDetect: autoDetect)
            goNext()
        case .tryIt:
            guard practiceSucceeded else { return }
            goNext()
        }
    }

    private func saveName() {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        guard !trimmed.isEmpty else { return }
        name = trimmed
        UserDefaults.standard.set(trimmed, forKey: FlowLegacyKeys.displayName)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    // MARK: Permissions

    private func isGranted(_ kind: FlowPermission) -> Bool {
        coordinator.status(for: kind).isGranted
    }

    func requestPermission(_ kind: FlowPermission, coordinator: FlowPermissions) {
        coordinator.request( kind)
        timeoutTasks[kind]?.cancel()
        timeoutTasks[kind] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.refreshPermissions(coordinator)
            // Accessibility is granted by hand in System Settings, so only complain once
            // the person is back in Flow without it.
            let isBack = kind == .microphone || NSApp.isActive
            if !self.isGranted(kind), self.page == .permissions, isBack {
                FlowToastCenter.shared.show(
                    "Permission request timed out. Please try again or restart the app.",
                    style: .error
                )
            }
        }
    }

    /// Re-reads permission state. When one becomes granted, brings Flow back to the front.
    func refreshPermissions(_ coordinator: FlowPermissions) {
        coordinator.refresh()
        let granted = Set(FlowPermission.required.filter(isGranted))
        let newlyGranted = granted.subtracting(grantedPermissions)
        grantedPermissions = granted
        guard !newlyGranted.isEmpty else { return }
        for kind in newlyGranted {
            timeoutTasks[kind]?.cancel()
            timeoutTasks[kind] = nil
        }
        if page == .permissions {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: Finish

    /// Marks onboarding done, shows the Flow Bar and opens the main window.
    func finish() {
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks = [:]
        coordinator.stopPolling()
        saveName()

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: FlowSettingsPrivateKeys.onboardingPage)
        defaults.set(0.0, forKey: FlowKeys.barSnoozeUntil)
        defaults.set(true, forKey: FlowKeys.showBarAlways)
        defaults.set(true, forKey: OnboardingSettings.completedV2Key)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)

        FlowBarController.shared.refreshVisibility()
        DispatchQueue.main.async {
            FlowNavigator.shared.open(.dictation)
        }
    }
}

/// Onboarding: Welcome, Permissions, Mic test, Shortcut test, (Language), Try it,
/// Features, AI agents. Finishing the AI agents page completes onboarding.
struct FlowOnboardingView: View {
    @StateObject private var model = FlowOnboardingModel()
    @StateObject private var micMeter = FlowMicTestMeter()
    @StateObject private var shortcutMonitor = FlowShortcutTestMonitor()
    @StateObject private var keyMonitor = FlowSettingsKeyMonitor()

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            FlowOnboardingHeader(current: model.page.section)
                .background(FlowColor.background)
            FlowOnboardingProgressBar(fraction: model.progress)
            pageView
                .id(model.page)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 600)
        .background(FlowColor.background)
        .ignoresSafeArea(.container, edges: .top)
        .flowSettingsOverlays(model.presenter)
        .flowToastHost()
        .onAppear {
            keyMonitor.start { event in handleKey(event) }
        }
        .onDisappear {
            keyMonitor.stop()
            micMeter.stop()
            shortcutMonitor.stop()
        }
    }

    @ViewBuilder
    private var pageView: some View {
        switch model.page {
        case .welcome:
            FlowWelcomePage(model: model)
        case .permissions:
            FlowPermissionsPage(model: model, coordinator: model.coordinator)
        case .micTest:
            FlowMicTestPage(model: model, meter: micMeter)
        case .shortcutTest:
            FlowShortcutTestPage(model: model, monitor: shortcutMonitor, presenter: model.presenter)
        case .language:
            FlowLanguagePage(model: model)
        case .tryIt:
            FlowTryItPage(model: model)
        case .features:
            FlowFeaturesPage(model: model)
        case .agents:
            FlowAgentsPage(model: model)
        }
    }

    /// Esc closes an open dialog; Return runs the page's primary action unless a
    /// text field or button has focus.
    private func handleKey(_ event: NSEvent) -> Bool {
        if FlowShortcutCaptureState.isCapturing { return false }
        let presenter = model.presenter
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty else { return false }

        if event.keyCode == UInt16(kVK_Escape) {
            if presenter.confirmation != nil {
                presenter.confirmation = nil
                return true
            }
            if presenter.dialog != nil {
                presenter.dialog = nil
                return true
            }
            return false
        }

        guard event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) else {
            return false
        }
        if presenter.dialog != nil || presenter.confirmation != nil || presenter.sheet != nil { return false }
        if let responder = event.window?.firstResponder, responder is NSTextView || responder is NSButton {
            return false
        }
        model.performPrimary()
        return true
    }
}
