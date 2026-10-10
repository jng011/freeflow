import AppKit
import SwiftUI

enum HistoryLayout {
    static let rowSpacing: CGFloat = 8
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 10
    static let listInset: CGFloat = 8
    static let listTopInset = QuickPanelMetrics.headerHeight + 10
    static let listBottomInset = QuickPanelMetrics.footerHeight + 18
    static let headerInset: CGFloat = 18
    static let detailInset: CGFloat = 14
    static let detailTopInset = QuickPanelMetrics.headerHeight + 12
    static let detailBottomSpacing: CGFloat = 24
    static let actionBarHeight: CGFloat = 44
    static let buttonHeight: CGFloat = 32
    static let playerHeight: CGFloat = 48
    static let playerSpacing: CGFloat = 4
}

struct HistorySearchHeader<Accessory: View>: View {
    @Binding var searchText: String
    let searchFocus: FocusState<Bool>.Binding
    var isSearching = false
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            TextField("Search transcriptions...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused(searchFocus)
                .frame(maxWidth: 340)

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            accessory()
        }
        .padding(.horizontal, HistoryLayout.headerInset)
        .frame(height: QuickPanelMetrics.headerHeight)
    }
}

struct HistoryList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(spacing: HistoryLayout.rowSpacing) {
                content()
            }
            .padding(.horizontal, HistoryLayout.listInset)
            .padding(.top, HistoryLayout.listTopInset)
            .padding(.bottom, HistoryLayout.listBottomInset)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryEmptyState: View {
    let hasSearchQuery: Bool
    let emptyMessage: LocalizedStringKey

    var body: some View {
        Group {
            if hasSearchQuery {
                ContentUnavailableView(
                    "No Matching Transcriptions",
                    systemImage: "magnifyingglass",
                    description: Text("Try another search term.")
                )
            } else {
                ContentUnavailableView(
                    "No Transcriptions Yet",
                    systemImage: "waveform",
                    description: Text(emptyMessage)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HistoryCardBackground: View {
    var surface = AppTheme.Surface.materialCard

    var body: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.card, style: .continuous)
            .fill(surface)
    }
}

struct HistoryTranscriptionRow: View {
    let transcription: Transcription
    let isSelected: Bool
    let onSelect: () -> Void
    var onPaste: (() -> Void)? = nil
    var onToggleCheck: (() -> Void)? = nil
    var showsCopyButton = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            if let onToggleCheck {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isSelected },
                        set: { _ in onToggleCheck() }
                    )
                )
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Select transcription")
            }

            rowAction

            if showsCopyButton {
                CopyIconButton(
                    textToCopy: transcription.preferredHistoryText,
                    accessibilityLabel: "Copy transcription"
                )
            }
        }
        .frame(height: 24)
        .padding(.horizontal, HistoryLayout.rowHorizontalPadding)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AppTheme.Selection.fill : (isHovered ? AppTheme.Surface.subtle : Color.clear))
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var rowAction: some View {
        if let onPaste {
            selectionButton
                .simultaneousGesture(TapGesture(count: 2).onEnded { _ in onPaste() })
        } else {
            selectionButton
        }
    }

    private var selectionButton: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                if let icon = transcription.recordedHistoryModeIcon {
                    ModeIconView(
                        icon: icon,
                        size: icon.kind == .emoji ? 16 : 14,
                        color: .secondary
                    )
                    .frame(width: 22)
                    .accessibilityHidden(true)
                }

                Text(transcription.preferredHistoryText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(transcription.timestamp, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(transcription.hasEnhancedHistoryText ? "Enhanced transcription" : "Original transcription")
        .accessibilityValue(transcription.preferredHistoryText)
        .accessibilityHint(
            onPaste == nil
                ? "Opens transcription details."
                : "Selects this transcription. Double-click to paste."
        )
    }
}

struct HistoryIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var isSelected = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemName)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(width: 18, height: 18)
        }
        .buttonBorderShape(.circle)
        .help(help)
        .accessibilityLabel(help)

        if isSelected {
            button.appGlassProminentButtonStyle()
        } else {
            button.appGlassButtonStyle()
        }
    }
}

struct HistoryCommandButton: View {
    let title: LocalizedStringKey
    let systemImage: String?
    let shortcut: String?
    let isDestructive: Bool
    let minimumWidth: CGFloat?
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        shortcut: String? = nil,
        isDestructive: Bool = false,
        minimumWidth: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.isDestructive = isDestructive
        self.minimumWidth = minimumWidth
        self.action = action
    }

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .frame(minWidth: minimumWidth)
            .fixedSize(horizontal: true, vertical: false)
        }
        .appGlassButtonStyle()
    }
}

struct HistoryWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableAreaView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableAreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
