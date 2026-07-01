import Foundation
import SwiftData

protocol CloudProvider: Sendable {
    var modelProvider: ModelProvider { get }
    var providerKey: String { get }
    var languageCodes: [String]? { get }
    var includesAutoDetect: Bool { get }
    var models: [CloudModel] { get }
    /// True when the provider has no batch HTTP endpoint and requires streaming for all transcription.
    var isStreamingOnly: Bool { get }

    func transcribe(audioData: Data, fileName: String, apiKey: String, model: String, language: String?, prompt: String?, customVocabulary: [String], timeout: TimeInterval) async throws -> String
    func makeStreamingProvider(modelContext: ModelContext) -> (any StreamingTranscriptionProvider)?
    func verifyAPIKey(_ key: String) async -> (isValid: Bool, errorMessage: String?)
}

extension CloudProvider {
    var isStreamingOnly: Bool { false }

    /// Streaming-only providers inherit this and get a clear error if batch is somehow attempted.
    /// Providers that support batch transcription override this with their real implementation.
    func transcribe(audioData: Data, fileName: String, apiKey: String, model: String, language: String?, prompt: String?, customVocabulary: [String], timeout: TimeInterval) async throws -> String {
        throw CloudTranscriptionError.unsupportedProvider
    }
}

/// Cloud transcription request timeout scaled to the audio size. The per-client 30–60s defaults are
/// tuned for short voice clips and time out on long recordings (a 10-min chunk needs minutes of
/// upload + server processing). Scales generously with bytes, floored/capped for sane bounds.
enum CloudTranscriptionTimeout {
    static func forAudio(_ data: Data) -> TimeInterval {
        min(600, max(60, Double(data.count) / 40_000))
    }
}

enum CloudProviderRegistry {
    static let allProviders: [any CloudProvider] = [
        GroqProvider(),
        ElevenLabsProvider(),
        DeepgramProvider(),
        MistralProvider(),
        GeminiProvider(),
        SonioxProvider(),
        SpeechmaticsProvider(),
        AssemblyAIProvider(),
        XAIProvider(),
        CartesiaProvider()
    ]

    static func provider(for modelProvider: ModelProvider) -> (any CloudProvider)? {
        allProviders.first { $0.modelProvider == modelProvider }
    }
}
