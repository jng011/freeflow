import AppKit
import Combine
import Foundation
import OSLog
import SwiftData

/// One local calendar day of history rows.
struct FlowHistoryGroup: Identifiable {
    let day: Date
    let title: String
    let items: [Transcription]

    var id: Date { day }
}

/// Paged, searchable dictation history for the home feed. Files transcriptions are excluded.
@MainActor
final class FlowHistoryModel: ObservableObject {
    static let firstPageSize = 25
    static let nextPageSize = 10
    static let searchLimit = 500
    static let rawFileName = "flow-history-raw.json"

    @Published private(set) var groups: [FlowHistoryGroup] = []
    @Published private(set) var items: [Transcription] = []
    @Published private(set) var hasMore = false
    @Published private(set) var didLoad = false
    @Published private(set) var rawIDs: Set<UUID> = []
    @Published var selectedID: UUID?
    @Published var searchText = "" {
        didSet {
            guard oldValue != searchText else { return }
            limit = Self.firstPageSize
            reload()
        }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var context: ModelContext?
    private var limit = FlowHistoryModel.firstPageSize
    private var cancellables = Set<AnyCancellable>()
    private var pendingReload: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.jaydenghiyam.parle", category: "FlowHistoryModel")

    init() {
        rawIDs = Self.loadRawIDs()

        let center = NotificationCenter.default
        Publishers.MergeMany(
            center.publisher(for: .transcriptionCreated),
            center.publisher(for: .transcriptionCompleted),
            center.publisher(for: .transcriptionDeleted)
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.scheduleReload()
        }
        .store(in: &cancellables)

        FlowFilesStore.shared.$transcriptionIDs
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleReload()
            }
            .store(in: &cancellables)
    }

    /// Binds the model to the window's context and loads the first page.
    func attach(_ context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        reload()
    }

    // MARK: - Loading

    /// Coalesces bursts of notifications (created + completed arrive together).
    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func reload() {
        guard let context else { return }
        let excluded = FlowFilesStore.shared.transcriptionIDs
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        if query.isEmpty {
            // Fetch enough rows to fill the page after dropping Files rows, plus one to detect more.
            descriptor.fetchLimit = limit + excluded.count + 1
        } else {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.text.localizedStandardContains(query)
                    || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
            }
            descriptor.fetchLimit = Self.searchLimit + excluded.count
        }

        let fetched: [Transcription]
        do {
            fetched = try context.fetch(descriptor)
        } catch {
            logger.error("History fetch failed: \(error.localizedDescription, privacy: .public)")
            fetched = []
        }

        let visible = fetched.filter { !excluded.contains($0.id) }
        let page = Array(visible.prefix(limit))
        hasMore = visible.count > page.count
        items = page
        groups = Self.group(page)
        didLoad = true

        if let selectedID, !page.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    /// True for the last few loaded rows, about 200 pt before the end of the list.
    func isNearEnd(_ id: UUID) -> Bool {
        guard hasMore, let index = items.lastIndex(where: { $0.id == id }) else { return false }
        return index >= items.count - 4
    }

    /// Loads the next 10 rows (infinite scroll).
    func loadMore() {
        guard hasMore else { return }
        limit += Self.nextPageSize
        reload()
    }

    // MARK: - Grouping

    private static func group(_ items: [Transcription]) -> [FlowHistoryGroup] {
        let calendar = Calendar.current
        var result: [FlowHistoryGroup] = []
        var currentDay: Date?
        var bucket: [Transcription] = []

        func flush() {
            guard let day = currentDay, !bucket.isEmpty else { return }
            result.append(FlowHistoryGroup(day: day, title: title(for: day), items: bucket))
        }

        for item in items {
            let day = calendar.startOfDay(for: item.timestamp)
            if day != currentDay {
                flush()
                currentDay = day
                bucket = []
            }
            bucket.append(item)
        }
        flush()
        return result
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return dayFormatter.string(from: day)
    }

    // MARK: - Row state

    func isRaw(_ transcription: Transcription) -> Bool {
        rawIDs.contains(transcription.id)
    }

    /// enhancedText when present and not toggled to raw, otherwise text.
    func displayText(for transcription: Transcription) -> String {
        if transcription.hasEnhancedHistoryText && !rawIDs.contains(transcription.id) {
            return transcription.preferredHistoryText
        }
        return transcription.text
    }

    /// "Undo AI edit" / "Redo AI edit".
    func toggleRaw(_ transcription: Transcription) {
        if rawIDs.contains(transcription.id) {
            rawIDs.remove(transcription.id)
        } else {
            rawIDs.insert(transcription.id)
        }
        Self.saveRawIDs(rawIDs)
    }

    // MARK: - Selection

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in items.firstIndex { $0.id == id } }
        let next: Int
        if let currentIndex {
            next = min(max(0, currentIndex + delta), items.count - 1)
        } else {
            next = delta >= 0 ? 0 : items.count - 1
        }
        selectedID = items[next].id
        if next >= items.count - 2 {
            loadMore()
        }
    }

    var selectedTranscription: Transcription? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    // MARK: - Actions

    func copy(_ transcription: Transcription) {
        let text = displayText(for: transcription)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        FlowToastCenter.shared.show("Transcript copied")
    }

    /// Deletes the row, its audio and its raw-toggle state.
    func delete(_ transcription: Transcription) {
        guard let context else { return }
        let id = transcription.id
        let audioURL = transcription.availableHistoryAudioURL

        FlowRowAudioPlayer.shared.stopIfPlaying(id)
        if selectedID == id { selectedID = nil }
        items.removeAll { $0.id == id }
        groups = Self.group(items)

        context.delete(transcription)
        do {
            try context.save()
        } catch {
            logger.error("Could not delete transcript: \(error.localizedDescription, privacy: .public)")
        }

        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        if rawIDs.remove(id) != nil {
            Self.saveRawIDs(rawIDs)
        }

        // The model object is gone after save, so listeners get the id instead.
        NotificationCenter.default.post(
            name: .transcriptionDeleted,
            object: nil,
            userInfo: ["transcriptionID": id]
        )
    }

    // MARK: - Raw-toggle persistence

    private static func loadRawIDs() -> Set<UUID> {
        let url = FlowPaths.file(rawFileName)
        guard let data = try? Data(contentsOf: url),
            let strings = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private static func saveRawIDs(_ ids: Set<UUID>) {
        let strings = ids.map(\.uuidString).sorted()
        guard let data = try? JSONEncoder().encode(strings) else { return }
        try? data.write(to: FlowPaths.file(rawFileName), options: .atomic)
    }
}
