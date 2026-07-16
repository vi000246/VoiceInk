import Foundation
import SwiftData

/// 一次 AI 呼叫的 token 用量(LLM chat / 嵌入各一筆)。
///
/// **費用不落地**:dashboard 以「當前單價表 × 歷史 token」即時計算(`AIModelPricingStore`),
/// 單價修正後歷史費用自動跟著重算,不會留下用舊價算出的殭屍數字。
///
/// 住在 stats.store(與 SessionMetric 同店):純統計、可重建性質相同,不進備份/匯出。
@Model
final class AIUsageEvent {
    #Index<AIUsageEvent>([\.timestamp])

    var id: UUID = UUID()
    var timestamp: Date = Date()
    /// `AIProvider.rawValue`(例 "Gemini");嵌入走 `EmbeddingModel.providerName`("gemini"/"openai")。
    var provider: String = ""
    /// 實際請求的模型名(解析後實名,非「跟隨預設」的 nil)。
    var model: String = ""
    /// 功能標籤(`AIUsageFeature.rawValue`;穩定 ASCII key,顯示名由 UI 對映)。
    var feature: String = ""
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    /// true = 供應商沒回 usage,數字是字元啟發式估算(見 `TokenEstimator`)。
    var isEstimated: Bool = false

    init(
        timestamp: Date = Date(),
        provider: String,
        model: String,
        feature: String,
        inputTokens: Int,
        outputTokens: Int,
        isEstimated: Bool
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.feature = feature
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.isEstimated = isEstimated
    }
}
