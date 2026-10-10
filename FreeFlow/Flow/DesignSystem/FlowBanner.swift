import SwiftUI

/// Dark hero banner used by Home, Dictionary and Files. Original gradient art, no photos.
struct FlowBanner<Actions: View>: View {
    let title: Text
    let description: Text?
    let dismissKey: String?
    let actions: Actions

    @AppStorage private var dismissed: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Text-based init: callers compose italic or bold spans themselves.
    init(
        title: Text,
        description: Text? = nil,
        dismissKey: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.description = description
        self.dismissKey = dismissKey
        self.actions = actions()
        self._dismissed = AppStorage(wrappedValue: false, dismissKey ?? "FlowBannerNeverDismissed")
    }

    /// Markdown init: `*italic*` in the title renders in EB Garamond Italic,
    /// `**bold**` in the description renders at weight 600.
    init(
        title: String,
        description: String? = nil,
        dismissKey: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            title: FlowRichText.text(
                title,
                font: FlowFont.serif(36),
                italicFont: FlowFont.serif(36, italic: true),
                boldFont: FlowFont.serif(36, weight: 600)
            ),
            description: description.map {
                FlowRichText.text(
                    $0,
                    font: FlowFont.sans(15),
                    italicFont: FlowFont.sans(15).italic(),
                    boldFont: FlowFont.sans(15, weight: 600)
                )
            },
            dismissKey: dismissKey,
            actions: actions
        )
    }

    var body: some View {
        if !(dismissKey != nil && dismissed) {
            banner
        }
    }

    private var banner: some View {
        let shape = RoundedRectangle(cornerRadius: FlowRadius.lg, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            title
                .font(FlowFont.serif(36))
                .tracking(-1.44)
                .lineSpacing(max(0, 40 - 36 * 1.2))
                .foregroundStyle(FlowColor.lumen)
                .frame(maxWidth: 700, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let description {
                description
                    .font(FlowFont.sans(15))
                    .lineSpacing(0)
                    .foregroundStyle(FlowColor.lumen)
                    .frame(maxWidth: 600, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                actions
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlowBannerArt())
        .clipShape(shape)
        .overlay {
            if colorScheme == .dark {
                shape.strokeBorder(FlowColor.border, lineWidth: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if dismissKey != nil {
                FlowIconButton(icon: .x, variant: .frosted, help: "Dismiss") {
                    withAnimation(FlowMotion.standard) { dismissed = true }
                }
                .padding(.top, 16)
                .padding(.trailing, 16)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

extension FlowBanner where Actions == EmptyView {
    init(title: String, description: String? = nil, dismissKey: String? = nil) {
        self.init(title: title, description: description, dismissKey: dismissKey) { EmptyView() }
    }
}

/// Banner background: #0E0D0C base, 100 degree gradient to #2B2420, warm radial glow.
struct FlowBannerArt: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                FlowColor.hex(0x0E0D0C)
                // CSS 100deg points right and slightly down.
                LinearGradient(
                    colors: [FlowColor.hex(0x0E0D0C), FlowColor.hex(0x2B2420)],
                    startPoint: UnitPoint(x: 0.008, y: 0.413),
                    endPoint: UnitPoint(x: 0.992, y: 0.587)
                )
                RadialGradient(
                    colors: [FlowColor.hex(0xC9A46A, alpha: 0.22), FlowColor.hex(0xC9A46A, alpha: 0)],
                    center: UnitPoint(x: 0.78, y: 0.4),
                    startRadius: 0,
                    endRadius: max(1, geometry.size.width * 0.6)
                )
            }
        }
    }
}
