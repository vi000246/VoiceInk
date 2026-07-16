import Foundation
import SwiftData
import LLMkit
import os

/// AI 呼叫的功能標籤。rawValue 是穩定儲存 key(落地進 `AIUsageEvent.feature`),
/// 顯示名走 `displayName`——之後改顯示文字不會讓歷史資料變孤兒。
enum AIUsageFeature: String, CaseIterable {
    case enhancement = "enhancement"
    case askAI = "askai"
    case assistant = "assistant"
    /// 會議 cue 偵測(fast model 分類器;live 與離線覆盤共用)。
    case meetingCue = "meeting-cue"
    /// 會議即答/深答(tier1 + tier2 串流;live 與離線覆盤共用)。
    case meetingAnswer = "meeting-answer"
    case meetingTranslation = "meeting-translation"
    case recorderAutomation = "recorder-automation"
    case embedding = "embedding"
    case other = "other"

    var displayName: String {
        switch self {
        case .enhancement: return "聽寫增強"
        case .askAI: return "Ask AI"
        case .assistant: return "語音助理"
        case .meetingCue: return "會議 cue 偵測"
        case .meetingAnswer: return "會議即答/深答"
        case .meetingTranslation: return "會議即時翻譯"
        case .recorderAutomation: return "錄音自動化"
        case .embedding: return "語意索引（嵌入）"
        case .other: return "其他"
        }
    }

    /// 歷史資料的 raw 值 → 顯示名(未知 key 原樣顯示,不吞資料)。
    static func displayName(forRaw raw: String) -> String {
        AIUsageFeature(rawValue: raw)?.displayName ?? raw
    }
}

/// 一次呼叫的 token 數(供應商回報,或估算)。
struct ChatUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var isEstimated: Bool = false
}

/// 用量估算的輸入側便捷函式 —— 供應商沒回 usage 時的退路(事件標 `isEstimated`)。
/// 字元啟發式本體重用 RecorderAutomation 的 `TokenEstimator`(CJK ≈ 1 字/token、其他 ≈ 4 字/token)。
extension TokenEstimator {
    /// chat 請求輸入側的估算:system + 各訊息(+4 tokens/則的角色框架 overhead)
    /// + 圖片每張以 ~1100 tokens 粗估(各家 vision 計價差異大,只求量級)。
    static func estimateInput(system: String?, messages: [ChatMessage], imageCount: Int = 0) -> Int {
        var total = 0
        if let system, !system.isEmpty {
            total += estimate(system)
        }
        for message in messages {
            total += estimate(message.content) + 4
        }
        return total + imageCount * 1100
    }
}

/// AI 用量記錄器。app 啟動時 `configure` 注入 mainContext;`record` 可從任意執行緒呼叫
/// (內部 hop 到 MainActor 寫入)。未 configure 時靜默丟棄(單元測試/預覽情境)。
@MainActor
final class AIUsageRecorder {
    static let shared = AIUsageRecorder()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AIUsage")
    private var modelContext: ModelContext?

    private init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// 落一筆用量事件。0 tokens(空回應且無輸入)不落,避免噪音。
    nonisolated func record(provider: String, model: String, feature: AIUsageFeature, usage: ChatUsage) {
        guard usage.inputTokens > 0 || usage.outputTokens > 0 else { return }
        Task { @MainActor in
            guard let context = self.modelContext else { return }
            context.insert(AIUsageEvent(
                provider: provider,
                model: model,
                feature: feature.rawValue,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                isEstimated: usage.isEstimated))
            do {
                try context.save()
            } catch {
                self.logger.error("AIUsage save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// chat 呼叫的便捷入口:優先用供應商回報的 usage;沒有就以請求/回應內容估算並標 isEstimated。
    nonisolated func recordChat(
        provider: AIProvider,
        model: String,
        feature: AIUsageFeature,
        systemPrompt: String?,
        messages: [ChatMessage],
        imageCount: Int = 0,
        responseText: String,
        reported: ChatUsage?
    ) {
        let usage = reported ?? ChatUsage(
            inputTokens: TokenEstimator.estimateInput(
                system: systemPrompt, messages: messages, imageCount: imageCount),
            outputTokens: TokenEstimator.estimate(responseText),
            isEstimated: true)
        record(provider: provider.rawValue, model: model, feature: feature, usage: usage)
    }
}
