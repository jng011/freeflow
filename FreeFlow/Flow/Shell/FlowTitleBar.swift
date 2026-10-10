import AppKit
import SwiftUI

/// 52 pt window title bar: traffic-light spacer, sidebar toggle, theme menu. The empty area drags the window.
struct FlowTitleBar: View {
    @ObservedObject private var navigator = FlowNavigator.shared
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appearance = AppAppearancePreference.system
    @Environment(\.colorScheme) private var colorScheme

    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            // Traffic lights live here (positioned by WindowManager at x 16, y 19).
            Color.clear
                .frame(width: 52, height: 12)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 8))
                .allowsHitTesting(false)

            FlowIconButton(icon: .panelLeft, size: .lg) {
                withAnimation(FlowMotion.standard) {
                    navigator.toggleSidebar()
                }
            }
            // Tip to the right: centered below, it covered the window buttons.
            .flowHint(navigator.isSidebarCollapsed ? "Open sidebar" : "Close sidebar", edge: .trailing)
            .accessibilityLabel(navigator.isSidebarCollapsed ? "Open sidebar" : "Close sidebar")
            .focusEffectDisabled()
            .padding(.leading, 8)

            Spacer(minLength: 0)

            themeMenu
                .padding(.trailing, 16)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(FlowWindowDragArea())
    }

    private var themeMenu: some View {
        FlowMenuButton(alignment: .trailing, minWidth: 160) {
            [AppAppearancePreference.light, .dark, .system].map { preference in
                FlowMenuItem.button(
                    FlowAppearance.menuTitle(for: preference),
                    icon: FlowAppearance.icon(for: preference),
                    checked: appearance == preference
                ) {
                    FlowAppearance.set(preference)
                }
            }
        } label: { isOpen in
            FlowTitleBarNavItem(icon: colorScheme == .dark ? .moon : .sun, isActive: isOpen)
        }
        .flowHint("Theme")
        .accessibilityLabel("Theme")
    }
}

/// 36x36 nav item: padding 8, radius 6, icon 20, hover neutral200.
private struct FlowTitleBarNavItem: View {
    let icon: FlowIconName
    let isActive: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        FlowIcon(icon, size: 20, color: FlowColor.foreground)
            .padding(8)
            .frame(width: 36, height: 36)
            .background(shape.fill(hovering || isActive ? FlowColor.neutral200 : Color.clear))
            .contentShape(shape)
            .onHover { inside in
                withAnimation(FlowMotion.standard) { hovering = inside }
            }
    }
}

/// Drags the window from empty title-bar space; double-click follows the system title-bar setting.
struct FlowWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize":
                    window.performMiniaturize(nil)
                case "None":
                    break
                default:
                    window.performZoom(nil)
                }
                return
            }
            window.performDrag(with: event)
        }
    }
}
