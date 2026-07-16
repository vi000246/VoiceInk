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

    /// Chunk size for the map step (chars). ~3000 tokens/chunk at the chars/4 heuristic.
    let maxCharsPerChunk = 12_000

    /// Fraction of a model's context window we allow the input transcript to occupy before
    /// pre-summarizing. The remainder is headroom for the analysis system prompt and the
    /// generated output. Deliberately generous — we'd rather send the full transcript and let
    /// an oversized call surface a context-length error (raw transcript is still preserved and
    /// exported) than silently summarize away detail on recordings that would have fit.
    private let inputBudgetFraction = 0.7

    /// Best-effort context-window sizes (input tokens) per enhancement model. The app stores no
    /// such metadata, so this is a hand-maintained table keyed by provider and refined by model
    /// name. Unknown/local backends get a conservative value so we summarize rather than risk a
    /// context overflow. Update alongside `AIProvider.availableModels` when models change.
    static func contextWindowTokens(provider: AIProvider, modelName: String?) -> Int {
        let model = (modelName ?? provider.defaultModel).lowercased()
        switch provider {
        case .anthropic:
            return 200_000                                   // Claude 4.x: 200k window
        case .gemini:
            return 1_000_000                                 // Gemini 2.5/3.x: 1M window
        case .openAI:
            if model.hasPrefix("gpt-4.1") { return 1_000_000 }  // GPT-4.1 family: 1M
            return 256_000                                   // GPT-5.x: large but unpublished — stay safe
        case .mistral, .groq, .cerebras, .openRouter:
            return 128_000                                   // Llama/Qwen/GPT-OSS/Mistral-class: ~128k
        case .ollama:
            return 8_000                                     // local models default to a small num_ctx (4–8k)
        case .localCLI, .custom:
            return 128_000                                   // unknown backend — assume a modern mid-size window
        case .elevenLabs, .deepgram, .soniox, .speechmatics, .assemblyAI:
            return 32_000                                    // transcription-only; never reaches enhancement
        }
    }

    /// Estimated-token budget for the transcript we can send verbatim (no pre-summarization),
    /// derived from the resolved analysis model's real context window.
    func inputTokenBudget(provider: AIProvider, modelName: String?) -> Int {
        let context = Self.contextWindowTokens(provider: provider, modelName: modelName)
        return max(1, Int(Double(context) * inputBudgetFraction))
    }

    func needsSummarization(_ text: String, provider: AIProvider, modelName: String?) -> Bool {
        TokenEstimator.estimate(text) > inputTokenBudget(provider: provider, modelName: modelName)
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
        guard needsSummarization(text, provider: provider, modelName: modelName) else { return text }
        let parts = chunks(text)
        var summaries: [String] = []
        for (i, chunk) in parts.enumerated() {
            do {
                let s = try await aiService.completeChat(
                    provider: provider,
                    modelName: modelName,
                    messages: [ChatMessage.user(chunk)],
                    systemPrompt: "Summarize this transcript segment faithfully and concisely, preserving speaker attribution (who said what — keep the 講者N／speaker labels or names), names, decisions, questions, and key facts. Output prose only.",
                    timeout: 60,
                    usageFeature: .recorderAutomation
                )
                summaries.append("[Segment \(i + 1)]\n\(s)")
            } catch {
                logger.error("Summarize segment \(i, privacy: .public) failed: \(error, privacy: .public)")
                summaries.append("[Segment \(i + 1)]\n\(String(chunk.prefix(2000)))")
            }
        }
        let joined = summaries.joined(separator: "\n\n")
        // Reduce step only if the joined map output is itself still large.
        guard needsSummarization(joined, provider: provider, modelName: modelName) else { return joined }
        do {
            return try await aiService.completeChat(
                provider: provider,
                modelName: modelName,
                messages: [ChatMessage.user(joined)],
                systemPrompt: "Combine these ordered segment summaries into one coherent, faithful summary, keeping speaker attribution (who said what) wherever the segments carry it. Output prose only.",
                timeout: 60,
                usageFeature: .recorderAutomation
            )
        } catch {
            logger.error("Summarize reduce failed: \(error, privacy: .public)")
            return joined
        }
    }
}
