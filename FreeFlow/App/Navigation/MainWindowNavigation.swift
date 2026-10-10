import OSLog
import SwiftUI

enum ViewType: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case modes = "Modes"
    case models = "AI Models"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case settings = "Settings"

    var id: String { rawValue }
}

/// Legacy navigation entry point. Old callers pass the former ViewType raw strings;
/// they are routed onto the Flow window (FlowNavigator) on the main actor.
final class MainWindowNavigation: ObservableObject {
    static let shared = MainWindowNavigation()

    @Published var selectedView: ViewType = .dashboard

    private init() {}

    func navigate(to destination: String) {
        if let viewType = ViewType(rawValue: destination) {
            selectedView = viewType
        }
        Task { @MainActor in
            FlowNavigator.shared.route(legacyDestination: destination)
        }
    }

    func navigate(to destination: ViewType) {
        navigate(to: destination.rawValue)
    }
}

/// Main window content. The Flow shell replaced the old split view; this wrapper keeps the name.
/// Legacy `.navigateToDestination` posts are handled by FlowNavigator.
