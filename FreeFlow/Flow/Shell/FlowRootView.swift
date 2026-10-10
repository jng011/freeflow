import AppKit
import SwiftUI

/// The main window: 52 pt title bar over the sidebar and the page card for the current destination.
/// The settings modal, in-window dialogs and toasts are layered on top.
struct FlowRootView: View {
    @ObservedObject private var navigator = FlowNavigator.shared

    static let minimumWidth: CGFloat = 1140
    static let minimumHeight: CGFloat = 750

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                FlowTitleBar()
                HStack(spacing: 0) {
                    FlowSidebar()
                        // Collapsed-sidebar hints overflow onto the page card.
                        .zIndex(1)
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlowColor.backgroundTertiary)

            if navigator.settingsPane != nil {
                settingsOverlay
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(FlowMotion.respecting(FlowMotion.dialogIn), value: navigator.settingsPane != nil)
        .flowDialogHost()
        .flowToastHost()
        .ignoresSafeArea(.container, edges: .top)
        .background(FlowColor.backgroundTertiary)
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
    }

    @ViewBuilder
    private var page: some View {
        switch navigator.destination {
        case .dictation:
            FlowHomeView()
        case .insights:
            InsightsView()
        case .dictionary:
            FlowDictionaryView()
        case .files:
            FlowFilesView()
        }
    }

    private var settingsOverlay: some View {
        ZStack {
            FlowColor.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { navigator.dismissSettings() }
            FlowSettingsModal(
                pane: Binding(
                    get: { navigator.settingsPane ?? .general },
                    set: { navigator.settingsPane = $0 }
                ),
                dialog: Binding(
                    get: { navigator.settingsDialog },
                    set: { navigator.settingsDialog = $0 }
                ),
                onClose: { navigator.dismissSettings() }
            )
        }
    }
}
