import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

@MainActor
class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()

    // MARK: - Published State

    @Published var queue: [AudioFileQueueItem] = []
    @Published var isProcessingQueue = false
    @Published var lastCompletedItemId: UUID?
    /// Bumped on fine-grained progress (e.g. each transcribed chunk) so observers refresh live even
    /// though the change lives on an individual queue item rather than this manager's own state.
    @Published var activityTick: UInt64 = 0

    // MARK: - Private

    private var processingTask: Task<Void, Never>?
    private var processingGeneration: UInt64 = 0
    private let audioProcessor = AudioProcessor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionManager")

    private init() {}

    // MARK: - Queue Management

    /// Add one or more audio file URLs to the queue. Invalid files are silently skipped.
    func addToQueue(urls: [URL]) {
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard SupportedMedia.isSupported(url: url) else { continue }

            // Avoid adding the same file path twice if it's already pending/processing
            let path = url.standardizedFileURL.path
            if queue.contains(where: { $0.url.standardizedFileURL.path == path && !$0.status.isTerminal }) {
                continue
            }

            let item = AudioFileQueueItem(url: url)
            queue.append(item)
        }
    }

    /// Add audio file URLs tagged with their origin. Recorder imports bypass Mode enhancement.
    func addToQueue(urls: [URL], origin: QueueItemOrigin) {
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard SupportedMedia.isSupported(url: url) else { continue }

            let path = url.standardizedFileURL.path
            if queue.contains(where: { $0.url.standardizedFileURL.path == path && !$0.status.isTerminal }) {
                continue
            }

            queue.append(AudioFileQueueItem(url: url, origin: origin))
        }
    }

    /// Remove a pending item from the queue.
    func removeFromQueue(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue[index]

        // Only allow removing pending items
        guard case .pending = item.status else { return }

        queue.remove(at: index)
    }

    /// Clear all items from the queue, cancelling any in-progress work.
    func clearAll() {
        cancelProcessing()
        queue.removeAll()
        lastCompletedItemId = nil
    }

    /// Retry a failed item by resetting it to pending and re-enqueuing.
    func retryItem(id: UUID) {
        guard let item = queue.first(where: { $0.id == id }),
              case .failed = item.status else { return }

        item.status = .pending
    }

    /// Start processing pending items in the queue sequentially.
    func startProcessing(modelContext: ModelContext, engine: VoiceInkEngine, mode: ModeConfig) {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        processingGeneration &+= 1
        let generation = processingGeneration

        processingTask = Task { [weak self] in
            guard let self else { return }

            while let item = self.nextPendingItem() {
                guard !Task.isCancelled else { break }
                await self.processItem(item, modelContext: modelContext, engine: engine, mode: mode)
            }

            if self.processingGeneration == generation {
                self.isProcessingQueue = false
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessingQueue = false

        // Reset any in-progress items back to pending
        for item in queue {
            if case .processing = item.status {
                item.status = .pending
            }
        }
    }

    var hasPendingItems: Bool {
        queue.contains { if case .pending = $0.status { return true }; return false }
    }

    // MARK: - Private

    private func nextPendingItem() -> AudioFileQueueItem? {
        queue.first { if case .pending = $0.status { return true }; return false }
    }

    private func processItem(_ item: AudioFileQueueItem, modelContext: ModelContext, engine: VoiceInkEngine, mode: ModeConfig) async {
        let serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager,
            modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )

        do {
            guard let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                mode: mode,
                transcriptionModelManager: engine.transcriptionModelManager
            ) else {
                throw TranscriptionError.noModelSelected
            }
            let currentModel = transcriptionConfiguration.model

            // Phase: Loading
            item.status = .processing(phase: .loading)
            try Task.checkCancellation()

            // Phase: Processing Audio
            item.status = .processing(phase: .processingAudio)

            let accessing = item.url.startAccessingSecurityScopedResource()
            defer { if accessing { item.url.stopAccessingSecurityScopedResource() } }

            let samples = try await audioProcessor.processAudioToSamples(item.url)
            try Task.checkCancellation()

            let audioAsset = AVURLAsset(url: item.url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

            let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.prakashjoshipax.VoiceInk")
                .appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            try Task.checkCancellation()

            // Phase: Transcribing. Long recordings on cloud models are split into <25MB WAV chunks,
            // transcribed one at a time, and the transcripts merged back together.
            item.status = .processing(phase: .transcribing)
            let transcriptionStart = Date()
            let (rawText, chunkURLs) = try await transcribeSamples(
                samples, model: currentModel,
                requestContext: transcriptionConfiguration.requestContext,
                registry: serviceRegistry, recordingsDirectory: recordingsDirectory, item: item
            )
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            let permanentURL = chunkURLs.first!   // transcribeSamples always yields at least one chunk
            var text = TranscriptionOutputFilter.filter(rawText)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            let modeMetadata = transcriptionConfiguration.metadata
            let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text
            try Task.checkCancellation()

            // Handle enhancement if enabled
            var transcription: Transcription

            let enhancementConfiguration = engine.enhancementService
                .flatMap { enhancementService in
                    enhancementService.getAIService().map { aiService in
                        ModeRuntimeResolver.currentEnhancementConfiguration(
                            mode: mode,
                            enhancementService: enhancementService,
                            aiService: aiService
                        )
                    }
                }

            if case .manual = item.origin,
               let enhancementService = engine.enhancementService,
               let enhancementConfiguration,
               enhancementConfiguration.isEnabled,
               enhancementService.isConfigured(for: enhancementConfiguration) {
                item.status = .processing(phase: .enhancing)
                do {
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                        text,
                        configuration: enhancementConfiguration
                    )
                    transcription = Transcription(
                        text: cleanedText,
                        duration: duration,
                        enhancedText: enhancedText,
                        audioFileURL: permanentURL.absoluteString,
                        transcriptionModelName: currentModel.displayName,
                        aiEnhancementModelName: enhancementConfiguration.modelName ?? enhancementConfiguration.provider?.defaultModel,
                        promptName: promptName,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancementDuration,
                        aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                        aiRequestUserMessage: enhancementService.lastUserMessageSent,
                        modeName: modeMetadata.name,
                        modeEmoji: modeMetadata.emoji
                    )
                } catch {
                    logger.error("Enhancement failed: \(error, privacy: .public)")
                    transcription = Transcription(
                        text: cleanedText,
                        duration: duration,
                        enhancedText: "Enhancement failed: \(error.localizedDescription)",
                        audioFileURL: permanentURL.absoluteString,
                        transcriptionModelName: currentModel.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration,
                        modeName: modeMetadata.name,
                        modeEmoji: modeMetadata.emoji
                    )
                }
            } else {
                transcription = Transcription(
                    text: cleanedText,
                    duration: duration,
                    audioFileURL: permanentURL.absoluteString,
                    transcriptionModelName: currentModel.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    modeName: modeMetadata.name,
                    modeEmoji: modeMetadata.emoji
                )
            }

            if case let .recorderImport(deviceId, fingerprint) = item.origin {
                transcription.recorderSourceDeviceId = deviceId
                transcription.importFingerprint = fingerprint
            }
            if chunkURLs.count > 1 {
                transcription.audioChunkPathsRaw = chunkURLs.map { $0.path }.joined(separator: "\n")
            }
            item.chunkProgress = nil

            modelContext.insert(transcription)
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

            item.transcription = transcription
            item.status = .completed
            lastCompletedItemId = item.id

            // Recorder items: run the M2 post-processing pipeline (classify → route → summarize →
            // enhance with category prompt → export). The raw transcript above is already persisted.
            if case let .recorderImport(deviceId, _) = item.origin,
               let enhancementService = engine.enhancementService,
               let aiService = enhancementService.getAIService() {
                let device = RecorderConfigStore.shared.device(byId: deviceId)
                await RecorderPostProcessor.shared.process(
                    transcription: transcription, rawText: cleanedText, device: device,
                    modelContext: modelContext, enhancementService: enhancementService, aiService: aiService)
            }

        } catch {
            if Task.isCancelled || error is CancellationError {
                item.status = .pending
            } else {
                logger.error("Transcription error: \(error, privacy: .public)")
                item.status = .failed(message: error.localizedDescription)
                // Recorder imports have no visible queue of their own — surface the failure so it
                // isn't silent (previously the whole recording just vanished with no explanation).
                if case .recorderImport = item.origin {
                    NotificationManager.shared.showNotification(
                        title: "錄音處理失敗：\(error.localizedDescription)", type: .error, duration: 6)
                }
            }
        }

        await serviceRegistry.cleanup()
    }

    /// 16kHz mono samples per WAV chunk. 10 min → ~19MB, safely under the ~25MB cloud upload cap.
    private static let chunkSampleLimit = Int(AudioProcessor.AudioFormat.targetSampleRate) * 600

    /// Transcribe processed samples, chunking long recordings for cloud models. Returns the merged
    /// transcript plus the on-disk WAV chunk(s) — a single WAV when no chunking was needed, or the
    /// ordered split chunks otherwise (each independently playable in Recording Management).
    private func transcribeSamples(
        _ samples: [Float],
        model: any TranscriptionModel,
        requestContext: TranscriptionRequestContext,
        registry: TranscriptionServiceRegistry,
        recordingsDirectory: URL,
        item: AudioFileQueueItem
    ) async throws -> (text: String, chunkURLs: [URL]) {
        let limit = Self.chunkSampleLimit
        let needsChunking = model.provider.usesCloudUpload && samples.count > limit

        guard needsChunking else {
            let url = recordingsDirectory.appendingPathComponent("transcribed_\(UUID().uuidString).wav")
            try audioProcessor.saveSamplesAsWav(samples: samples, to: url)
            try Task.checkCancellation()
            let text = try await registry.transcribe(audioURL: url, model: model, context: requestContext)
            return (text, [url])
        }

        let total = (samples.count + limit - 1) / limit
        let base = UUID().uuidString
        var chunkURLs: [URL] = []
        var pieces: [String] = []
        var failed = 0
        var lastError: Error?
        for i in 0..<total {
            try Task.checkCancellation()
            item.chunkProgress = ChunkProgress(done: i, total: total)
            activityTick &+= 1
            let start = i * limit
            let slice = Array(samples[start..<min(start + limit, samples.count)])
            let url = recordingsDirectory.appendingPathComponent("transcribed_\(base)_part\(i + 1).wav")
            try audioProcessor.saveSamplesAsWav(samples: slice, to: url)
            chunkURLs.append(url)
            do {
                let piece = try await registry.transcribe(audioURL: url, model: model, context: requestContext)
                pieces.append(piece.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One chunk failing shouldn't throw away the whole recording — keep a placeholder and
                // carry on so the rest of the transcript still reaches Recording Management.
                failed += 1
                lastError = error
                logger.error("Recorder chunk \(i + 1)/\(total) failed: \(error, privacy: .public)")
                pieces.append("［第 \(i + 1)/\(total) 段轉錄失敗：\(error.localizedDescription)］")
            }
        }
        item.chunkProgress = ChunkProgress(done: total, total: total)
        activityTick &+= 1
        if failed == total, let lastError { throw lastError }   // nothing succeeded → a real failure
        let merged = pieces.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (merged, chunkURLs)
    }
}

enum TranscriptionError: Error, LocalizedError {
    case noModelSelected
    case transcriptionCancelled

    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return String(localized: "No transcription model selected")
        case .transcriptionCancelled:
            return String(localized: "Transcription was cancelled")
        }
    }
}
