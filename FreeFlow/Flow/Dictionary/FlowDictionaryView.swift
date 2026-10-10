import AppKit
import SwiftUI

/// The Dictionary page: banner, All / Personal tabs, search, sort, refresh and
/// the word list with star, edit and delete.
struct FlowDictionaryView: View {
    @ObservedObject private var store = FlowDictionaryStore.shared
    @StateObject private var addModel = FlowDictionaryAddModel()

    @AppStorage(FlowKeys.dictionarySort) private var sortRaw = FlowDictionarySort.newest.rawValue

    @State private var tab = 0                       // 0 All, 1 Personal
    @State private var query = ""
    @State private var visible: [FlowDictionaryEntry] = []
    @State private var hasFiltered = false
    @State private var selectedID: String?
    @State private var deleteTarget: FlowDictionaryEntry?
    @State private var refreshTurns: Double = 0

    private static let bannerDismissKey = "FlowDictionaryBannerDismissed"

    private var sort: FlowDictionarySort {
        FlowDictionarySort(rawValue: sortRaw) ?? .newest
    }

    private struct FilterInputs: Equatable {
        let entries: [FlowDictionaryEntry]
        let query: String
        let personalOnly: Bool
        let sort: FlowDictionarySort
    }

    private var filterInputs: FilterInputs {
        FilterInputs(entries: store.entries, query: query, personalOnly: tab == 1, sort: sort)
    }

    var body: some View {
        FlowPage(title: "Dictionary") {
            Button("Add new") { addModel.presentAdd() }
                .buttonStyle(FlowButtonStyle(variant: .primary))
                .keyboardShortcut("n", modifiers: .command)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                banner
                tabs
                    .padding(.top, 16)
                list
                    .padding(.top, 24)
                    .padding(.bottom, 24)
            }
        }
        .task(id: filterInputs) {
            let inputs = filterInputs
            let result = await Task.detached(priority: .userInitiated) {
                Self.filtered(inputs)
            }.value
            guard !Task.isCancelled else { return }
            visible = result
            hasFiltered = true
            if let selectedID, !result.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
        }
        .background(
            FlowKeyMonitor { event in handleKey(event) }
                .frame(width: 0, height: 0)
        )
        .flowDialog(isPresented: $addModel.isPresented, primaryAction: { addModel.submit() }) {
            FlowDictionaryAddDialog(model: addModel)
        }
        .flowDialog(isPresented: deletePresented, primaryAction: { confirmDelete() }) {
            FlowDialog(
                title: "Delete from personal vocabulary?",
                subtitle: "'\(deleteTarget?.phrase ?? "")' will be deleted permanently."
            ) {
                Button("Cancel") { deleteTarget = nil }
                    .buttonStyle(FlowButtonStyle(variant: .secondary))
                Button("Delete") { confirmDelete() }
                    .buttonStyle(FlowButtonStyle(variant: .destructive))
            }
        }
    }

    // MARK: - Banner

    private var banner: some View {
        FlowBanner(
            title: "Free Flow spells the way *you* do.",
            description: "Fix a spelling once or add it here, and Free Flow will get **names, jargon and unusual words** right every time you dictate.",
            dismissKey: Self.bannerDismissKey
        ) {
            FlowDictionaryWrapLayout(spacing: 8) {
                Button("Add new word") { addModel.presentAdd() }
                    .buttonStyle(FlowButtonStyle(variant: .secondary, size: .sm))
                ForEach(["Free Flow", "Sam", "Kubernetes"], id: \.self) { word in
                    FlowDictionarySuggestionChip(action: { addModel.presentAdd(phrase: word) }) {
                        Text(word)
                    }
                }
                FlowDictionarySuggestionChip(action: { addModel.presentAdd(phrase: "teh", replacement: "the") }) {
                    HStack(spacing: 6) {
                        Text("teh")
                            .strikethrough()
                            .foregroundStyle(FlowColor.foregroundTertiary)
                        FlowIcon(.arrowRight, size: 14)
                        Text("the")
                    }
                }
            }
        }
    }

    // MARK: - Tabs and utilities

    private var tabs: some View {
        FlowTabs(items: ["All", "Personal"], selection: $tab) {
            HStack(spacing: 4) {
                FlowSearchField(text: $query, placeholder: "Search your vocabulary")

                FlowMenuButton(
                    icon: .arrowUpDown,
                    variant: .toolbar,
                    color: FlowColor.vast300,
                    alignment: .trailing,
                    minWidth: 200
                ) {
                    sortMenuItems()
                }
                .flowHint("Sort")

                FlowIconButton(icon: .refreshCw, variant: .toolbar, color: FlowColor.vast300, help: "Refresh") {
                    refresh()
                }
                .rotationEffect(.degrees(refreshTurns * 360))
            }
        }
    }

    private func sortMenuItems() -> [FlowMenuItem] {
        var items: [FlowMenuItem] = [.section("SORT BY")]
        for option in FlowDictionarySort.allCases {
            items.append(.button(option.title, checked: option == sort) {
                sortRaw = option.rawValue
            })
        }
        return items
    }

    private func refresh() {
        store.reload()
        if FlowMotion.reduceMotion {
            return
        }
        withAnimation(.easeInOut(duration: 0.6)) {
            refreshTurns += 1
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if !hasFiltered {
            Color.clear.frame(height: 1)
        } else if visible.isEmpty {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                FlowEmptyState(
                    icon: .bookText,
                    title: "Your dictionary is empty",
                    body: "Add names, terms and spellings so Free Flow gets them right."
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
            } else {
                noResults
            }
        } else {
            rows
        }
    }

    private var rows: some View {
        let shape = RoundedRectangle(cornerRadius: FlowRadius.lg, style: .continuous)
        // Lazy so dictionaries with thousands of entries stay smooth.
        return LazyVStack(spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                VStack(spacing: 0) {
                    if index > 0 {
                        Rectangle().fill(FlowColor.border).frame(height: 1)
                    }
                    FlowDictionaryRow(
                        entry: entry,
                        query: query,
                        isSelected: selectedID == entry.id,
                        onSelect: { selectedID = entry.id },
                        onStar: { store.setStarred(entry, !entry.isStarred) },
                        onEdit: {
                            selectedID = entry.id
                            addModel.presentEdit(entry)
                        },
                        onDelete: {
                            selectedID = entry.id
                            deleteTarget = entry
                        }
                    )
                }
            }
        }
        .background(FlowColor.background)
        .clipShape(shape)
        .overlay(shape.strokeBorder(FlowColor.border, lineWidth: 1))
    }

    private var noResults: some View {
        VStack(spacing: 4) {
            Text("No results found")
                .flowText(.mdEmph)
                .foregroundStyle(FlowColor.foreground)
            Text("No words found matching your search")
                .flowText(.sm)
                .foregroundStyle(FlowColor.foregroundTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: FlowRadius.lg, style: .continuous)
                .fill(FlowColor.backgroundTertiary)
        )
        .padding(.top, 32 - 24)   // the list area already has 24 pt above it
        .padding(.bottom, 48 - 24)
    }

    // MARK: - Delete

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private func confirmDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        store.delete(target)
    }

    // MARK: - Keyboard

    /// Up/Down or j/k select, Return edits, Delete asks to delete, "s" toggles star.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !addModel.isPresented,
            deleteTarget == nil,
            FlowNavigator.shared.settingsPane == nil,
            !FlowKeyboard.isEditingText
        else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 126:   // up arrow
            moveSelection(by: -1)
            return true
        case 125:   // down arrow
            moveSelection(by: 1)
            return true
        case FlowKeyboard.returnKeyCode, FlowKeyboard.keypadEnterKeyCode:
            guard let entry = selectedEntry else { return false }
            addModel.presentEdit(entry)
            return true
        case 51, 117:   // delete, forward delete
            guard let entry = selectedEntry else { return false }
            deleteTarget = entry
            return true
        default:
            break
        }

        switch characters {
        case "j":
            moveSelection(by: 1)
            return true
        case "k":
            moveSelection(by: -1)
            return true
        case "s":
            guard let entry = selectedEntry else { return false }
            store.setStarred(entry, !entry.isStarred)
            return true
        default:
            return false
        }
    }

    private var selectedEntry: FlowDictionaryEntry? {
        guard let selectedID else { return nil }
        return visible.first { $0.id == selectedID }
    }

    private func moveSelection(by delta: Int) {
        guard !visible.isEmpty else { return }
        guard let selectedID, let index = visible.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = delta > 0 ? visible.first?.id : visible.last?.id
            return
        }
        let next = min(max(index + delta, 0), visible.count - 1)
        self.selectedID = visible[next].id
    }

    // MARK: - Filtering (off the main thread)

    nonisolated private static func filtered(_ inputs: FilterInputs) -> [FlowDictionaryEntry] {
        let needle = inputs.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = inputs.entries.filter { entry in
            if inputs.personalOnly && !entry.source.isPersonal { return false }
            guard !needle.isEmpty else { return true }
            // The phrase holds every comma-separated variant, so any variant matches.
            if entry.phrase.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
            if let replacement = entry.replacement,
                replacement.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            {
                return true
            }
            return false
        }

        let newestFirst: (FlowDictionaryEntry, FlowDictionaryEntry) -> Bool = { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }

        switch inputs.sort {
        case .starred:
            result.sort { lhs, rhs in
                if lhs.isStarred != rhs.isStarred { return lhs.isStarred }
                return newestFirst(lhs, rhs)
            }
        case .newest:
            result.sort(by: newestFirst)
        case .oldest:
            result.sort { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
        case .alpha:
            result.sort { lhs, rhs in
                let order = lhs.phrase.localizedCaseInsensitiveCompare(rhs.phrase)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.id < rhs.id
            }
        }
        return result
    }
}

// MARK: - Banner pieces

/// Example chip in the banner: a small secondary button at 65% opacity, full on hover.
private struct FlowDictionarySuggestionChip<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(FlowButtonStyle(variant: .secondary, size: .sm))
        .opacity(hovering ? 1 : 0.65)
        .onHover { inside in
            withAnimation(FlowMotion.standard) { hovering = inside }
        }
    }
}

/// Left-aligned wrapping row used for the banner examples.
struct FlowDictionaryWrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
