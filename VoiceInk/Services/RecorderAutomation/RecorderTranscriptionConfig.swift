import Foundation

/// Builds a transcription-only `ModeConfig` from Recorder Mode settings so recorder imports
/// transcribe with the recorder's own model — independent of the active voice Mode. AI enhancement
/// is OFF here; recorder analysis is applied later (manually) via `RecorderPostProcessor`.
enum RecorderTranscriptionConfig {
    static func makeMode(transcriptionModelName: String?, language: String?, textFormatting: Bool) -> ModeConfig {
        ModeConfig(
            name: "Recorder",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: transcriptionModelName,
            isRealtimeTranscriptionEnabled: false,
            selectedLanguage: language ?? "auto",
            isTextFormattingEnabled: textFormatting)
    }

    @MainActor static func current() -> ModeConfig {
        let s = RecorderConfigStore.shared
        return makeMode(transcriptionModelName: s.recorderTranscriptionModelName,
                        language: s.recorderLanguage,
                        textFormatting: s.recorderTextFormattingEnabled)
    }
}
