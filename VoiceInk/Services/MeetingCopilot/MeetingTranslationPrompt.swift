import Foundation

/// 即時字幕翻譯的 prompt(純函式:不讀 UserDefaults、不發網路、同輸入同輸出;
/// MIRROR `ResponseCueExtractor.buildPrompt` 的 prompt seam)。
///
/// **不做語言偵測**:LLM 天然處理混語——會議裡「這個 cache 的 latency 有點高」這種
/// 中英夾雜是常態,而任何語言偵測器都會在夾雜句上判錯,再把判錯的結果當成指令送給模型
/// (「輸入是英文」→ 模型把中文部分也當英文硬翻)。所以預設 `sourceLanguage = "auto"`,
/// 讓模型自己看;真要指定時才多給一行**提示**(不是斷言)。
enum MeetingTranslationPrompt {

    /// 語言碼 → 人類語言名。直接把碼塞進 prompt(「譯成 zh-TW」)時,模型偶爾會把語言碼
    /// 當成輸出格式指示;給人話比較穩。未知碼原樣返回(不猜、不崩)。
    static func displayName(for code: String) -> String {
        switch code {
        case "zh-TW": return "繁體中文"
        case "zh-CN": return "简体中文"
        case "en": return "English"
        case "ja": return "日本語"
        default: return code
        }
    }

    /// 組翻譯 prompt。system = 翻譯指示,user = 原文本身。
    ///
    /// - Parameters:
    ///   - text: 一段 committed 逐字稿原文。
    ///   - sourceLanguage: `"auto"`(或空字串)= 由模型自行判斷,混語會議的預設。
    ///     其他值僅作為提示,不改變「無論輸入語言都譯成目標語言」的主指示。
    ///   - targetLanguage: 目標語言碼(例 `"zh-TW"`),經 `displayName(for:)` 轉人話。
    static func build(
        text: String,
        sourceLanguage: String,
        targetLanguage: String
    ) -> (system: String, user: String) {
        let target = displayName(for: targetLanguage)
        var lines = [
            "你是會議即時字幕翻譯。**無論輸入**是什麼語言(可能中英夾雜),都譯成\(target)。",
            "輸入若已是\(target),**原樣輸出**(僅修正明顯的 ASR 錯字)。",
            "**只輸出**譯文本身——不要解釋、不要引號、不要標註語言。",
        ]
        // auto(含空字串的舊/壞設定)不加提示——寧可不給,也不要給「輸入主要為 」這種空指示。
        if sourceLanguage != "auto" && !sourceLanguage.isEmpty {
            lines.append("輸入主要為 \(sourceLanguage)。")
        }
        return (lines.joined(separator: "\n"), text)
    }
}
