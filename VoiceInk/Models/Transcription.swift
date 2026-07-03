import Foundation
import SwiftData

enum TranscriptionStatus: String, Codable {
    case pending
    case completed
    case failed
    case canceled
}

@Model
final class Transcription {
    static let canceledTranscriptionText = "The transcription was canceled."

    var id: UUID = UUID()
    var text: String = ""
    var enhancedText: String?
    var timestamp: Date = Date()
    var duration: TimeInterval = 0
    var audioFileURL: String?
    var transcriptionModelName: String?
    var aiEnhancementModelName: String?
    var promptName: String?
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var aiRequestSystemMessage: String?
    var aiRequestUserMessage: String?
    @Attribute(originalName: "powerModeName")
    var modeName: String?
    @Attribute(originalName: "powerModeEmoji")
    var modeEmoji: String?
    var transcriptionStatus: String?
    var recorderSourceDeviceId: UUID?
    var importFingerprint: String?
    var recorderCategoryName: String?
    var recorderCategoryId: UUID?
    /// Recorder display title: `yyyyMMdd HHmm <≤10-char AI summary>`, generated at classification.
    var recorderTitle: String?
    /// User-marked "favorite" recording (yellow star in Recording Management) — a reminder that this
    /// record shouldn't be deleted. Default false; new column so SwiftData lightweight-migrates.
    var recorderFavorite: Bool = false
    var classificationConfidence: Double?
    var exportedFilePath: String?
    var speakerLabeled: Bool = false
    /// True only when the speaker segments' text is the user's real transcript (native diarization,
    /// e.g. ElevenLabs). FluidAudio fallback segments carry local Parakeet-ASR text that may not
    /// match the recording's language (e.g. Chinese), so they must never replace the original
    /// transcript in the UI — the raw-transcript tab shows plain `text` instead.
    var speakerSegmentsAreNative: Bool = false
    /// Newline-joined absolute paths of the split audio chunks, when a long recording was chunked
    /// for cloud transcription. nil for single-file recordings.
    var audioChunkPathsRaw: String?

    /// The playable audio chunks in order. Empty when the recording wasn't chunked.
    var audioChunkURLs: [URL] {
        guard let raw = audioChunkPathsRaw, !raw.isEmpty else { return [] }
        return raw.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    // MARK: - Speaker diarization

    /// JSON-encoded `[SpeakerSegment]` when the transcript was diarized; nil otherwise.
    var speakerSegmentsRaw: String?
    /// JSON-encoded `[speakerId: displayName]` rename map; nil = all anonymous.
    var speakerNamesRaw: String?

    /// Per-speaker segments. Setting a non-empty value flips `speakerLabeled` to true.
    var speakerSegments: [SpeakerSegment] {
        get {
            guard let raw = speakerSegmentsRaw, let data = raw.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([SpeakerSegment].self, from: data)) ?? []
        }
        set {
            speakerSegmentsRaw = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
            speakerLabeled = !newValue.isEmpty
        }
    }

    /// Rename map: speaker id → user-chosen display name.
    var speakerNames: [String: String] {
        get {
            guard let raw = speakerNamesRaw, let data = raw.data(using: .utf8) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            speakerNamesRaw = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Distinct speaker ids in first-appearance order — drives the "講者N" fallback label.
    var orderedSpeakerIds: [String] {
        var seen: [String] = []
        for s in speakerSegments where !seen.contains(s.speaker) { seen.append(s.speaker) }
        return seen
    }

    /// Display name for a speaker id: the rename map wins; otherwise "講者N" by first-appearance order.
    func displayName(for speakerId: String) -> String {
        if let name = speakerNames[speakerId], !name.isEmpty { return name }
        // ElevenLabs detect_speaker_roles returns semantic ids instead of speaker_0/1/…
        switch speakerId {
        case "agent": return "客服"
        case "customer": return "客戶"
        default:
            let idx = orderedSpeakerIds.firstIndex(of: speakerId) ?? 0
            return "講者\(idx + 1)"
        }
    }

    /// Rename a speaker; a blank name removes the override (falls back to 講者N).
    func renameSpeaker(_ speakerId: String, to name: String) {
        var map = speakerNames
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { map.removeValue(forKey: speakerId) } else { map[speakerId] = trimmed }
        speakerNames = map
    }

    init(text: String,
         duration: TimeInterval,
         enhancedText: String? = nil,
         audioFileURL: String? = nil,
         transcriptionModelName: String? = nil,
         aiEnhancementModelName: String? = nil,
         promptName: String? = nil,
         transcriptionDuration: TimeInterval? = nil,
         enhancementDuration: TimeInterval? = nil,
         aiRequestSystemMessage: String? = nil,
         aiRequestUserMessage: String? = nil,
         modeName: String? = nil,
         modeEmoji: String? = nil,
         transcriptionStatus: TranscriptionStatus = .pending,
         recorderSourceDeviceId: UUID? = nil,
         importFingerprint: String? = nil) {
        self.id = UUID()
        self.text = text
        self.enhancedText = enhancedText
        self.timestamp = Date()
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.transcriptionModelName = transcriptionModelName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.promptName = promptName
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.aiRequestSystemMessage = aiRequestSystemMessage
        self.aiRequestUserMessage = aiRequestUserMessage
        self.modeName = modeName
        self.modeEmoji = modeEmoji
        self.transcriptionStatus = transcriptionStatus.rawValue
        self.recorderSourceDeviceId = recorderSourceDeviceId
        self.importFingerprint = importFingerprint
    }

    func markAsCanceledTranscription(
        duration: TimeInterval? = nil,
        modelName: String? = nil
    ) {
        text = Self.canceledTranscriptionText
        enhancedText = nil
        transcriptionStatus = TranscriptionStatus.canceled.rawValue
        if let duration {
            self.duration = duration
        }
        if let modelName {
            transcriptionModelName = modelName
        }
        transcriptionDuration = nil
        enhancementDuration = nil
        aiEnhancementModelName = nil
        promptName = nil
        aiRequestSystemMessage = nil
        aiRequestUserMessage = nil
    }
}
