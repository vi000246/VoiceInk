import Foundation
import SwiftData
import LLMkit

enum CloudTranscriptionError: Error, LocalizedError {
    case unsupportedProvider
    case missingAPIKey
    case invalidAPIKey
    case audioFileNotFound
    case apiRequestFailed(statusCode: Int, message: String)
    case networkError(Error)
    case noTranscriptionReturned
    case dataEncodingError
    case fileTooLarge(bytes: Int, limitBytes: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return String(localized: "The model provider is not supported by this service.")
        case .missingAPIKey:
            return String(localized: "API key for this service is missing. Please configure it in the settings.")
        case .invalidAPIKey:
            return String(localized: "The provided API key is invalid.")
        case .audioFileNotFound:
            return String(localized: "The audio file to transcribe could not be found.")
        case .apiRequestFailed(let statusCode, let message):
            return String(format: String(localized: "The API request failed with status code %lld: %@"), Int64(statusCode), message)
        case .networkError(let error):
            return String(format: String(localized: "A network error occurred: %@"), error.localizedDescription)
        case .noTranscriptionReturned:
            return String(localized: "The API returned an empty or invalid response.")
        case .dataEncodingError:
            return String(localized: "Failed to encode the request body.")
        case .fileTooLarge(let bytes, let limitBytes):
            let mb = Double(bytes) / 1_048_576, limitMB = Double(limitBytes) / 1_048_576
            return String(format: String(localized: "The audio is too large for cloud transcription (%.0f MB; the API limit is about %.0f MB). Long recordings become large 16kHz WAVs — use a local transcription model, or split the file."), mb, limitMB)
        }
    }
}

class CloudTranscriptionService: TranscriptionService {
    private let modelContext: ModelContext
    private lazy var openAICompatibleService = OpenAICompatibleTranscriptionService()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        let audioData = try loadAudioData(from: audioURL)
        let fileName = audioURL.lastPathComponent
        let language = selectedLanguage(from: context)

        do {
            if model.provider == .custom {
                guard let customModel = model as? CustomCloudModel else {
                    throw CloudTranscriptionError.unsupportedProvider
                }
                return try await openAICompatibleService.transcribe(audioURL: audioURL, model: customModel, context: context)
            }

            guard let cloudProvider = CloudProviderRegistry.provider(for: model.provider) else {
                throw CloudTranscriptionError.unsupportedProvider
            }
            let uploadLimit = model.provider.maxUploadBytes
            if audioData.count > uploadLimit {
                throw CloudTranscriptionError.fileTooLarge(bytes: audioData.count, limitBytes: uploadLimit)
            }
            let apiKey = try requireAPIKey(forProvider: cloudProvider.providerKey)
            // no_verbatim is an ElevenLabs scribe_v2-only param the bundled LLMkit client can't send,
            // so route that specific case through the in-repo REST client. Everything else (incl.
            // scribe_v1 or noVerbatim off) uses the normal shared path.
            if context.noVerbatim, model.provider == .elevenLabs, model.name == "scribe_v2" {
                return try await ElevenLabsScribeClient.transcribe(
                    audioData: audioData,
                    fileName: fileName,
                    apiKey: apiKey,
                    model: model.name,
                    language: language,
                    noVerbatim: true,
                    timeout: CloudTranscriptionTimeout.forAudio(audioData))
            }
            return try await cloudProvider.transcribe(
                audioData: audioData,
                fileName: fileName,
                apiKey: apiKey,
                model: model.name,
                language: language,
                prompt: transcriptionPrompt(from: context),
                customVocabulary: getCustomDictionaryTerms(),
                timeout: CloudTranscriptionTimeout.forAudio(audioData)
            )
        } catch let error as CloudTranscriptionError {
            throw error
        } catch let error as LLMKitError {
            throw mapLLMKitError(error)
        } catch {
            throw CloudTranscriptionError.networkError(error)
        }
    }

    // MARK: - Helpers

    private func loadAudioData(from url: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CloudTranscriptionError.audioFileNotFound
        }
        return try Data(contentsOf: url)
    }

    private func requireAPIKey(forProvider provider: String) throws -> String {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: provider), !apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }
        return apiKey
    }

    private func selectedLanguage(from context: TranscriptionRequestContext) -> String? {
        let lang = context.language ?? "auto"
        return (lang == "auto" || lang.isEmpty) ? nil : lang
    }

    private func transcriptionPrompt(from context: TranscriptionRequestContext) -> String? {
        let prompt = context.prompt ?? ""
        return prompt.isEmpty ? nil : prompt
    }

    private func getCustomDictionaryTerms() -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let vocabularyWords = try? modelContext.fetch(descriptor) else {
            return []
        }
        var seen = Set<String>()
        var unique: [String] = []
        for word in vocabularyWords {
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(trimmed)
            }
        }
        return unique
    }

    private func mapLLMKitError(_ error: LLMKitError) -> CloudTranscriptionError {
        switch error {
        case .missingAPIKey:
            return .missingAPIKey
        case .httpError(let statusCode, let message):
            return .apiRequestFailed(statusCode: statusCode, message: message)
        case .noResultReturned:
            return .noTranscriptionReturned
        case .encodingError:
            return .dataEncodingError
        case .networkError(let detail):
            return .networkError(NSError(domain: "LLMkit", code: -1, userInfo: [NSLocalizedDescriptionKey: detail]))
        case .invalidURL, .decodingError, .timeout:
            return .networkError(error)
        }
    }
}
