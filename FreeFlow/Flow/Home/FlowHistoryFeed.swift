import SwiftData
import SwiftUI

/// Day-grouped history list with sticky day headers, search and keyboard navigation.
struct FlowHistoryFeed: View {
    @ObservedObject var model: FlowHistoryModel

    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if model.groups.isEmpty {
                    Section {
                        emptyState
                    } header: {
                        header(title: model.isSearching ? "Results" : "Today", showsSearch: true)
                    }
                } else {
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        Section {
                            FlowListContainer {
                                ForEach(group.items, id: \.id) { transcription in
                                    FlowHistoryRow(transcription: transcription, model: model) {
                                        select(transcription.id)
                                    }
                                    .id(transcription.id)
                                    .onAppear {
                                        // The last few rows are roughly the final 200 pt.
                                        if model.isNearEnd(transcription.id) {
                                            model.loadMore()
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, 8)
                        } header: {
                            header(title: group.title, showsSearch: index == 0)
                        }
                    }

                    if model.hasMore {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { model.loadMore() }
                    }
                }
            }
            .padding(.bottom, 40)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.upArrow) { move(-1, proxy: proxy) }
            .onKeyPress(.downArrow) { move(1, proxy: proxy) }
            .onKeyPress(characters: CharacterSet(charactersIn: "jk"), phases: .down) { press in
                move(press.characters == "j" ? 1 : -1, proxy: proxy)
            }
            .onKeyPress(.return) {
                guard let transcription = model.selectedTranscription else { return .ignored }
                model.copy(transcription)
                return .handled
            }
            .onKeyPress(.space) {
                guard let transcription = model.selectedTranscription,
                    let url = transcription.availableHistoryAudioURL
                else {
                    return .ignored
                }
                FlowRowAudioPlayer.shared.toggle(id: transcription.id, url: url)
                return .handled
            }
            .onKeyPress(.escape) {
                guard model.selectedID != nil else { return .ignored }
                model.selectedID = nil
                return .handled
            }
        }
    }

    // MARK: - Pieces

    private func header(title: String, showsSearch: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .flowText(.label)
                .foregroundStyle(FlowColor.foregroundTertiary)
            Spacer(minLength: 0)
            if showsSearch {
                FlowSearchField(text: $model.searchText, placeholder: "Search past transcripts")
            }
        }
        .frame(minHeight: 28)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(FlowColor.background)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.didLoad {
            VStack(spacing: 8) {
                FlowSkeletonBar(height: 56)
                FlowSkeletonBar(height: 56)
            }
        } else if model.isSearching {
            FlowEmptyState(
                icon: .search,
                title: "No matching transcripts",
                body: "Try a different word or phrase."
            )
        } else {
            FlowEmptyState(
                icon: .search,
                title: "No dictations yet",
                body: "Once you dictate across different apps, your entire dictation history will appear here."
            )
        }
    }

    // MARK: - Keyboard

    private func select(_ id: UUID) {
        model.selectedID = id
        focused = true
    }

    private func move(_ delta: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !model.items.isEmpty else { return .ignored }
        model.moveSelection(by: delta)
        if let id = model.selectedID {
            withAnimation(FlowMotion.respecting(FlowMotion.standard)) {
                proxy.scrollTo(id)
            }
        }
        return .handled
    }
}
