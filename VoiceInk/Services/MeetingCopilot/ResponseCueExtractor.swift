import Foundation
import LLMkit

/// fast model 從對方 committed 片段抽出的單則 cue(尚未持久化的中間型別)。
struct ExtractedCue: Codable, Equatable {
    let text: String
    let kind: MeetingCueKind
}

/// 從「對方」的 committed 逐字稿抽出 response cue 並四分類(FR-8/FR-9)。
///
/// - **一次非串流呼叫**:輸出是結構化 JSON、使用者看不到中間產物,不需要逐 token 顯示,
///   所以走既有 `AIService.completeChat`,**不碰 SSE**(SSE 屬 M3;canon §3.3/§3.4)。
/// - **LLM seam**:重用 Ask AI 的 `ChatCompleting`(AskAIService.swift:6-8)——測試注入 fake。
/// - **靜默容錯**:LLM 失敗、JSON 解析失敗一律回 `[]`,不 throw、不跳 UI
///   (與 MeetingLiveTranscriber 的 ASR error 只記 log 同一紀律)。
final class ResponseCueExtractor {

    private let chat: ChatCompleting

    init(chat: ChatCompleting) {
        self.chat = chat
    }

    // MARK: - Prompt(純函式,FR-12)

    /// 四分類定義 + JSON 契約。**不要只靠問號**是本模組的核心要求(umbrella AC-4)。
    static let systemPrompt = """
    你是會議即時輔助的 cue 偵測器。輸入是「對方剛說的話」的即時 ASR 逐字稿(可能有錯字,\
    請判斷語意而非字面)。從中抽出所有「需要我(聽者)回應的東西」,每一則分類為以下四類之一:
    - directQuestion:直接問句(例:「你會怎麼設計一個短網址服務?」)
    - impliedChallenge:陳述句形式的質疑或疑慮——沒有問號,但明顯期待我回應\
    (例:「我對這個寫入效能有點擔心」)
    - assignedToMe:點名或指派我說明/負責某事(例:「這塊 Logan 你來說明一下」)
    - informational:純資訊陳述,不需要我回應(例:「我們上週上線了 v2」)
    注意:**不要只靠問號判斷**——質疑與指派常以陳述句出現,漏抓它們是最嚴重的錯誤。
    沒有任何 cue 時回空陣列。
    只輸出 JSON,不要任何其他文字、不要 markdown code fence,格式:
    {"cues":[{"text":"<cue 原句>","kind":"directQuestion|impliedChallenge|assignedToMe|informational"}]}
    """

    /// 組 prompt。純函式:不讀 UserDefaults、不發網路、同輸入同輸出(FR-12)。
    /// `recentContext` 是留給 M3 調校的滑動窗 seam,M2 預設空字串。
    static func buildPrompt(committed: String, recentContext: String = "") -> (system: String, user: String) {
        var lines: [String] = []
        if !recentContext.isEmpty {
            lines.append("先前上下文(僅供理解,不要從這裡抽 cue):")
            lines.append(recentContext)
            lines.append("")
        }
        lines.append("對方剛說:")
        lines.append(committed)
        return (systemPrompt, lines.joined(separator: "\n"))
    }

    // MARK: - JSON 契約(golden test 鎖定;M3 依賴)

    private struct CueEnvelope: Codable {
        let cues: [RawCue]
    }
    private struct RawCue: Codable {
        let text: String
        let kind: String
    }

    /// 解析 fast model 回的 JSON。任何失敗 → [](沿用 repo `try? JSONDecoder` 容錯慣例)。純函式。
    static func parse(_ raw: String) -> [ExtractedCue] {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 容錯:模型偶爾違反指示包 ```json fence——剝掉再解。
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(CueEnvelope.self, from: data) else { return [] }
        return envelope.cues.compactMap { raw in
            let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let kind = MeetingCueKind(rawValue: raw.kind) else { return nil }
            return ExtractedCue(text: text, kind: kind)
        }
    }

    // MARK: - 抽取(一次非串流呼叫,FR-8)

    func extract(committed: String, recentContext: String = "") async -> [ExtractedCue] {
        let (system, user) = Self.buildPrompt(committed: committed, recentContext: recentContext)
        guard let reply = try? await chat.complete(system: system, user: user) else { return [] }
        return Self.parse(reply)
    }
}

// MARK: - 正式 adapter(形狀照抄 AskAIView.LiveChatCompleter,AskAIView.swift:5-15)

/// 把 `ChatCompleting` 轉呼叫 `AIService.completeChat`(fast model,非串流)。
struct MeetingFastChatCompleter: ChatCompleting {
    let aiService: AIService
    let provider: AIProvider
    var modelName: String?

    func complete(system: String, user: String) async throws -> String {
        try await aiService.completeChat(
            provider: provider, modelName: modelName,
            messages: [ChatMessage.user(user)], systemPrompt: system, timeout: 30)
    }
}
