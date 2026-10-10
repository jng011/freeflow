import SwiftUI

/// Shown when a dictation finished but no editable field had focus, so nothing was pasted.
/// Shows the text with a Copy button. Lifetime and Esc / ⌘C handling live in FlowBarController.
struct FlowNoTextboxCard: View {
    let text: String
    let copied: Bool
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        FlowBarClampedWidth(minWidth: 380, maxWidth: 440) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Text(text)
                    .font(FlowFont.sans(15, weight: 400))
                    .foregroundStyle(FlowBarPalette.mutedText)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                HStack {
                    Spacer(minLength: 0)
                    FlowNoTextboxCopyButton(copied: copied, action: onCopy)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .topTrailing) {
            FlowNoTextboxCloseButton(action: onClose)
                .padding(.top, 12)
                .padding(.trailing, 12)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            FlowBarLogoBars()
                .fill(Color.white)
                .frame(width: 21, height: 20)
            Spacer(minLength: 0)
            Text("Select a textbox first, then dictate")
                .font(FlowFont.sans(12, weight: 400))
                .foregroundStyle(FlowBarPalette.light.opacity(0.4))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.top, 16)
        .padding(.leading, 16)
        .padding(.bottom, 20)
        .padding(.trailing, 50)
    }
}

/// Five rounded bars in a 21 x 20 box, the same geometry as the app's logo mark.
/// Drawn here so the card does not depend on the shell's view type.
struct FlowBarLogoBars: Shape {
    private static let xs: [CGFloat] = [1, 5.4, 9.2, 13, 17.4]
    private static let heights: [CGFloat] = [9, 14, 19, 12, 16]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 21, rect.height / 20)
        let originX = rect.midX - 21 * scale / 2
        let originY = rect.midY - 20 * scale / 2
        var path = Path()
        for (x, height) in zip(Self.xs, Self.heights) {
            let bar = CGRect(
                x: originX + x * scale,
                y: originY + (10 - height / 2) * scale,
                width: 2.6 * scale,
                height: height * scale
            )
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: 1.3 * scale, height: 1.3 * scale))
        }
        return path
    }
}

struct FlowNoTextboxCopyButton: View {
    let copied: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(copied ? "Copied" : "Copy")
                    .font(FlowFont.sans(15, weight: 600))
                    .foregroundStyle(FlowBarPalette.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
                if !copied {
                    Text("⌘C")
                        .font(FlowFont.sans(12, weight: 400))
                        .foregroundStyle(FlowBarPalette.secondaryText)
                        .opacity(0.7)
                        .fixedSize()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? FlowBarPalette.primaryActionHover : FlowBarPalette.primaryAction)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// 32 pt circle with a 1.5 pt white 60% ring and a 14 pt white "x".
struct FlowNoTextboxCloseButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isHovered ? 0.08 : 0))
                Circle()
                    .strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
                FlowBarGlyphShape(kind: .cross)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 14, height: 14)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Close")
    }
}
