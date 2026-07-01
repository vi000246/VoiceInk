import Foundation
import FluidAudio
import os

/// On-device speaker-diarization fallback for transcription models without native diarization.
///
/// Runs FluidAudio Parakeet ASR (for token timings) and the FluidAudio offline diarizer (for the
/// speaker timeline) on the recorder audio, then aligns them into `[SpeakerSegment]`. Fully local —
/// no API cost, no changes to the shared transcription pipeline. Models are lazily loaded + reused.
///
/// The transcript text shown elsewhere (`Transcription.text`) stays as the user's chosen model's
/// output; only the speaker-segmented view uses this FluidAudio-derived text.
@MainActor
final class FluidAudioDiarizer {
    static let shared = FluidAudioDiarizer()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private var diarizer: OfflineDiarizerManager?
    private var asr: AsrManager?
    private init() {}

    /// True once both model sets are loaded in memory (so callers can post a first-run notice).
    private var loaded: Bool { diarizer != nil && asr != nil }

    private func ensureLoaded() async throws {
        if diarizer == nil {
            let d = OfflineDiarizerManager()
            try await d.prepareModels()            // downloads + initializes on first run (idempotent)
            diarizer = d
        }
        if asr == nil {
            // MIRROR FluidAudioTranscriptionService.swift:50-51,92-97 — Parakeet TDT (v3) load.
            let models = try await AsrModels.downloadAndLoad()
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            asr = m
        }
    }

    /// Returns aligned speaker segments, or nil on any failure (caller degrades to plain transcript).
    /// `onFirstDownload` fires once if models still needed loading (for a UI notice).
    /// `expectedSpeakers` is accepted for parity with the native path; the offline diarizer clusters
    /// speakers automatically, so it is unused in M2 (see plan M3 notes).
    func diarize(audioURL: URL, expectedSpeakers: Int?, onFirstDownload: () -> Void) async -> [SpeakerSegment]? {
        _ = expectedSpeakers
        do {
            if !loaded { onFirstDownload() }
            try await ensureLoaded()
            guard let diarizer, let asr else { return nil }

            // Feed BOTH ASR and the diarizer the SAME raw 16kHz samples (no VAD) so their
            // timestamps share one time base and alignment is meaningful.
            let samples = try await AudioProcessor().processAudioToSamples(audioURL)

            var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let asrResult = try await asr.transcribe(samples, decoderState: &decoderState)
            let diaResult = try await diarizer.process(audio: samples)

            let tokens = (asrResult.tokenTimings ?? []).map {
                DiarizationAlignment.Token(text: $0.token, start: $0.startTime, end: $0.endTime)
            }
            let timeline = diaResult.segments.map {
                DiarizationAlignment.SpeakerRange(speaker: $0.speakerId,
                                                  start: TimeInterval($0.startTimeSeconds),
                                                  end: TimeInterval($0.endTimeSeconds))
            }
            guard !tokens.isEmpty, !timeline.isEmpty else {
                logger.notice("FluidAudio diarization produced no tokens/timeline")
                return nil
            }
            let segs = DiarizationAlignment.align(tokens: tokens, timeline: timeline)
            logger.notice("FluidAudio diarization → \(segs.count, privacy: .public) segments")
            return segs.isEmpty ? nil : segs
        } catch {
            logger.error("FluidAudio diarization failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
