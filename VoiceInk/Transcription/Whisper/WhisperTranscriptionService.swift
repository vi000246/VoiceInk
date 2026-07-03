import Foundation
import AVFoundation
import os

class WhisperTranscriptionService: TranscriptionService {

    /// Context created by THIS service (never the provider's shared one), kept loaded across
    /// transcriptions so a batch of recorder imports pays one whisper_init instead of one per file.
    /// Released on model switch and in cleanup() — the registry calls that at end of session/batch,
    /// preserving the app's release-after-use memory policy.
    private var whisperContext: WhisperContext?
    private var cachedModelName: String?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        guard model.provider == .whisper else {
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        // Check if the required model is already loaded in the model provider
        let activeContext: WhisperContext
        if let provider = modelProvider,
           await provider.isModelLoaded,
           let loadedContext = await provider.whisperContext,
           await provider.loadedWhisperModel?.name == model.name {

            logger.notice("Using already loaded model: \(model.name, privacy: .public)")
            activeContext = loadedContext
        } else if let cached = whisperContext, cachedModelName == model.name {
            logger.notice("Reusing cached context for model: \(model.name, privacy: .public)")
            activeContext = cached
        } else {
            await releaseCachedContext()

            // Resolve the on-disk URL using the provider's availableModels (covers imports)
            let resolvedURL: URL? = await modelProvider?.availableModels.first(where: { $0.name == model.name })?.url
            guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }

            logger.notice("Loading model: \(model.name, privacy: .public)")
            do {
                let created = try await WhisperContext.createContext(path: modelURL.path)
                whisperContext = created
                cachedModelName = model.name
                activeContext = created
            } catch {
                logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }
        }

        // Read audio data
        let data = try readAudioSamples(audioURL)

        // Set prompt
        await activeContext.setLanguage(context.language)
        await activeContext.setPrompt(context.prompt ?? "")

        // Transcribe
        let success = await activeContext.fullTranscribe(samples: data)

        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        let text = await activeContext.getTranscription()

        logger.notice("Whisper transcription completed successfully.")

        return text
    }

    /// Frees the service-created context. Never touches the provider's shared context.
    func cleanup() async {
        await releaseCachedContext()
    }

    private func releaseCachedContext() async {
        if let cached = whisperContext {
            await cached.releaseResources()
        }
        whisperContext = nil
        cachedModelName = nil
    }

    private func readAudioSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { return [] }
        // Skip the 44-byte WAV header; single-pass decode (a per-sample Data slice here cost
        // ~1M allocations per minute of audio).
        return PCMAudioConverter.float32Samples(fromPCM16Data: data.dropFirst(44))
    }
}
