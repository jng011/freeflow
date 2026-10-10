import AppKit
import SwiftUI

/// Left navigation: logo, Dictation / Insights / Dictionary / Files, and Settings at the bottom.
struct FlowSidebar: View {
    @ObservedObject private var navigator = FlowNavigator.shared
    @State private var isFullScreen = false

    static let expandedWidth: CGFloat = 216
    static let fullScreenWidth: CGFloat = 256
    static let collapsedWidth: CGFloat = 60

    private var collapsed: Bool { navigator.isSidebarCollapsed }

    private var width: CGFloat {
        if collapsed { return Self.collapsedWidth }
        return isFullScreen ? Self.fullScreenWidth : Self.expandedWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logoRow
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(FlowDestination.allCases) { destination in
                    FlowSidebarItem(
                        icon: destination.icon,
                        title: destination.title,
                        isSelected: navigator.destination == destination,
                        collapsed: collapsed
                    ) {
                        navigator.select(destination)
                    }
                }
            }

            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(FlowColor.border)
                    .frame(height: 1)
                    .padding(.top, 8)
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    FlowSidebarItem(
                        icon: .settings,
                        title: "Settings",
                        isSelected: navigator.settingsPane != nil,
                        collapsed: collapsed,
                        badgeCount: FlowSettingsAttention.count
                    ) {
                        navigator.presentSettings(.general)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(12)
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(FlowColor.backgroundTertiary)
        .animation(FlowMotion.standard, value: width)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === WindowManager.shared.currentMainWindow() {
                isFullScreen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === WindowManager.shared.currentMainWindow() {
                isFullScreen = false
            }
        }
        .onAppear {
            isFullScreen = WindowManager.shared.currentMainWindow()?.styleMask.contains(.fullScreen) ?? false
        }
    }

    private var logoRow: some View {
        HStack(spacing: 2) {
            FlowInviteTapTarget { FlowLogoMark() }
            FlowWordmark()
                .padding(.leading, 3)
                .opacity(collapsed ? 0 : 1)
            FlowBadge("Pro", variant: .brandLight)
                .padding(.leading, 10)
                .opacity(collapsed ? 0 : 1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Free Flow")
    }
}

/// One sidebar row: padding 8, radius 6, 20 pt icon box, smEmph label.
private struct FlowSidebarItem: View {
    let icon: FlowIconName
    let title: String
    let isSelected: Bool
    let collapsed: Bool
    var badgeCount: Int = 0
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                FlowIcon(icon, size: 20, color: FlowColor.foreground)
                    .frame(width: 20, height: 20)
                    .overlay(alignment: .topTrailing) {
                        if collapsed && badgeCount > 0 {
                            FlowCountBadge(count: badgeCount)
                                .offset(x: 6, y: -6)
                        }
                    }
                Text(title)
                    .flowText(.smEmph)
                    .foregroundStyle(FlowColor.foreground)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(collapsed ? 0 : 1)
                Spacer(minLength: 0)
                if !collapsed && badgeCount > 0 {
                    FlowCountBadge(count: badgeCount)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(isSelected || hovering ? FlowColor.neutral200 : FlowColor.backgroundTertiary))
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(FlowMotion.standard) { hovering = inside }
        }
        .flowHint(title, edge: .trailing, isEnabled: collapsed)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Red 16x16 count badge (#EF4444, 9 pt weight 650, white).
struct FlowCountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(FlowFont.sans(9, weight: 650))
            .foregroundStyle(Color.white)
            .padding(.horizontal, count > 9 ? 3 : 0)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(FlowColor.badgeRed))
    }
}
