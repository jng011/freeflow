import SwiftUI

/// One dictionary row: the word (or "phrase → replacement"), an auto-learn
/// sparkle, and star / edit / delete actions that fade in on hover.
struct FlowDictionaryRow: View {
    let entry: FlowDictionaryEntry
    let query: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onStar: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var showsActions: Bool { isHovered || isSelected }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(Self.attributedTitle(for: entry, query: query))
                    .flowText(.sm)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .textSelection(.disabled)

                if entry.isAutoLearned {
                    FlowIcon(.sparkles, size: 14, color: FlowColor.dawn700)
                        .flowHint("Free Flow learned this word automatically ✨")
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                FlowIconButton(
                    icon: .star,
                    size: .md,
                    variant: .rowAction,
                    color: entry.isStarred ? FlowColor.dawn700 : FlowColor.neutral600,
                    help: entry.isStarred ? "Unstar" : "Star",
                    action: onStar
                )
                .overlay {
                    if entry.isStarred {
                        // Lucide icons are stroke-only; fill the starred state.
                        Image(systemName: "star.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(FlowColor.dawn700)
                            .allowsHitTesting(false)
                    }
                }
                .opacity(showsActions || entry.isStarred ? 1 : 0)

                Group {
                    FlowIconButton(
                        icon: .pencil, size: .md, variant: .rowAction,
                        color: FlowColor.neutral600, help: "Edit", action: onEdit)
                    FlowIconButton(
                        icon: .trash, size: .md, variant: .rowAction,
                        color: FlowColor.neutral600, help: "Delete", action: onDelete)
                }
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
            }
            // Buttons are 28 pt; keep the row height driven by the text.
            .frame(height: 20)
            .animation(.easeOut(duration: 0.15), value: showsActions)
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(FlowMotion.standard) { isHovered = hovering }
        }
        .onTapGesture(count: 2) { onEdit() }
        .onTapGesture { onSelect() }
        .contextMenu {
            Button(entry.isStarred ? "Unstar" : "Star", action: onStar)
            Button("Edit", action: onEdit)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
    }

    private var rowBackground: Color {
        if isHovered { return FlowColor.backgroundTertiary }
        if isSelected { return FlowColor.dictSelected }
        return .clear
    }

    // MARK: - Text

    static func attributedTitle(for entry: FlowDictionaryEntry, query: String) -> AttributedString {
        var result = highlighted(entry.phrase, query: query)
        if let replacement = entry.replacement {
            var arrow = AttributedString(" → ")
            arrow.foregroundColor = FlowColor.foregroundTertiary
            result += arrow
            result += highlighted(replacement, query: query)
        }
        return result
    }

    /// Text in `foreground` with every case-insensitive match of `query`
    /// on a #FFE788 background.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            var plain = AttributedString(text)
            plain.foregroundColor = FlowColor.foreground
            return plain
        }

        var result = AttributedString()
        var cursor = text.startIndex
        while cursor < text.endIndex,
            let found = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: cursor..<text.endIndex
            )
        {
            if cursor < found.lowerBound {
                var before = AttributedString(String(text[cursor..<found.lowerBound]))
                before.foregroundColor = FlowColor.foreground
                result += before
            }
            var match = AttributedString(String(text[found]))
            match.backgroundColor = FlowColor.searchHighlight
            // The highlight is light in both themes, so the text stays dark.
            match.foregroundColor = FlowColor.vast950
            result += match
            guard found.upperBound > cursor else { break }
            cursor = found.upperBound
        }
        if cursor < text.endIndex {
            var rest = AttributedString(String(text[cursor...]))
            rest.foregroundColor = FlowColor.foreground
            result += rest
        }
        return result
    }
}
