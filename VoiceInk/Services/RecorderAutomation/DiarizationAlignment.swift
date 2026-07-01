import Foundation

/// Pure alignment of ASR token timings against a speaker timeline → speaker-labelled segments.
/// Inputs are plain tuples (not FluidAudio types) so this stays unit-testable without models.
enum DiarizationAlignment {
    struct Token: Equatable { let text: String; let start: TimeInterval; let end: TimeInterval }
    struct SpeakerRange: Equatable { let speaker: String; let start: TimeInterval; let end: TimeInterval }

    /// Assign each token to the timeline range with the greatest temporal overlap of the token's
    /// [start,end]; group contiguous same-speaker tokens (in ASR order) into segments.
    /// Parakeet word markers ("▁") become spaces; empty segments are dropped and bounds are snapped
    /// to the matched speaker's timeline range.
    static func align(tokens: [Token], timeline: [SpeakerRange]) -> [SpeakerSegment] {
        guard !timeline.isEmpty else { return [] }
        func overlap(_ t: Token, _ r: SpeakerRange) -> Double {
            max(0, min(t.end, r.end) - max(t.start, r.start))
        }
        var out: [SpeakerSegment] = []
        for t in tokens {
            guard let best = timeline.max(by: { overlap(t, $0) < overlap(t, $1) }),
                  overlap(t, best) > 0 || timeline.count == 1 else { continue }
            let piece = t.text.replacingOccurrences(of: "▁", with: " ")
            if var last = out.last, last.speaker == best.speaker {
                last.text += piece
                last.end = max(last.end, t.end)
                out[out.count - 1] = last
            } else {
                out.append(SpeakerSegment(speaker: best.speaker, text: piece, start: t.start, end: t.end))
            }
        }
        return out.compactMap { seg in
            let text = seg.text
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let r = timeline.first { $0.speaker == seg.speaker }
            return SpeakerSegment(speaker: seg.speaker, text: text,
                                  start: r?.start ?? seg.start, end: r?.end ?? seg.end)
        }
    }
}
