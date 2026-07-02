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

/// Where a queue item came from. Recorder imports skip Mode enhancement (raw transcript).
enum QueueItemOrigin: Equatable {
    case manual
    case recorderImport(deviceId: UUID, fingerprint: String)
}

/// Sub-progress while transcribing a chunked (long) recording: chunk `done` of `total`.
struct ChunkProgress: Equatable {
    let done: Int
    let total: Int
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

@MainActor
class AudioFileQueueItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let filename: String
    let origin: QueueItemOrigin

    @Published var status: QueueItemStatus = .pending
    @Published var transcription: Transcription?
    /// Set while a long recording is transcribed chunk-by-chunk; nil for single-shot transcription.
    @Published var chunkProgress: ChunkProgress?
    /// When the transcribing phase began — drives the elapsed-seconds display for single-file
    /// (unchunked) uploads, where a progress bar can't reflect real upload progress. nil until then.
    @Published var transcribingStartedAt: Date?

    init(url: URL, origin: QueueItemOrigin = .manual) {
        self.url = url
        self.filename = url.lastPathComponent
        self.origin = origin
    }
}
