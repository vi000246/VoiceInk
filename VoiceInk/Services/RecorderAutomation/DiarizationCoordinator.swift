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

    /// Merged speaker segments for the audio, or nil when diarization can't produce anything
    /// (degrade to plain transcript). Native-capable models (ElevenLabs) use their word-accurate
    /// API; every other model — and any native failure — falls back to the on-device FluidAudio
    /// diarizer so diarization is universal across all transcription models.
    static func diarize(audioURL: URL, transcriptionModelName: String?,
                        language: String?, expectedSpeakers: Int?) async -> [SpeakerSegment]? {
        if supportsNativeDiarization(modelName: transcriptionModelName),
           let modelName = transcriptionModelName {
            if let native = await nativeElevenLabs(audioURL: audioURL, modelName: modelName,
                                                   language: language, expectedSpeakers: expectedSpeakers) {
                return native
            }
            // Native path failed (no key / API error) → still try the local fallback below.
        }
        // Universal on-device fallback (FluidAudio ASR + diarizer, aligned).
        return await FluidAudioDiarizer.shared.diarize(
            audioURL: audioURL,
            expectedSpeakers: expectedSpeakers,
            onFirstDownload: {
                NotificationManager.shared.showNotification(
                    title: "首次語者辨識：正在下載本地模型…", type: .info, duration: 4)
            })
    }

    /// ElevenLabs native diarization via the in-repo client. nil on missing key / unreadable audio /
    /// API error so the coordinator can fall back to the local diarizer.
    private static func nativeElevenLabs(audioURL: URL, modelName: String,
                                         language: String?, expectedSpeakers: Int?) async -> [SpeakerSegment]? {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "ElevenLabs"), !apiKey.isEmpty else {
            logger.notice("Native diarization skipped — no ElevenLabs API key")
            return nil
        }
        guard let audioData = try? Data(contentsOf: audioURL) else {
            logger.error("Native diarization skipped — cannot read audio at \(audioURL.lastPathComponent, privacy: .public)")
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
            logger.notice("Native diarization produced \(result.segments.count, privacy: .public) segments")
            return result.segments
        } catch {
            logger.error("Native diarization failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
