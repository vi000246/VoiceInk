import Foundation
import AVFoundation
import os

/// Speaker-diarization entry for recorder transcripts.
///
/// 方案 C: the recorder is hardcoded to ElevenLabs (see `RecorderTranscriptionConfig`), which accepts
/// the WHOLE recording in one request (up to 5GB) and diarizes long audio natively with speaker ids
/// that stay consistent across the entire transcript. So we diarize the whole recording in ONE call
/// — no chunking for diarization, no cross-chunk speaker stitching, no local fallback. If the model
/// has no native diarization (i.e. the constant was changed to a non-ElevenLabs model) diarization is
/// simply skipped. Never throws: any failure yields nil so the plain transcript is preserved.
@MainActor
enum DiarizationCoordinator {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")

    /// Diarization result. `isNative` is always true here (segments come from ElevenLabs, whose text
    /// IS the user's transcript in the right language); kept as a field so the UI's native/non-native
    /// handling stays intact if the model ever changes.
    struct Outcome {
        let segments: [SpeakerSegment]
        let isNative: Bool
    }

    /// Resolve a cloud model that natively diarizes, matching either its internal `name`
    /// (e.g. "scribe_v2") or its `displayName` (e.g. "Scribe V2"). Callers store the model under
    /// different conventions — Settings keeps `name`, the transcription pipeline keeps `displayName` —
    /// so both must resolve here or native diarization is silently skipped.
    static func nativeModel(matching modelName: String?) -> CloudModel? {
        guard let modelName else { return nil }
        for provider in CloudProviderRegistry.allProviders {
            if let m = provider.models.first(where: {
                $0.supportsNativeDiarization && ($0.name == modelName || $0.displayName == modelName)
            }) {
                return m
            }
        }
        return nil
    }

    /// Pure lookup: is there a cloud model with this name/displayName whose provider natively diarizes?
    static func supportsNativeDiarization(modelName: String?) -> Bool {
        nativeModel(matching: modelName) != nil
    }

    /// Single-file convenience — see the whole-recording overload below.
    static func diarize(audioURL: URL, transcriptionModelName: String?,
                        language: String?, expectedSpeakers: Int?,
                        detectSpeakerRoles: Bool = false) async -> Outcome? {
        await diarize(audioURLs: [audioURL], transcriptionModelName: transcriptionModelName,
                      language: language, expectedSpeakers: expectedSpeakers,
                      detectSpeakerRoles: detectSpeakerRoles)
    }

    /// Speaker segments for the whole recording, or nil when diarization can't produce anything
    /// (degrade to plain transcript).
    ///
    /// The transcript path may have split a long recording into WAV chunks for its own reasons, but
    /// ElevenLabs has no such limit — so for diarization we reassemble the chunks into one file and
    /// send it in a SINGLE request. ElevenLabs then returns one globally-consistent speaker timeline
    /// (its own strong diarizer, up to 48 speakers) instead of restarting speaker numbering per chunk.
    static func diarize(audioURLs: [URL], transcriptionModelName: String?,
                        language: String?, expectedSpeakers: Int?,
                        detectSpeakerRoles: Bool = false) async -> Outcome? {
        let urls = audioURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return nil }
        // Reuse segments the recorder's transcription step already produced in its single diarized
        // call (see transcribeAndDiarizeForRecorder) — avoids transcribing the whole recording twice.
        if let cached = consumeCachedSegments(for: urls) {
            logger.notice("Diarization reused \(cached.count, privacy: .public) segments from the transcription call")
            return Outcome(segments: cached, isNative: true)
        }
        guard let model = nativeModel(matching: transcriptionModelName) else {
            logger.notice("Diarization skipped — model has no native diarization (local fallback was removed)")
            return nil
        }
        // Reassemble the whole recording into one file (single chunk → use it as-is).
        guard let whole = await wholeRecordingAudio(urls) else { return nil }
        defer { if whole.isTemporary { try? FileManager.default.removeItem(at: whole.url) } }

        guard let segments = await nativeElevenLabs(audioURL: whole.url, modelId: model.name,
                                                    language: language, expectedSpeakers: expectedSpeakers,
                                                    detectSpeakerRoles: detectSpeakerRoles) else { return nil }
        return Outcome(segments: segments, isNative: true)
    }

    /// The whole recording as one file to upload. A single chunk is used directly; multiple chunks
    /// are decoded and concatenated back into one 16kHz WAV in a temp file (deleted by the caller).
    /// nil if no chunk can be decoded / written.
    private static func wholeRecordingAudio(_ urls: [URL]) async -> (url: URL, isTemporary: Bool)? {
        if urls.count == 1 { return (urls[0], false) }
        return await Task.detached(priority: .userInitiated) {
            let processor = AudioProcessor()
            var all: [Float] = []
            for url in urls {
                guard let s = try? await processor.processAudioToSamples(url) else { return nil }
                all.append(contentsOf: s)
            }
            guard !all.isEmpty else { return nil }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("diarize-\(UUID().uuidString).wav")
            do {
                try processor.saveSamplesAsWav(samples: all, to: tmp)
                return (tmp, true)
            } catch {
                return nil
            }
        }.value
    }

    // MARK: - Single-call merge (recorder)

    /// Segments produced by the recorder's transcription step, keyed by audio-file path, waiting for
    /// `diarize` to pick them up. Consumed (removed) on read; @MainActor so no locking needed.
    private static var cachedSegments: [String: [SpeakerSegment]] = [:]

    /// One diarized ElevenLabs call used AS the recorder's transcription: returns the transcript text
    /// AND caches the speaker segments keyed by `wavURL`, so the post-processing `diarize` reuses them
    /// instead of transcribing the whole recording a second time. nil (→ caller falls back to a plain
    /// transcription) on missing key / unreadable audio / API error.
    static func transcribeAndDiarizeForRecorder(
        wavURL: URL, modelId: String, language: String?, expectedSpeakers: Int?,
        detectSpeakerRoles: Bool, noVerbatim: Bool) async -> (text: String, segments: [SpeakerSegment])? {
        guard let result = await nativeElevenLabsResult(
            audioURL: wavURL, modelId: modelId, language: language, expectedSpeakers: expectedSpeakers,
            detectSpeakerRoles: detectSpeakerRoles, noVerbatim: noVerbatim) else { return nil }
        cachedSegments[wavURL.path] = result.segments
        return (result.text, result.segments)
    }

    /// Read + remove any cached segments for these audio files (see transcribeAndDiarizeForRecorder).
    private static func consumeCachedSegments(for urls: [URL]) -> [SpeakerSegment]? {
        for url in urls {
            if let segs = cachedSegments.removeValue(forKey: url.path) { return segs }
        }
        return nil
    }

    /// ElevenLabs native diarization of a single (whole-recording) file → merged speaker segments.
    private static func nativeElevenLabs(audioURL: URL, modelId: String,
                                         language: String?, expectedSpeakers: Int?,
                                         detectSpeakerRoles: Bool) async -> [SpeakerSegment]? {
        await nativeElevenLabsResult(audioURL: audioURL, modelId: modelId, language: language,
                                     expectedSpeakers: expectedSpeakers, detectSpeakerRoles: detectSpeakerRoles,
                                     noVerbatim: false)?.segments
    }

    /// One ElevenLabs diarized transcription (text + merged segments). nil on missing key / unreadable
    /// audio / API error so the caller degrades to a plain transcript.
    private static func nativeElevenLabsResult(
        audioURL: URL, modelId: String, language: String?, expectedSpeakers: Int?,
        detectSpeakerRoles: Bool, noVerbatim: Bool) async -> ElevenLabsDiarizingClient.Result? {
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "ElevenLabs"), !apiKey.isEmpty else {
            logger.notice("Native diarization skipped — no ElevenLabs API key")
            return nil
        }
        // Read the whole audio off the main actor — a large recording would otherwise freeze the UI.
        guard let audioData = await Task.detached(priority: .userInitiated, operation: {
            try? Data(contentsOf: audioURL)
        }).value else {
            logger.error("Native diarization skipped — cannot read audio at \(audioURL.lastPathComponent, privacy: .public)")
            return nil
        }
        do {
            let result = try await ElevenLabsDiarizingClient.transcribeDiarized(
                audioData: audioData,
                fileName: audioURL.lastPathComponent,
                apiKey: apiKey,
                model: modelId,
                language: (language == "auto" ? nil : language),
                numSpeakers: expectedSpeakers,
                detectSpeakerRoles: detectSpeakerRoles,
                noVerbatim: noVerbatim,
                timeout: CloudTranscriptionTimeout.forAudio(audioData))
            logger.notice("Native diarization produced \(result.segments.count, privacy: .public) segments")
            return result
        } catch {
            logger.error("Native diarization failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
