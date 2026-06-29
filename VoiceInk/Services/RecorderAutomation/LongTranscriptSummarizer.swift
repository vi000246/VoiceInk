import Foundation
import LLMkit
import os

/// Map-reduce summarization pre-pass for transcripts that exceed a token threshold, so a long
/// (e.g. 90-min seminar) transcript fits an enhancement call's context window.
@MainActor
final class LongTranscriptSummarizer {
    static let shared = LongTranscriptSummarizer()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() {}

    /// Above this estimated token count, condense before enhancing.
    let thresholdTokens = 6000
    /// Chunk size for the map step (chars). ~3000 tokens/chunk at the chars/4 heuristic.
    let maxCharsPerChunk = 12_000

    func needsSummarization(_ text: String) -> Bool {
        TokenEstimator.estimate(text) > thresholdTokens
    }

    /// Split text into chunks on paragraph/whitespace boundaries, each ≤ maxCharsPerChunk. Pure/testable.
    func chunks(_ text: String) -> [String] {
        guard text.count > maxCharsPerChunk else { return text.isEmpty ? [] : [text] }
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            // A single oversized paragraph is hard-split.
            if paragraph.count > maxCharsPerChunk {
                if !current.isEmpty { result.append(current); current = "" }
                var slice = paragraph[...]
                while slice.count > maxCharsPerChunk {
                    result.append(String(slice.prefix(maxCharsPerChunk)))
                    slice = slice.dropFirst(maxCharsPerChunk)
                }
                current = String(slice)
                continue
            }
            if current.count + paragraph.count + 1 > maxCharsPerChunk {
                result.append(current)
                current = paragraph
            } else {
                current = current.isEmpty ? paragraph : current + "\n" + paragraph
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Returns the text unchanged when below threshold; otherwise a map-reduce condensation.
    /// On any AI failure, falls back to the original text (enhancement may still truncate, but we never lose data).
    func condense(
        _ text: String,
        aiService: AIService,
        provider: AIProvider,
        modelName: String?
    ) async -> String {
        guard needsSummarization(text) else { return text }
        let parts = chunks(text)
        var summaries: [String] = []
        for (i, chunk) in parts.enumerated() {
            do {
                let s = try await aiService.completeChat(
                    provider: provider,
                    modelName: modelName,
                    messages: [ChatMessage.user(chunk)],
                    systemPrompt: "Summarize this transcript segment faithfully and concisely, preserving names, decisions, questions, and key facts. Output prose only.",
                    timeout: 60
                )
                summaries.append("[Segment \(i + 1)]\n\(s)")
            } catch {
                logger.error("Summarize segment \(i, privacy: .public) failed: \(error, privacy: .public)")
                summaries.append("[Segment \(i + 1)]\n\(String(chunk.prefix(2000)))")
            }
        }
        let joined = summaries.joined(separator: "\n\n")
        // Reduce step only if the joined map output is itself still large.
        guard needsSummarization(joined) else { return joined }
        do {
            return try await aiService.completeChat(
                provider: provider,
                modelName: modelName,
                messages: [ChatMessage.user(joined)],
                systemPrompt: "Combine these ordered segment summaries into one coherent, faithful summary. Output prose only.",
                timeout: 60
            )
        } catch {
            logger.error("Summarize reduce failed: \(error, privacy: .public)")
            return joined
        }
    }
}
