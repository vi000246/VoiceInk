import Foundation
import LLMkit
import os

/// Generates a category's classifier description from its bound analysis template via one AI call.
/// Lives OUTSIDE the view hierarchy so a generation keeps running — and its result still lands —
/// after the user closes the category editor or switches to another page mid-flight.
///
/// Delivery: the result is published in `pendingResults` for an open editor to consume into its
/// text field; if the category already exists in the store it is ALSO persisted directly, so a
/// background completion survives with no editor open. (An unsaved "add" draft has nothing to
/// persist into — its result is only delivered if the editor is still open.)
@MainActor
final class ClassifierDescriptionGenerator: ObservableObject {
    static let shared = ClassifierDescriptionGenerator()
    /// Category ids (draft id for a not-yet-saved category) with a generation in flight.
    @Published private(set) var inFlight: Set<UUID> = []
    /// Finished results waiting for an open editor to consume.
    @Published private(set) var pendingResults: [UUID: String] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() {}

    func isGenerating(_ id: UUID) -> Bool { inFlight.contains(id) }

    /// Editor pulls (and clears) a finished result for its category.
    func consumeResult(_ id: UUID) -> String? {
        defer { pendingResults[id] = nil }
        return pendingResults[id]
    }

    /// Generation model: dedicated classifier override → recorder default analysis model →
    /// first connected provider (mirrors RecorderPostProcessor's resolution).
    private func resolveModel(
        aiService: AIService, store: RecorderConfigStore
    ) -> (provider: AIProvider, modelName: String?)? {
        if let name = store.recorderClassifierProviderName, let p = AIProvider(rawValue: name),
           aiService.connectedProviders.contains(p) {
            return (p, store.recorderClassifierModelName)
        }
        if let name = store.defaultAIProviderName, let p = AIProvider(rawValue: name),
           aiService.connectedProviders.contains(p) {
            return (p, store.defaultAIModelName)
        }
        if let p = aiService.connectedProviders.first { return (p, nil) }
        return nil
    }

    func generate(
        categoryId: UUID, categoryName: String, prompt: CustomPrompt,
        aiService: AIService, store: RecorderConfigStore
    ) {
        guard !inFlight.contains(categoryId) else { return }
        guard let model = resolveModel(aiService: aiService, store: store) else {
            errors[categoryId] = "尚未連接任何 AI provider"
            return
        }
        errors[categoryId] = nil
        inFlight.insert(categoryId)
        Task { @MainActor in
            defer { inFlight.remove(categoryId) }
            let system = """
            你在為一個錄音自動分類系統撰寫「分類描述」。系統會把逐字稿連同各類別的分類描述交給分類器，判斷該錄音屬於哪一類。
            根據使用者提供的類別名稱與該類別的分析範本，寫出這個類別的分類描述：說明「什麼樣的錄音內容應該歸入此類別」。
            要求：一到兩句話，聚焦錄音內容的特徵（主題、場景、講者形式），不要複述範本的輸出格式要求。只輸出描述本身，不要任何前綴、引號或說明。
            """
            let user = """
            類別名稱：\(categoryName.isEmpty ? "（未命名）" : categoryName)
            分析範本標題：\(prompt.title)
            分析範本內容：
            \(String(prompt.promptText.prefix(3000)))
            """
            do {
                let raw = try await aiService.completeChat(
                    provider: model.provider, modelName: model.modelName,
                    messages: [ChatMessage.user(user)], systemPrompt: system, timeout: 60,
                    usageFeature: .recorderAutomation)
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else {
                    errors[categoryId] = "模型未回傳內容，請重試"
                    return
                }
                pendingResults[categoryId] = cleaned
                // Persist directly when the category exists so a background completion isn't lost.
                if var c = store.category(byId: categoryId) {
                    c.classifierDescription = cleaned
                    store.upsertCategory(c)
                    NotificationManager.shared.showNotification(
                        title: "已產生「\(c.name)」的分類描述", type: .success, duration: 4)
                }
            } catch {
                logger.error("Classifier description generation failed: \(error, privacy: .public)")
                errors[categoryId] = "產生失敗：\(error.localizedDescription)"
                NotificationManager.shared.showNotification(
                    title: "分類描述產生失敗", type: .warning, duration: 4)
            }
        }
    }
}
