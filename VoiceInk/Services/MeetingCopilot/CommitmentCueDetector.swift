import Foundation
import os

/// LLM 確認後的單筆承諾(尚未持久化的中間型別)。
struct CommitmentDetection: Equatable {
    /// 精簡的承諾內容(LLM 產出;純詞表模式 = committed 原文)。
    var title: String
    /// 口頭提到的期限**原文**(例「下週五之前」;沒提 = 空字串)。
    var dueHint: String = ""
    /// true = 純詞表記帳(`llmConfirmEnabled` 關閉),未經 LLM 確認。
    var unconfirmed: Bool = false
}

/// M15 承諾帳本的偵測器:從**我自己**(local 聲道)的 committed 逐字稿抓「口頭答應要做的事」。
///
/// 兩段式,鏡射 `ResponseCueExtractor` 的紀律:
/// 1. **純函式 pre-filter**(`candidates(in:)`):中英 commitment 詞表命中才進下一步——
///    沒中就**完全不呼叫 LLM**(local 聲道每段都跑 LLM 太貴;詞表 recall 導向,precision 交給 LLM)。
/// 2. **LLM 確認**(fast model、非串流一次呼叫):輸出 `{"is_commitment":bool,"title":…,"due_hint":…}`。
///    LLM 失敗/解析失敗/回 false → **保守丟棄**(寧漏勿誤——漏的還有 M12 會後包兜底,
///    誤記會讓帳本失去信任)。
final class CommitmentCueDetector {

    private let chat: ChatCompleting
    /// false = 純詞表記帳(不打 LLM),結果標 `unconfirmed`。
    private let llmConfirmEnabled: Bool
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    init(chat: ChatCompleting, llmConfirmEnabled: Bool = true) {
        self.chat = chat
        self.llmConfirmEnabled = llmConfirmEnabled
    }

    // MARK: - 詞表(具名常數;調校只動這裡,不動演算法)

    /// 中文承諾詞。ASR 逐字稿沒有空白斷詞,一律用**連續子字串**比對。
    static let zhCommitmentMarkers: [String] = [
        "我會", "我來", "我去", "我幫你", "我幫妳", "我幫忙", "我處理", "我先處理",
        "我查一下", "我查查", "我確認後", "我確認一下", "我再確認",
        "給你", "給妳", "寄給", "傳給", "發給", "回覆你", "回覆妳", "回你",
        "我負責", "交給我", "我試試", "我研究一下", "我弄好",
    ]

    /// 中文期限組合的**時間詞**:時間詞之後 4 字內出現「前」(之前/以前)即視為期限承諾候選
    /// (「明天之前」「下週五以前」)。
    static let zhDeadlineTimeWords: [String] = [
        "今天", "今晚", "明天", "後天", "這週", "這周", "本週", "本周",
        "下週", "下周", "週五", "周五", "月底",
    ]

    /// 中文否定/反問前綴:比對到的承諾詞,若**緊鄰的前綴**以這些結尾 → 排除該次命中
    /// (「我不會給你」「沒寄給他」)。「我不會」「我怎麼會」本身不含「我會」連續子字串,
    /// 天然不命中;這張表擋的是「不＋給你/寄給」這類詞表詞前面直接掛否定的情況。
    static let zhNegationPrefixes: [String] = [
        "不", "沒", "沒有", "別", "未", "不會", "不能", "無法", "不用",
        "怎麼", "怎會", "哪會", "難道",
    ]

    /// 中文反問尾:承諾詞所在子句(到下一個標點為止)以這些收尾 → 反問,排除(「我會嗎」)。
    static let zhRhetoricalSuffixes: [String] = ["嗎", "吗", "咧", "勒"]

    /// 英文承諾詞(比對前先 lowercased;含尾空白者要求後面還有字,避免句尾殘片)。
    static let enCommitmentMarkers: [String] = [
        "i'll ", "i will ", "i can send", "i can share", "i can take",
        "let me ", "i'm going to ", "i am going to ",
        "leave it to me", "i'll get back", "i'll follow up",
        "by tomorrow", "by today", "by tonight", "by friday", "by monday",
        "by next week", "by end of",
    ]

    /// 英文否定型:命中的承諾詞若落在這些片語的範圍內 → 排除
    /// (「I will not send」的 "i will " 命中會被 "i will not" 覆蓋掉)。
    static let enNegatedForms: [String] = [
        "i will not", "i will never", "i'll never", "won't",
        "i don't think i'll", "i'm not going to", "i am not going to",
        "i can't", "i cannot",
    ]

    /// 子句邊界(反問尾判定用)。
    private static let clauseBoundaries = CharacterSet(charactersIn: "。！？!?,，;；\n")

    // MARK: - Pre-filter(純函式)

    /// 命中的承諾詞(空 = 非候選,呼叫端不得打 LLM)。回傳命中詞是為了測試與 log 可讀,
    /// 呼叫端只需 `isEmpty` 判斷。
    static func candidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var hits: [String] = []

        // 中文詞表:逐一找出現位置,檢查否定前綴與反問尾。
        for marker in zhCommitmentMarkers {
            if hasValidZhOccurrence(of: marker, in: trimmed) { hits.append(marker) }
        }

        // 中文期限組合:「時間詞 … 前」在 4 字內。
        for timeWord in zhDeadlineTimeWords {
            if hasDeadlineCombo(timeWord: timeWord, in: trimmed) {
                hits.append("\(timeWord)…前")
            }
        }

        // 英文詞表:lowercase 比對 + 否定片語覆蓋排除。
        let lowered = trimmed.lowercased()
        let negatedRanges = enNegatedForms.flatMap { allRanges(of: $0, in: lowered) }
        for marker in enCommitmentMarkers {
            let ranges = allRanges(of: marker, in: lowered)
            let valid = ranges.contains { r in
                !negatedRanges.contains { $0.overlaps(r) }
            }
            if valid { hits.append(marker.trimmingCharacters(in: .whitespaces)) }
        }
        return hits
    }

    /// marker 在 text 中是否有**至少一次**未被否定前綴/反問尾排除的出現。
    private static func hasValidZhOccurrence(of marker: String, in text: String) -> Bool {
        for range in allRanges(of: marker, in: text) {
            // 否定前綴:取 marker 前最多 3 字,若以任一否定詞**結尾**則排除本次出現。
            let prefixStart = text.index(range.lowerBound, offsetBy: -3, limitedBy: text.startIndex) ?? text.startIndex
            let prefix = String(text[prefixStart..<range.lowerBound])
            if zhNegationPrefixes.contains(where: { prefix.hasSuffix($0) }) { continue }
            // 反問尾:marker 之後到子句結束,若以「嗎」等收尾則排除。
            var clauseEnd = range.upperBound
            while clauseEnd < text.endIndex,
                  !(text[clauseEnd].unicodeScalars.allSatisfy { clauseBoundaries.contains($0) }) {
                clauseEnd = text.index(after: clauseEnd)
            }
            let clauseTail = String(text[range.upperBound..<clauseEnd])
            if zhRhetoricalSuffixes.contains(where: { clauseTail.hasSuffix($0) }) { continue }
            return true
        }
        return false
    }

    /// 「時間詞之後 4 字內出現『前』」= 期限組合(「明天之前」「下週五以前」)。
    private static func hasDeadlineCombo(timeWord: String, in text: String) -> Bool {
        for range in allRanges(of: timeWord, in: text) {
            let windowEnd = text.index(range.upperBound, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex
            if text[range.upperBound..<windowEnd].contains("前") { return true }
        }
        return false
    }

    private static func allRanges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var search = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: search) {
            out.append(r)
            guard r.upperBound < haystack.endIndex else { break }
            search = r.upperBound..<haystack.endIndex
        }
        return out
    }

    // MARK: - Prompt(純函式)

    static let systemPrompt = """
    你是會議「口頭承諾」偵測器。輸入是**我自己**在會議中剛說的話(即時 ASR 逐字稿,可能有錯字,\
    請判斷語意而非字面)。判斷這段話是否包含「我答應要做某件事」的承諾\
    (例:「我會把報告寄給你」「我明天處理」「I'll send it by Friday」)。
    不算承諾的情況:單純描述現況或過去、轉述別人的話、假設/條件語氣(「如果需要的話我可以…」\
    還沒答應)、否定(「我不會…」)、反問(「我會嗎?」)、講客套話(「我幫你看看喔」後面明顯沒下文)。
    只輸出 JSON,不要任何其他文字、不要 markdown code fence,格式:
    {"is_commitment": true 或 false, "title": "<精簡的承諾內容,20 字內,動詞開頭,例「寄效能報告給 Alex」;非承諾給空字串>", \
    "due_hint": "<口頭提到的期限**原文**,例「下週五之前」;沒提到就給 null,不要編造>"}
    """

    /// 組 prompt。`previousLocal` = 前一段我說的話(僅供理解語意——「這個」「那份」指什麼)。
    static func buildPrompt(committed: String, previousLocal: String = "") -> (system: String, user: String) {
        var lines: [String] = []
        if !previousLocal.isEmpty {
            lines.append("我前一段說(僅供理解,不從這裡判斷):")
            lines.append(previousLocal)
            lines.append("")
        }
        lines.append("我剛說:")
        lines.append(committed)
        return (systemPrompt, lines.joined(separator: "\n"))
    }

    // MARK: - JSON 解析(純函式;任何失敗 → nil = 保守丟棄)

    private struct DTO: Decodable {
        let is_commitment: Bool?
        let title: String?
        let due_hint: String?
    }

    /// 解析 LLM 回覆。`is_commitment != true`、title 空、JSON 壞掉 → 一律 nil(寧漏勿誤)。
    static func parse(_ raw: String) -> CommitmentDetection? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 容錯:模型偶爾違反指示包 ```json fence(同 ResponseCueExtractor.parse)。
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = trimmed.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: data),
              dto.is_commitment == true else { return nil }
        let title = (dto.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return CommitmentDetection(
            title: title,
            dueHint: (dto.due_hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - 偵測(pre-filter → LLM 確認)

    /// nil = 非承諾(pre-filter 沒中、LLM 判 false、或 LLM 失敗的保守丟棄)。
    func detect(committed: String, previousLocal: String = "") async -> CommitmentDetection? {
        let hits = Self.candidates(in: committed)
        guard !hits.isEmpty else { return nil }

        guard llmConfirmEnabled else {
            // 純詞表模式:直接記 committed 原文,標 unconfirmed(帳本頁提示使用者自行過目)。
            return CommitmentDetection(
                title: committed.trimmingCharacters(in: .whitespacesAndNewlines),
                unconfirmed: true)
        }

        let (system, user) = Self.buildPrompt(committed: committed, previousLocal: previousLocal)
        do {
            let reply = try await chat.complete(system: system, user: user)
            guard let detection = Self.parse(reply) else {
                logger.notice("🤝 承諾候選被 LLM 否決或解析失敗,丟棄: \(committed.prefix(60), privacy: .public)")
                return nil
            }
            return detection
        } catch {
            // 保守丟棄:誤記傷帳本信任;漏的還有會後包兜底。但要留線索——最常見的失敗
            // 是 fast model 的 provider 沒接 API key(同 ResponseCueExtractor 的紀律)。
            logger.error("🤝 承諾確認 LLM 呼叫失敗,保守丟棄: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
