import Foundation

/// Outcome of routing a classification result: the chosen category + its bound prompt (if any).
struct RoutingDecision: Equatable {
    let category: RecorderCategory
    let prompt: CustomPrompt?
    let usedFallback: Bool
}

/// Maps a classification result → a `RecorderCategory` + its `CustomPrompt`.
/// `uncertain`, below-floor confidence, or an unresolvable id all route to the fallback category.
enum TemplateRouter {
    static func route(
        result: ClassificationResult,
        categories: [RecorderCategory],
        prompts: [CustomPrompt],
        confidenceFloor: Double
    ) -> RoutingDecision {
        let fallback = categories.first { $0.isFallback } ?? .makeFallback()

        guard let id = result.categoryId,
              result.confidence >= confidenceFloor,
              let category = categories.first(where: { $0.id == id }) else {
            return RoutingDecision(category: fallback,
                                   prompt: prompts.first { $0.id == fallback.customPromptId },
                                   usedFallback: true)
        }
        return RoutingDecision(category: category,
                               prompt: prompts.first { $0.id == category.customPromptId },
                               usedFallback: category.isFallback)
    }
}
