import Foundation

/// Builds a transcription-only `ModeConfig` from Recorder Mode settings so recorder imports
/// transcribe with the recorder's own model — independent of the active voice Mode. AI enhancement
/// is OFF here; recorder analysis is applied later (manually) via `RecorderPostProcessor`.
enum RecorderTranscriptionConfig {
    /// The recorder ALWAYS transcribes with this model — hardcoded to ElevenLabs Scribe V2. This is
    /// the single source of truth: swap this one constant to change the recorder's model later.
    ///
    /// Why fixed to ElevenLabs: it accepts the whole recording in one request (up to 5GB) and
    /// diarizes long audio natively with consistent speaker ids, so the recorder pipeline never has
    /// to chunk for diarization, stitch speakers across chunks, or fall back to a weaker local
    /// diarizer. It is the model's `name` (not displayName) — resolved via `usableModels`, so an
    /// ElevenLabs API key must be configured (otherwise transcription resolution falls back to the
    /// first usable model and native diarization is unavailable).
    static let transcriptionModelName = "scribe_v2"

    static func makeMode(transcriptionModelName: String?, language: String?, textFormatting: Bool,
                         noVerbatim: Bool = false) -> ModeConfig {
        ModeConfig(
            name: "Recorder",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: transcriptionModelName,
            isRealtimeTranscriptionEnabled: false,
            selectedLanguage: language ?? "auto",
            isTextFormattingEnabled: textFormatting,
            noVerbatim: noVerbatim)
    }

    @MainActor static func current() -> ModeConfig {
        let s = RecorderConfigStore.shared
        return makeMode(transcriptionModelName: transcriptionModelName,   // hardcoded ElevenLabs
                        language: s.recorderLanguage,
                        textFormatting: s.recorderTextFormattingEnabled,
                        noVerbatim: s.recorderNoVerbatim)
    }
}
