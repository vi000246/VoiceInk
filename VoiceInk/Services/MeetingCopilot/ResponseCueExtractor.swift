import Foundation
import LLMkit
import os

/// fast model 從對方 committed 片段抽出的單則 cue(尚未持久化的中間型別)。
struct ExtractedCue: Codable, Equatable {
    let text: String
    let kind: MeetingCueKind
}

/// 一次抽取的完整結果:cues 之外還帶覆盤用的原始資料(回寫 `MeetingLiveSegment`)。
/// 「抽出 0 則」與「呼叫失敗」對使用者同樣靜默,但對調校是兩件事——這裡把它們分開。
struct CueExtractionOutcome: Equatable {
    var cues: [ExtractedCue] = []
    /// fast model 的原始回覆(解析失敗時的唯一線索;呼叫失敗時為空)。
    var rawReply: String = ""
    /// LLM 呼叫失敗原因(空 = 成功)。
    var errorDescription: String = ""
    var elapsedMs: Int = 0
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
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    init(chat: ChatCompleting) {
        self.chat = chat
    }

    // MARK: - Prompt(純函式,FR-12)

    /// 四分類定義 + JSON 契約。**不要只靠問號**是本模組的核心要求(umbrella AC-4)。
    ///
    /// 主題過濾(2026-07-13 依使用者要求):只有**技術/軟體工程相關**的問題才需要 AI 輔助
    /// 回答;非技術問題(期望待遇、個人資料、行為面試等)歸 `informational`——會持久化供
    /// 覆盤,但預設不上 overlay、不觸發三層回應(informational 本來就不觸發,見
    /// MeetingCopilotController.ingest)。
    static let systemPrompt = """
    你是會議即時輔助的 cue 偵測器。輸入是「對方剛說的話」的即時 ASR 逐字稿(可能有錯字,\
    請判斷語意而非字面)。從中抽出所有「需要我(聽者)回應的東西」,每一則分類為以下四類之一:
    - directQuestion:**技術/軟體工程相關**的直接問句(例:「你會怎麼設計一個短網址服務?」)
    - impliedChallenge:**技術面**的質疑或疑慮——沒有問號,但明顯期待我回應\
    (例:「我對這個寫入效能有點擔心」)
    - assignedToMe:點名或指派我說明/負責**技術上的**某事(例:「這塊 Logan 你來說明一下」)
    - informational:不需要 AI 輔助回答的一切——純資訊陳述(例:「我們上週上線了 v2」),\
    以及**所有非技術問題**:薪資/期望待遇、住址/個人資料、行為面試(自我介紹、優缺點、\
    團隊衝突經驗)、寒暄閒聊、公司流程行政事項。這些就算是問句、就算點名我,也一律歸此類。
    判斷基準:只有「需要軟體/系統/程式專業知識才能答好」的,才歸前三類。
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

    func extract(committed: String, recentContext: String = "") async -> CueExtractionOutcome {
        let (system, user) = Self.buildPrompt(committed: committed, recentContext: recentContext)
        let start = Date()
        do {
            let reply = try await chat.complete(system: system, user: user)
            return CueExtractionOutcome(
                cues: Self.parse(reply),
                rawReply: reply,
                elapsedMs: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            // 對使用者仍然靜默(不跳 UI),但要留診斷線索——最常見的失敗是
            // fast model 的 provider 沒接 API key,沒 log 根本查不到。
            logger.error("🥡 cue 抽取 LLM 呼叫失敗: \(error.localizedDescription, privacy: .public)")
            return CueExtractionOutcome(
                errorDescription: error.localizedDescription,
                elapsedMs: Int(Date().timeIntervalSince(start) * 1000))
        }
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
