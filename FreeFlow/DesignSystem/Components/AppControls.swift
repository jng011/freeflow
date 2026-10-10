import Foundation
import SwiftUI

struct AppIconButton: View {
    let systemName: String
    let help: LocalizedStringResource
    var size: CGFloat = 40
    var iconSize: CGFloat = 18
    var cornerRadius: CGFloat = AppTheme.Radius.pill
    var isDisabled = false
    let action: () -> Void

    init(
        systemName: String,
        help: LocalizedStringResource,
        size: CGFloat = 40,
        iconSize: CGFloat = 18,
        cornerRadius: CGFloat = AppTheme.Radius.pill,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.size = size
        self.iconSize = iconSize
        self.cornerRadius = cornerRadius
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: size - 12, height: size - 12)
        }
        .appGlassButtonStyle()
        .buttonBorderShape(.circle)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

enum AppActionButtonKind: Equatable {
    case secondary
    case primary
    case destructive
}

struct AppActionButton: View {
    let title: LocalizedStringKey
    var kind: AppActionButtonKind = .secondary
    var minWidth: CGFloat?
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        kind: AppActionButtonKind = .secondary,
        minWidth: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.minWidth = minWidth
        self.action = action
    }

    var body: some View {
        let button = Button(role: kind == .destructive ? .destructive : nil, action: action) {
            Text(title)
                .frame(minWidth: minWidth)
        }
        .controlSize(.large)

        switch kind {
        case .secondary:
            button.appGlassButtonStyle()
        case .primary:
            button.appGlassProminentButtonStyle()
        case .destructive:
            button.appGlassProminentButtonStyle().tint(.red)
        }
    }
}

extension View {
    /// System Liquid Glass button (macOS 26); bordered fallback on macOS 15.
    @ViewBuilder
    func appGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// System prominent Liquid Glass button (macOS 26); bordered-prominent fallback.
    @ViewBuilder
    func appGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

struct AppPanelHeader: View {
    let title: LocalizedStringKey
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Spacer()

            AppIconButton(
                systemName: "xmark",
                help: "Close",
                size: 28,
                iconSize: 14,
                cornerRadius: AppTheme.Radius.control,
                action: onClose
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .zIndex(1)
    }
}

struct AppScreenHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var infoMessage: LocalizedStringKey?
    var infoURL: String?
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.primary)

                if let infoMessage {
                    if let infoURL {
                        InfoTip(infoMessage, learnMoreURL: infoURL)
                    } else {
                        InfoTip(infoMessage)
                    }
                }
            }

            Spacer()

            trailing()
        }
        .frame(height: 40)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}

extension AppScreenHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey, infoMessage: LocalizedStringKey? = nil, infoURL: String? = nil) {
        self.title = title
        self.infoMessage = infoMessage
        self.infoURL = infoURL
        self.trailing = { EmptyView() }
    }
}
