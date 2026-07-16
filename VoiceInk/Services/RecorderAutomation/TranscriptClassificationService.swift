import Foundation
import LLMkit
import os

/// Result of classifying a transcript: a resolved category id (nil = uncertain) + 0–1 confidence.
struct ClassificationResult: Equatable {
    let categoryId: UUID?
    let confidence: Double
    static let uncertain = ClassificationResult(categoryId: nil, confidence: 0)
}

/// One lightweight cloud-AI call mapping a raw transcript → a category id or `uncertain` + confidence.
/// Prompt building and response parsing are pure/testable; the network call is thin.
@MainActor
final class TranscriptClassificationService {
    static let shared = TranscriptClassificationService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() {}

    /// Cap the transcript sent to the classifier — head excerpt is enough to classify and bounds cost.
    static let excerptCharLimit = 4000

    func representativeExcerpt(_ text: String) -> String {
        guard text.count > Self.excerptCharLimit else { return text }
        return String(text.prefix(Self.excerptCharLimit))
    }

    func buildSystemPrompt(categories: [RecorderCategory]) -> String {
        let lines = categories.map { c in
            "- id: \(c.id.uuidString) | name: \(c.name) | whenToUse: \(c.classifierDescription)"
        }.joined(separator: "\n")
        return """
        You classify a transcript into exactly one category, or 'uncertain'.
        Categories:
        \(lines)

        Respond with ONLY a JSON object, no prose:
        {"categoryId": "<one of the ids above, or the literal string uncertain>", "confidence": <number 0.0-1.0>}
        """
    }

    /// Parse the model's JSON. Unknown / unparseable / "uncertain" → `.uncertain`.
    /// A returned id is only accepted if it matches a known category.
    func parse(_ raw: String, categories: [RecorderCategory]) -> ClassificationResult {
        guard let jsonRange = raw.range(of: #"\{[^}]*\}"#, options: .regularExpression),
              let data = String(raw[jsonRange]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .uncertain
        }
        let confidence = (obj["confidence"] as? Double)
            ?? Double((obj["confidence"] as? NSNumber)?.stringValue ?? "") ?? 0
        guard let idString = obj["categoryId"] as? String,
              idString.lowercased() != "uncertain",
              let uuid = UUID(uuidString: idString),
              categories.contains(where: { $0.id == uuid }) else {
            return ClassificationResult(categoryId: nil, confidence: confidence)
        }
        return ClassificationResult(categoryId: uuid, confidence: confidence)
    }

    func classify(
        _ text: String,
        categories: [RecorderCategory],
        aiService: AIService,
        provider: AIProvider,
        modelName: String?
    ) async -> ClassificationResult {
        guard !categories.isEmpty else { return .uncertain }
        let system = buildSystemPrompt(categories: categories)
        let user = representativeExcerpt(text)
        do {
            let raw = try await aiService.completeChat(
                provider: provider,
                modelName: modelName,
                messages: [ChatMessage.user(user)],
                systemPrompt: system,
                timeout: 30,
                usageFeature: .recorderAutomation
            )
            return parse(raw, categories: categories)
        } catch {
            logger.error("Classification failed: \(error, privacy: .public)")
            return .uncertain
        }
    }
}
