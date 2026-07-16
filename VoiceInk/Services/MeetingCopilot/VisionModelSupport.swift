import Foundation

/// 判斷深答模型是否支援圖片輸入(多模態)。
///
/// # 為什麼是名稱啟發式
/// 沒有官方 API 可查「這顆模型吃不吃圖」。VoiceInk 又允許自訂 base URL / 任意模型名,不可能維護
/// 一份窮盡清單。這裡的策略是**保守放行**:命中已知視覺家族才放行,其餘擋下並提示換模型
/// (使用者明確要求「不支援時給清楚訊息」)。
///
/// 誤判的兩種後果都收得住:
/// - 偽陰性(其實支援卻被擋):使用者看到提示、到設定換一顆更主流的視覺模型即可,不會靜默壞掉。
/// - 偽陽性(不支援卻放行):圖片送出後 API 會報錯,落到 Tier 2 的 catch → 降級 + 錯誤訊息浮到
///   overlay(見 `AnswerCoordinator.requestDeepWithImages`),同樣有清楚回饋。
enum VisionModelSupport {

    /// 已知支援視覺的模型家族標記(小寫子字串比對)。
    private static let visionMarkers: [String] = [
        // OpenAI —— gpt-5 子字串涵蓋 app 內建的 gpt-5 / gpt-5.4* / gpt-5.5(含預設 model),
        // 這些皆為多模態;缺了它,OpenAI 預設配置的截圖深答會被誤擋(M10 FR-83 修正)。
        "gpt-5", "gpt-4o", "gpt-4.1", "gpt-4-turbo", "gpt-4-vision", "chatgpt-4o",
        "o1", "o3", "o4-mini", "o4",
        // Anthropic(Claude 3 起全系列吃圖)
        "claude-3", "claude-sonnet-4", "claude-opus-4", "claude-haiku-4", "claude-4",
        // Google
        "gemini",
        // xAI
        "grok-2-vision", "grok-3", "grok-4",
        // 開源多模態
        "llava", "qwen-vl", "qwen2-vl", "qwen2.5-vl", "pixtral", "llama-3.2", "llama-4",
        "internvl", "minicpm-v", "phi-3.5-vision", "phi-4",
    ]

    /// - Parameter label: `"provider/model"`(`AnswerCoordinator.deepLabel` 格式)或裸 model 名。
    static func isVisionCapable(label: String) -> Bool {
        let m = label.lowercased()
        return visionMarkers.contains { m.contains($0) }
    }
}
