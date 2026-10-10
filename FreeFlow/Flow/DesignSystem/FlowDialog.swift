import AppKit
import SwiftUI

// MARK: - Dialog surface

/// Dialog container: title, optional subtitle, custom content and right-aligned actions.
struct FlowDialog<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String?
    let content: Content
    let actions: Actions

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FlowRadius.md, style: .continuous)
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(FlowFont.sans(18, weight: 600))
                    .lineSpacing(28 - 18 * 1.2)
                    .foregroundStyle(FlowColor.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .flowText(.sm)
                        .foregroundStyle(FlowColor.neutral500)
                        .lineLimit(4)
                        .frame(maxWidth: 416, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(24)
        .frame(minWidth: 200, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(shape.fill(FlowColor.background))
        .overlay(shape.strokeBorder(FlowColor.border, lineWidth: 1))
        .flowShadow(.xl)
    }
}

extension FlowDialog where Content == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, subtitle: subtitle, content: { EmptyView() }, actions: actions)
    }
}

// MARK: - Presentation

/// One dialog request, carried up to the window-level host through a preference.
/// Not Equatable on purpose, so the host re-renders whenever the presenter does.
struct FlowDialogRequest {
    let id: UUID
    let view: AnyView
    let dismiss: () -> Void
    let primaryAction: (() -> Void)?
}

struct FlowDialogPreferenceKey: PreferenceKey {
    static var defaultValue: [FlowDialogRequest] = []

    static func reduce(value: inout [FlowDialogRequest], nextValue: () -> [FlowDialogRequest]) {
        value.append(contentsOf: nextValue())
    }
}

private struct FlowDialogHostAvailableKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var flowDialogHostAvailable: Bool {
        get { self[FlowDialogHostAvailableKey.self] }
        set { self[FlowDialogHostAvailableKey.self] = newValue }
    }
}

/// Scrim plus centered dialog; Esc closes, Return runs the primary action.
private struct FlowDialogOverlay: View {
    let request: FlowDialogRequest
    @State private var appeared = false

    var body: some View {
        ZStack {
            FlowColor.scrim
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { request.dismiss() }
            request.view
                .scaleEffect(appeared || FlowMotion.reduceMotion ? 1 : 0.9)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(FlowMotion.dialogIn) { appeared = true }
        }
        .background(
            FlowKeyMonitor { event in
                if event.keyCode == FlowKeyboard.escapeKeyCode {
                    request.dismiss()
                    return true
                }
                if event.keyCode == FlowKeyboard.returnKeyCode || event.keyCode == FlowKeyboard.keypadEnterKeyCode,
                    let primary = request.primaryAction
                {
                    primary()
                    return true
                }
                return false
            }
            .frame(width: 0, height: 0)
        )
        .transition(.opacity)
    }
}

private struct FlowDialogPresenter<DialogContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let primaryAction: (() -> Void)?
    let dialog: () -> DialogContent

    @Environment(\.flowDialogHostAvailable) private var hostAvailable
    @State private var id = UUID()

    private var request: FlowDialogRequest {
        FlowDialogRequest(
            id: id,
            view: AnyView(dialog()),
            dismiss: { isPresented = false },
            primaryAction: primaryAction
        )
    }

    func body(content: Content) -> some View {
        if hostAvailable {
            content.preference(key: FlowDialogPreferenceKey.self, value: isPresented ? [request] : [])
        } else {
            content.overlay {
                if isPresented {
                    FlowDialogOverlay(request: request)
                }
            }
        }
    }
}

private struct FlowDialogHostModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .environment(\.flowDialogHostAvailable, true)
            .overlayPreferenceValue(FlowDialogPreferenceKey.self) { requests in
                if let request = requests.last {
                    FlowDialogOverlay(request: request)
                        .id(request.id)
                }
            }
    }
}

extension View {
    /// Presents a dialog over the whole window (or over this view when no host is installed).
    /// `primaryAction` runs on Return.
    func flowDialog<DialogContent: View>(
        isPresented: Binding<Bool>,
        primaryAction: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> DialogContent
    ) -> some View {
        modifier(FlowDialogPresenter(isPresented: isPresented, primaryAction: primaryAction, dialog: content))
    }

    /// Installed once by the root view so dialogs cover the whole window.
    func flowDialogHost() -> some View {
        modifier(FlowDialogHostModifier())
    }
}

// MARK: - Text field

struct FlowTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?
    var onSubmit: (() -> Void)?

    @FocusState private var focused: Bool
    @State private var hovering = false

    init(_ placeholder: String, text: Binding<String>, width: CGFloat? = 460, onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.width = width
        self.onSubmit = onSubmit
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FlowRadius.sm, style: .continuous)
        let active = focused || hovering
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .flowText(.sm)
            .foregroundStyle(FlowColor.foreground)
            .focused($focused)
            .onSubmit { onSubmit?() }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(shape.fill(FlowColor.background))
            .overlay(
                shape.strokeBorder(active ? FlowColor.neutral500 : FlowColor.neutral300, lineWidth: active ? 2 : 1)
            )
            .onHover { inside in
                withAnimation(FlowMotion.standard) { hovering = inside }
            }
            .onTapGesture { focused = true }
    }
}
