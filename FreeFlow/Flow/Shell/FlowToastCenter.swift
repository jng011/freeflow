import SwiftUI

enum FlowToastStyle { case info, success, error }

struct FlowToastItem: Identifiable {
    let id = UUID()
    let message: String
    let title: String?
    let style: FlowToastStyle
    let duration: TimeInterval
    let actionTitle: String?
    let action: (() -> Void)?
}

/// In-window toasts, bottom-right of the main window. Use only while the window is visible;
/// outside the window use the Flow Bar toasts.
@MainActor
final class FlowToastCenter: ObservableObject {
    static let shared = FlowToastCenter()

    @Published private(set) var toasts: [FlowToastItem] = []

    private var timers: [UUID: Task<Void, Never>] = [:]
    private let maxVisible = 3

    private init() {}

    func show(
        _ message: String,
        title: String? = nil,
        style: FlowToastStyle = .info,
        duration: TimeInterval = 5,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        let item = FlowToastItem(
            message: message, title: title, style: style, duration: duration, actionTitle: actionTitle,
            action: action)

        withAnimation(FlowMotion.respecting(FlowMotion.toastIn)) {
            toasts.append(item)
            while toasts.count > maxVisible {
                let removed = toasts.removeFirst()
                timers[removed.id]?.cancel()
                timers[removed.id] = nil
            }
        }

        guard duration > 0 else { return }
        timers[item.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(item.id)
        }
    }

    func dismiss(_ id: UUID) {
        timers[id]?.cancel()
        timers[id] = nil
        withAnimation(FlowMotion.respecting(FlowMotion.toastOut)) {
            toasts.removeAll { $0.id == id }
        }
    }

    func dismissAll() {
        for task in timers.values { task.cancel() }
        timers.removeAll()
        withAnimation(FlowMotion.respecting(FlowMotion.toastOut)) {
            toasts.removeAll()
        }
    }
}

// MARK: - Views

struct FlowToastView: View {
    let item: FlowToastItem
    let onDismiss: () -> Void

    private var iconName: FlowIconName? {
        switch item.style {
        case .info: return nil
        case .success: return .circleCheck
        case .error: return .circleAlert
        }
    }

    private var iconColor: Color {
        switch item.style {
        case .info: return FlowColor.vast300
        case .success: return FlowColor.hex(0x34D399)
        case .error: return FlowColor.hex(0xFF5757)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(alignment: .center, spacing: 8) {
            if let iconName {
                FlowIcon(iconName, size: 16, color: iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = item.title {
                    Text(title)
                        .font(FlowFont.sans(15, weight: 600))
                        .foregroundStyle(Color.white)
                    Text(item.message)
                        .flowText(.xs)
                        .foregroundStyle(FlowColor.vast300)
                } else {
                    Text(item.message)
                        .flowText(.sm)
                        .foregroundStyle(Color.white)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            if let actionTitle = item.actionTitle {
                Button {
                    item.action?()
                    onDismiss()
                } label: {
                    Text(actionTitle)
                        .flowText(.smEmph)
                        .foregroundStyle(FlowColor.sand600)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(width: 300, alignment: .leading)
        .background(shape.fill(FlowColor.vast950))
        .overlay(shape.strokeBorder(FlowColor.vast900, lineWidth: 1))
        .flowShadow(.lg)
        .environment(\.colorScheme, .dark)
    }
}

/// Bottom-right toast stack, 16 pt from the right and bottom edges.
private struct FlowToastHostModifier: ViewModifier {
    @ObservedObject private var center = FlowToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(center.toasts) { item in
                    FlowToastView(item: item) {
                        center.dismiss(item.id)
                    }
                    .transition(
                        .asymmetric(
                            insertion: .offset(y: 16).combined(with: .scale(scale: 0.9)).combined(with: .opacity),
                            removal: .offset(y: -32).combined(with: .opacity)
                        )
                    )
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 16)
        }
    }
}

extension View {
    /// Installed once by the root view.
    func flowToastHost() -> some View {
        modifier(FlowToastHostModifier())
    }
}
