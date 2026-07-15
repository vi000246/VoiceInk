import Foundation
import LLMkit
import os

/// fast model 從對方 committed 片段抽出的單則 cue(尚未持久化的中間型別)。
struct ExtractedCue: Codable, Equatable {
    let text: String
    let kind: MeetingCueKind
    /// aboutMe 專用:fast model 把問題改寫成的筆記檢索詞(其他類為空;M8 FR-45)。
    var searchHint: String = ""
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

/// 從「對方」的 committed 逐字稿抽出 response cue 並五分類(FR-8/FR-9;M8 FR-45 加 aboutMe)。
///
/// - **一次非串流呼叫**:輸出是結構化 JSON、使用者看不到中間產物,不需要逐 token 顯示,
///   所以走既有 `AIService.completeChat`,**不碰 SSE**(SSE 屬 M3;canon §3.3/§3.4)。
/// - **LLM seam**:重用 Ask AI 的 `ChatCompleting`(AskAIService.swift:6-8)——測試注入 fake。
/// - **靜默容錯**:LLM 失敗、JSON 解析失敗一律回 `[]`,不 throw、不跳 UI
///   (與 MeetingLiveTranscriber 的 ASR error 只記 log 同一紀律)。
final class ResponseCueExtractor {

    private let chat: ChatCompleting
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")
    /// 實際送出的分類器 system prompt。使用者在設定頁覆寫時由 live controller 注入
    /// (`config.effectiveCuePrompt`);nil/空 → 內建 `systemPrompt`。
    private let effectiveSystemPrompt: String

    init(chat: ChatCompleting, systemPrompt: String? = nil) {
        self.chat = chat
        self.effectiveSystemPrompt = (systemPrompt?.isEmpty == false) ? systemPrompt! : Self.systemPrompt
    }

    // MARK: - Prompt(純函式,FR-12)

    /// 五分類定義 + JSON 契約。**不要只靠問號**是本模組的核心要求(umbrella AC-4)。
    ///
    /// 主題過濾(2026-07-13 依使用者要求)+ aboutMe 分流(M8 FR-45/46):技術問題歸前三類;
    /// 「關於我本人」的問題(專案經歷、績效考核、行為面試)歸 `aboutMe`——即使非技術也要
    /// 觸發回應,靠個人筆記 RAG 接地,並要求 fast model 順手給 `searchHint`(問題改寫成
    /// 筆記檢索詞);剩下真正不需要 AI 的(純資訊、純隱私資料、寒暄、行政)才歸
    /// `informational`——會持久化供覆盤,但預設不上 overlay、不觸發三層回應
    /// (見 MeetingCopilotController.ingest)。
    static let systemPrompt = """
    你是會議即時輔助的 cue 偵測器。輸入是「對方剛說的話」的即時 ASR 逐字稿(可能有錯字,\
    請判斷語意而非字面)。從中抽出所有「需要我(聽者)回應的東西」,每一則分類為以下五類之一:
    - directQuestion:**技術/軟體工程相關**的直接問句(例:「你會怎麼設計一個短網址服務?」)
    - impliedChallenge:**技術面**的質疑或疑慮——沒有問號,但明顯期待我回應\
    (例:「我對這個寫入效能有點擔心」)
    - assignedToMe:點名或指派我說明/負責**技術上的**某事(例:「這塊 Logan 你來說明一下」)
    - aboutMe:需要回憶**我做過什麼/我的貢獻/我的觀點**才能答的——問我的專案、我的經歷、\
    績效考核(例:「你對某專案有什麼**貢獻**?」「最有成就感的專案?」「你負責的範圍?」\
    「你從中學到什麼?」)、行為面試(**自我介紹**、優缺點、團隊衝突經驗)。\
    **即使非技術也歸此類**。
    - informational:不需要 AI 輔助回答的——純資訊陳述(例:「我們上週上線了 v2」)、\
    純隱私資料問題(薪資/期望待遇/住址)、寒暄閒聊、公司流程行政事項。
    判斷基準:「需要軟體/系統/程式專業知識才能答好」的歸前三類;「需要回憶我個人的經歷\
    /貢獻/觀點」的歸 aboutMe;兩者皆非才歸 informational。
    注意:**不要只靠問號判斷**——質疑與指派常以陳述句出現,漏抓它們是最嚴重的錯誤。
    輸入是**連續語音被即時切成的片段**,可能只是半句話的中段或結尾(例:「e conflict.」\
    「utes.」是新聞句被切碎的殘尾,不是問題)。若某段本身**不是語意完整、能獨立成立**的\
    問句/質疑/指派/關於我的問題,**不要硬湊成 cue**——寧可漏,不要把破碎的半句腦補成問題。
    沒有任何 cue 時回空陣列。
    只輸出 JSON,不要任何其他文字、不要 markdown code fence,格式:
    {"cues":[{"text":"<cue 原句>","kind":"directQuestion|impliedChallenge|assignedToMe|aboutMe|informational","searchHint":"<僅 aboutMe 給:把問題改寫成 2-4 個**同義/相關的筆記檢索詞**,用半形 | 分隔(涵蓋同義詞、上位詞、具體實例——例:團隊衝突→『團隊衝突|意見分歧|earn trust|跨團隊協作』);其他類給空字串>"}]}
    """

    // MARK: - 抽取前守門(2026-07-15 碎片誤判事故)

    /// 這段 committed 值不值得送 fast model 抽 cue。擋掉連續語音被切碎的「壞碎片」,
    /// 避免模型把半句話腦補成問題;**只擋結構上明顯不完整的**,多語安全。
    ///
    /// - 純標點/符號(切段接縫殘渣,如 `"..."`)→ 無語意,跳過。
    /// - **以小寫 ASCII 字母開頭** = 被切在英文詞/句中間的碎片(`"e conflict."`、`"utes."`)。
    ///   ElevenLabs Scribe V2 對句首一律大寫,完整英文 cue 不會小寫開頭;CJK 無大小寫,
    ///   不受影響(中文短句仍是合法 cue,不以長度硬擋)。代價:極少數以小寫品牌名
    ///   (`"iOS ..."`)開頭的真 cue 會被漏——由 recentContext + prompt + parse 三層補網。
    static func isExtractable(_ committed: String) -> Bool {
        let trimmed = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let hasLetterOrDigit = trimmed.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        guard hasLetterOrDigit else { return false }
        if let first = trimmed.unicodeScalars.first,
           first.isASCII, CharacterSet.lowercaseLetters.contains(first) {
            return false
        }
        return true
    }

    /// cue.text 是否**確實出自** committed(反腦補)+ 夠長。fast model 應回原句,故 cue 的
    /// bigram 應大部分被 committed 涵蓋;涵蓋度過低 = 模型自行虛構,丟棄。用 dedup 同一套
    /// 正規化/bigram,標準一致。
    static func isGrounded(_ cueText: String, in committed: String) -> Bool {
        let t = cueText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return false }
        let cueTokens = MeetingCueDeduplicator.tokens(MeetingCueDeduplicator.normalize(t))
        guard !cueTokens.isEmpty else { return false }
        let srcTokens = MeetingCueDeduplicator.tokens(MeetingCueDeduplicator.normalize(committed))
        let containment = Double(cueTokens.intersection(srcTokens).count) / Double(cueTokens.count)
        return containment >= 0.5
    }

    /// 組 prompt。純函式:不讀 UserDefaults、不發網路、同輸入同輸出(FR-12)。
    /// `recentContext` = 最近數段對方逐字稿(僅供理解語意,不從中抽 cue),讓模型判斷
    /// 當前片段是「新聞句的延續」還是「真的在問我」——M8 前恆空,碎片事故後接線。
    static func buildPrompt(committed: String, recentContext: String = "",
                            system: String = systemPrompt) -> (system: String, user: String) {
        var lines: [String] = []
        if !recentContext.isEmpty {
            lines.append("先前上下文(僅供理解,不要從這裡抽 cue):")
            lines.append(recentContext)
            lines.append("")
        }
        lines.append("對方剛說:")
        lines.append(committed)
        return (system, lines.joined(separator: "\n"))
    }

    // MARK: - JSON 契約(golden test 鎖定;M3 依賴)

    private struct CueEnvelope: Codable {
        let cues: [RawCue]
    }
    private struct RawCue: Codable {
        let text: String
        let kind: String
        /// optional:模型省略欄位(尤其非 aboutMe)時不可讓整包 decode 失敗。
        let searchHint: String?
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
            return ExtractedCue(text: text, kind: kind, searchHint: raw.searchHint ?? "")
        }
    }

    // MARK: - 抽取(一次非串流呼叫,FR-8)

    func extract(committed: String, recentContext: String = "") async -> CueExtractionOutcome {
        let (system, user) = Self.buildPrompt(committed: committed, recentContext: recentContext,
                                              system: effectiveSystemPrompt)
        let start = Date()
        do {
            let reply = try await chat.complete(system: system, user: user)
            // 反腦補守門:只留確實出自 committed 的 cue(rawReply 保留原樣供診斷比對)。
            let grounded = Self.parse(reply).filter { Self.isGrounded($0.text, in: committed) }
            return CueExtractionOutcome(
                cues: grounded,
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
