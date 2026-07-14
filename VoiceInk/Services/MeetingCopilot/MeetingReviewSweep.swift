import Foundation
import SwiftData
import os

/// 漏抓掃描(FR-57):「偵測器的偵測器」。
///
/// 用**無主題過濾**的通用 prompt 掃全逐字稿列出所有應回應項,與已偵測的 cues 做 bigram Jaccard
/// 匹配 —— 未匹配 = 漏抓候選。本身**不觸發 tier**(它產出的是調校訊號,不是給使用者的答案)。
///
/// # 為什麼要第二個掃描器
///
/// 漏抓(該回應卻沒偵測到)是分類 prompt 最嚴重的失效,卻**最難從資料裡看出來** —— session 裡
/// 只有「抓到的東西」,沒抓到的那些在資料上根本不存在。要發現它們,唯一的辦法是拿一把
/// **不同標準的尺**重掃一次全文,再和已抓到的比對差集。
///
/// # 為什麼是「無主題過濾」
///
/// 正式抽取的 prompt(`ResponseCueExtractor.systemPrompt`)帶主題過濾:非技術、非 aboutMe 的
/// 一律壓成 informational。掃描器若沿用同一套過濾,就只會回報「抽取已經抓到的東西」,差集恆為空
/// —— 掃了等於沒掃。所以這裡刻意放寬到「寧可多列」:多列的部分會被匹配掉,漏掉的部分才是純訊號。
///
/// 純函式 namespace + 一個 persist 用的 `run`,房子風格鏡射 `MeetingCueDeduplicator` / `Tier0Classifier`。
enum MeetingReviewSweep {

    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    // MARK: - Prompt(純函式)

    /// 通用掃描 prompt。**不得出現任何主題過濾字眼** —— 那正是它與正式抽取的唯一差異
    /// (`testSweepPromptIsGenericNoTopicFilter` 鎖住這件事)。
    /// JSON 契約與容錯慣例鏡射 `ResponseCueExtractor`(envelope + 不要 code fence + 失敗回空陣列)。
    static let systemPrompt = """
    你是會議覆盤的漏抓掃描器。輸入是一整場會議的逐字稿(可能有 ASR 錯字,請判斷語意而非字面)。
    請列出逐字稿中**所有**可能需要聽者回應的問題、點名、質疑 —— **不做任何主題過濾**,\
    寧可多列:這份清單是用來反查即時偵測漏掉了什麼,少列一則就等於漏掉一個調校訊號。
    注意:**不要只靠問號判斷** —— 質疑與指派常以陳述句出現。
    每一則給一個建議分類(僅供參考,不必嚴格):
    - directQuestion:直接問句
    - impliedChallenge:質疑或疑慮(常無問號,但明顯期待聽者回應)
    - assignedToMe:點名或指派聽者說明/負責某事
    - aboutMe:需要回憶聽者本人的經歷/貢獻/觀點才能答的(專案經歷、績效考核、行為面試)
    - informational:純資訊陳述、寒暄閒聊、公司流程行政事項
    沒有任何項目時回空陣列。
    只輸出 JSON,不要任何其他文字、不要 markdown code fence,格式:
    {"items":[{"text":"<原句>","suggestedKind":"directQuestion|impliedChallenge|assignedToMe|aboutMe|informational"}]}
    """

    /// 組 prompt。純函式:不讀 UserDefaults、不發網路、同輸入同輸出(鏡射 `ResponseCueExtractor.buildPrompt`)。
    static func buildPrompt(transcript: String) -> (system: String, user: String) {
        (systemPrompt, "會議逐字稿:\n\(transcript)")
    }

    // MARK: - JSON 契約

    private struct SweepEnvelope: Codable {
        let items: [RawItem]
    }
    private struct RawItem: Codable {
        let text: String
        /// optional:模型省略欄位時不可讓整包 decode 失敗(同 `ResponseCueExtractor.RawCue.searchHint`)。
        let suggestedKind: String?
    }

    /// 解析掃描回覆。任何失敗 → [](沿用 repo `try? JSONDecoder` 容錯慣例)。純函式。
    static func parse(_ raw: String) -> [SweepItem] {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 容錯:模型偶爾違反指示包 ```json fence——剝掉再解(同 `ResponseCueExtractor.parse`)。
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(SweepEnvelope.self, from: data) else { return [] }
        return envelope.items.compactMap { raw in
            let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SweepItem(text: text, suggestedKind: raw.suggestedKind ?? "")
        }
    }

    // MARK: - 匹配(純函式)

    /// 掃描項與已偵測 cue 的相似度 = **max(Jaccard, 包含度)**,共用
    /// `MeetingCueDeduplicator` 的正規化與 bigram(同一份逐字稿在兩處要用同一套斷詞標準)。
    ///
    /// # 為什麼不是純 Jaccard
    ///
    /// 這裡比的是**兩次獨立 LLM 呼叫對同一句話的改寫**,長度落差常常很大(掃描回「請自我介紹」、
    /// 即時抽到的是「先自我介紹一下你的經歷」)。Jaccard 的分母是聯集 —— 長句把聯集撐大,
    /// 短改寫再貼切也壓不過 0.6(上例 3/11 ≈ 0.27),於是「其實有抓到」的題目被**誤報成漏抓**。
    /// 漏抓清單裡混進假漏抓,比漏報還糟:調校時會照著一個虛高的漏抓率去鬆綁分類 prompt。
    ///
    /// 包含度(交集 / 較短一方的 bigram 數)正是「短改寫是否被長原句涵蓋」的問題,取兩者的 max
    /// 保留 Jaccard 對等長句的判斷力,同時吃得下長度落差。門檻仍沿用
    /// `MeetingCueDeduplicator.defaultThreshold`(0.6)—— 調校時只動那一個常數。
    static func similarity(_ a: String, _ b: String) -> Double {
        let ta = MeetingCueDeduplicator.tokens(MeetingCueDeduplicator.normalize(a))
        let tb = MeetingCueDeduplicator.tokens(MeetingCueDeduplicator.normalize(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let intersection = Double(ta.intersection(tb).count)
        let jaccard = intersection / Double(ta.union(tb).count)
        let containment = intersection / Double(min(ta.count, tb.count))
        return max(jaccard, containment)
    }

    /// 掃描結果 → 漏抓候選:與**任一**既有 cue 相似度 >= 門檻 → 視為已抓到(丟棄);其餘留下。
    /// 純函式(順序保留掃描器的輸出序 = 逐字稿順序)。
    ///
    /// 這裡**不做時間窗**(對比 `MeetingCueDeduplicator.isDuplicate`):掃描項只有文字、沒有時刻,
    /// 而且同一個問題在第 3 分鐘與第 40 分鐘各問一次時,live 只要抓到其中一次就不算漏抓。
    static func unmatched(sweep: [SweepItem], existingCueTexts: [String]) -> [SweepItem] {
        sweep.filter { item in
            !existingCueTexts.contains {
                similarity(item.text, $0) >= MeetingCueDeduplicator.defaultThreshold
            }
        }
    }

    // MARK: - JSON-in-raw(persist 到 session.reviewSweepRaw)

    /// → `reviewSweepRaw`。裸陣列,鏡射 `MeetingLiveCue.tier1Bullets` 的 JSON-in-raw 慣例。
    static func encode(_ items: [SweepItem]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// ← `reviewSweepRaw`。容錯回 [](舊資料/壞掉的 JSON 不該讓覆盤頁掛掉)。
    static func decode(_ raw: String) -> [SweepItem] {
        guard let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SweepItem].self, from: data)) ?? []
    }

    // MARK: - 執行(一次非串流呼叫,失敗靜默)

    /// 全逐字稿 → 一次掃描呼叫 → 與 session 已有的 cue 比對 → 未匹配項寫回 `reviewSweepRaw`。
    ///
    /// **失敗一律靜默**(不 throw、不清空既有):覆盤主體(cue／segment／Tier 1)在呼叫本函式前
    /// 就已經成立,掃描只是附加的調校訊號 —— 為了它把整場覆盤作廢是本末倒置。漏抓區空著即可。
    @MainActor
    static func run(session: MeetingLiveSession, transcript: String, chat: ChatCompleting) async {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }   // 沒有逐字稿可掃 → 不必燒一次呼叫

        let (system, user) = buildPrompt(transcript: text)
        let reply: String
        do {
            reply = try await chat.complete(system: system, user: user)
        } catch {
            logger.error("🧠 漏抓掃描 LLM 呼叫失敗:\(error.localizedDescription, privacy: .public) → 漏抓區留空")
            return
        }

        let items = parse(reply)
        // 解析出 0 則 **不等於** 零漏抓:呼叫成功但回了一坨壞 JSON 時,`parse` 的容錯同樣回 []
        // —— 兩者在這裡長得一模一樣。把「壞回覆」寫成「掃過了、零漏抓」是最糟的結果:覆盤頁會
        // 理直氣壯地顯示「沒有漏抓」,而使用者永遠不會發現掃描其實失敗了。寧可留空(= 尚未掃描,
        // UI 顯示補跑按鈕)。反之 items 非空、但全被匹配掉 → 寫 "[]",那才是真的零漏抓。
        guard !items.isEmpty else {
            logger.error("🧠 漏抓掃描解析不出項目(回覆長度 \(reply.count, privacy: .public))→ 漏抓區留空")
            return
        }

        let missed = unmatched(sweep: items, existingCueTexts: (session.cues ?? []).map(\.text))
        session.reviewSweepRaw = encode(missed)
        try? session.modelContext?.save()
        logger.notice("🧠 漏抓掃描 — 掃出 \(items.count, privacy: .public) 題,未被即時辨識 \(missed.count, privacy: .public) 題")
    }
}

/// 漏抓掃描的單則項目(persist 進 `MeetingLiveSession.reviewSweepRaw` 的 JSON 元素)。
///
/// **只存未匹配項**,所以不帶 `matched` 欄位 —— 它會恆為 false,是個看起來有意義、實際永遠不變的
/// 欄位,而「這一則沒被即時抓到」的語意由「它出現在這份清單裡」本身承載(FR-57 的匹配狀態隱含於此)。
///
/// `suggestedKind` 是掃描器的**建議**分類(裸 String,不轉 `MeetingCueKind`):掃描器沒有主題過濾,
/// 它給的分類與正式五分類不必然對得上,硬轉成 enum 只會在 decode 端把不認得的值整則丟掉 ——
/// 而「掃描器覺得這是 X,正式抽取卻連抓都沒抓到」正是要留下來看的調校線索。
struct SweepItem: Codable, Equatable {
    /// 掃描器認為需要回應的原句。
    let text: String
    /// 建議分類(directQuestion / impliedChallenge / assignedToMe / aboutMe / informational;可能為空)。
    let suggestedKind: String
}
