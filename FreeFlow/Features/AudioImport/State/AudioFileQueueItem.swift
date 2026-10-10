import Foundation

/// Represents a single audio file in the transcription queue.
enum QueueItemStatus: Equatable {
    case pending
    case processing(phase: ProcessingPhase)
    case completed
    case failed(message: String)

    enum ProcessingPhase: String {
        case loading = "Loading model..."
        case processingAudio = "Processing audio..."
        case transcribing = "Transcribing..."
        case enhancing = "Enhancing..."
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }
}

@MainActor
class AudioFileQueueItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let filename: String

    @Published var status: QueueItemStatus = .pending {
        didSet {
            if status != oldValue { phaseStartedAt = Date() }
        }
    }
    @Published var transcription: Transcription?
    /// When the current status/phase began. Drives Flow Files progress estimates.
    @Published var phaseStartedAt: Date?
    /// Media duration in seconds, set as soon as the manager has loaded it.
    @Published var audioDuration: TimeInterval?

    /// The Flow Files job this item belongs to, if any.
    var jobID: UUID?
    /// When true, the manager skips AI enhancement for this item.
    var skipEnhancement = false

    init(url: URL) {
        self.url = url
        self.filename = url.lastPathComponent
    }
}
