import Foundation

/// One diarized word as returned by a native STT diarization API (e.g. ElevenLabs `words[]`).
struct DiarizedWord: Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let speakerId: String
    let type: String            // "word" | "spacing" | "audio_event"
}

/// A contiguous run of speech by one speaker. `speaker` is a stable anonymous id
/// (e.g. "speaker_0"); display names are resolved separately via `Transcription.speakerNames`.
struct SpeakerSegment: Codable, Equatable {
    var speaker: String
    var text: String
    var start: TimeInterval
    var end: TimeInterval

    /// Merge consecutive same-speaker words into segments. `spacing` words keep the current
    /// speaker; `audio_event` words are dropped. Leading/trailing whitespace is trimmed and
    /// empty segments removed.
    static func merge(words: [DiarizedWord]) -> [SpeakerSegment] {
        var out: [SpeakerSegment] = []
        for w in words where w.type != "audio_event" {
            if var last = out.last, last.speaker == w.speakerId {
                last.text += w.text
                last.end = w.end
                out[out.count - 1] = last
            } else if w.type == "spacing", out.isEmpty {
                continue // leading spacing with no owner
            } else if w.type == "spacing" {
                var last = out[out.count - 1]
                last.text += w.text
                last.end = w.end
                out[out.count - 1] = last
            } else {
                out.append(SpeakerSegment(speaker: w.speakerId, text: w.text, start: w.start, end: w.end))
            }
        }
        return out
            .map { var s = $0; s.text = s.text.trimmingCharacters(in: .whitespaces); return s }
            .filter { !$0.text.isEmpty }
    }
}
