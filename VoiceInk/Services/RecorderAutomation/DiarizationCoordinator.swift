import Foundation
import os

/// Provider-agnostic diarization entry for recorder transcripts.
///
/// M1: native ElevenLabs only. Non-native models return nil (graceful skip — the FluidAudio local
/// fallback is M2). Never throws: any failure yields nil so the plain transcript is preserved.
@MainActor
enum DiarizationCoordinator {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")

    /// Pure lookup: is there a cloud model with this name whose provider natively diarizes?
    static func supportsNativeDiarization(modelName: String?) -> Bool {
        guard let modelName else { return false }
        for provider in CloudProviderRegistry.allProviders {
            if let m = provider.models.first(where: { $0.name == modelName }) {
                return m.supportsNativeDiarization
            }
        }
        return false
    }

    /// Merged speaker segments for the audio, or nil when diarization is unavailable (non-native
    /// model in M1) or failed (missing key / API / network error → degrade to plain transcript).
    static func diarize(audioURL: URL, transcriptionModelName: String?,
                        language: String?, expectedSpeakers: Int?) async -> [SpeakerSegment]? {
        guard supportsNativeDiarization(modelName: transcriptionModelName),
              let modelName = transcriptionModelName else { return nil }
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "ElevenLabs"), !apiKey.isEmpty else {
            logger.notice("Diarization skipped — no ElevenLabs API key")
            return nil
        }
        guard let audioData = try? Data(contentsOf: audioURL) else {
            logger.error("Diarization skipped — cannot read audio at \(audioURL.lastPathComponent, privacy: .public)")
            return nil
        }
        do {
            let result = try await ElevenLabsDiarizingClient.transcribeDiarized(
                audioData: audioData,
                fileName: audioURL.lastPathComponent,
                apiKey: apiKey,
                model: modelName,
                language: (language == "auto" ? nil : language),
                numSpeakers: expectedSpeakers,
                timeout: CloudTranscriptionTimeout.forAudio(audioData))
            logger.notice("Diarization produced \(result.segments.count, privacy: .public) segments")
            return result.segments
        } catch {
            logger.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
