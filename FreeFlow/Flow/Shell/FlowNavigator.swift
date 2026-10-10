import AppKit
import Combine
import SwiftUI

enum FlowDestination: String, CaseIterable, Identifiable {
    case dictation = "Dictation"
    case insights = "Insights"
    case dictionary = "Dictionary"
    case files = "Files"

    var id: String { rawValue }

    var title: String { rawValue }

    var icon: FlowIconName {
        switch self {
        case .dictation: return .mic
        case .insights: return .chartColumnBig
        case .dictionary: return .bookText
        case .files: return .fileVolume
        }
    }

    /// Cmd+1...4.
    var shortcutKey: KeyEquivalent {
        switch self {
        case .dictation: return "1"
        case .insights: return "2"
        case .dictionary: return "3"
        case .files: return "4"
        }
    }
}

@MainActor
final class FlowNavigator: ObservableObject {
    static let shared = FlowNavigator()

    static let sidebarCollapsedKey = "FlowSidebarCollapsed"

    @Published var destination: FlowDestination = .dictation {
        didSet {
            guard oldValue != destination else { return }
            if !isTraversingHistory {
                backStack.append(oldValue)
                if backStack.count > 50 { backStack.removeFirst(backStack.count - 50) }
                forwardStack.removeAll()
            }
            updateHistoryFlags()
        }
    }

    /// Non-nil shows the settings modal.
    @Published var settingsPane: FlowSettingsPane?
    /// Dialog to open automatically inside settings.
    @Published var settingsDialog: FlowSettingsDialog?
    @Published var isSidebarCollapsed: Bool {
        didSet { UserDefaults.standard.set(isSidebarCollapsed, forKey: Self.sidebarCollapsedKey) }
    }
    /// Insights tab: 0 usage, 1 voice.
    @Published var insightsTab: Int = 0

    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private var backStack: [FlowDestination] = []
    private var forwardStack: [FlowDestination] = []
    private var isTraversingHistory = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        isSidebarCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarCollapsedKey)

        NotificationCenter.default.publisher(for: .navigateToDestination)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let raw = notification.userInfo?["destination"] as? String else { return }
                self?.route(legacyDestination: raw)
            }
            .store(in: &cancellables)

        // "Open with" / dropped-on-Dock audio files: the old Transcribe Audio page is gone,
        // so they go to the Files queue.
        NotificationCenter.default.publisher(for: .openFileForTranscription)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let url = notification.userInfo?["url"] as? URL else { return }
                self?.destination = .files
                _ = FlowFilesStore.shared.enqueue(urls: [url])
            }
            .store(in: &cancellables)
    }

    // MARK: - Destinations

    /// Selects a destination and brings the main window forward.
    func open(_ destination: FlowDestination) {
        self.destination = destination
        bringMainWindowForward()
    }

    /// Selects a destination without touching window order (sidebar clicks).
    func select(_ destination: FlowDestination) {
        self.destination = destination
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        isTraversingHistory = true
        forwardStack.append(destination)
        destination = previous
        isTraversingHistory = false
        updateHistoryFlags()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        isTraversingHistory = true
        backStack.append(destination)
        destination = next
        isTraversingHistory = false
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    // MARK: - Settings

    func presentSettings(_ pane: FlowSettingsPane = .general, dialog: FlowSettingsDialog? = nil) {
        settingsDialog = dialog
        settingsPane = pane
        bringMainWindowForward()
    }

    func dismissSettings() {
        settingsPane = nil
        settingsDialog = nil
    }

    // MARK: - Sidebar

    func toggleSidebar() {
        isSidebarCollapsed.toggle()
    }

    // MARK: - Legacy routing

    /// Maps the old ViewType raw strings (and Flow destination names) onto Flow navigation.
    func route(legacyDestination raw: String) {
        switch raw {
        case "Dashboard", "History", "Dictation":
            destination = .dictation
        case "Transcribe Audio", "Files":
            destination = .files
        case "Dictionary":
            destination = .dictionary
        case "Insights":
            destination = .insights
        case "Modes":
            presentSettings(.aiCleanup)
        case "Settings", "AI Models", "Audio":
            presentSettings()
        default:
            break
        }
    }

    // MARK: - Window

    func bringMainWindowForward() {
        if let window = WindowManager.shared.currentMainWindow() {
            if !(window.isKeyWindow && NSApp.isActive && window.isVisible) {
                WindowManager.shared.showMainWindow()
            }
        } else {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        }
    }
}
