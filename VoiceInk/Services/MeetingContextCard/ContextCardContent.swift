import Foundation

// MARK: - 資料形狀

/// 檢索查詢：`query` 給向量檢索，`keywords` 給 Vikunja 任務標題的字面包含比對。
struct ContextCardQuery: Equatable {
    var query: String
    var keywords: [String]
}

/// 檢索塊的輕量投影——脈絡卡的純函式層不碰 SwiftData model（`EmbeddingChunk`），
/// 服務層在檢索後立刻映射成這個 struct，測試就不需要 model container。
struct ContextChunkInfo: Equatable {
    var text: String
    var sourceKind: String
    var sourceTitle: String?
    /// vault 相對路徑——只有 obsidian 塊會有（轉錄塊恆 nil，同 `EmbeddingChunk` 的反正規化規則）。
    var sourcePath: String?
}

/// 卡片內容（LLM 濃縮結果、退化卡或空卡共用同一形狀）。
struct MeetingContextCardModel: Equatable {
    struct NoteLink: Equatable, Identifiable {
        var id: String { path }
        var title: String
        var path: String
    }
    struct TaskLink: Equatable, Identifiable {
        var id: Int
        var title: String
    }

    var meetingTitle: String
    var lastSummary: [String] = []
    var openItems: [String] = []
    var myPromises: [String] = []
    /// 資料不足、看起來是第一次談這個主題（LLM 判定或空卡）。
    var firstMeeting: Bool = false
    /// LLM 失敗/解析失敗 → 退化卡：不顯示濃縮區塊，只列 RAG 來源清單（內容不憑空捏造）。
    var isFallback: Bool = false
    var noteLinks: [NoteLink] = []
    var tasks: [TaskLink] = []
    var generatedAt: Date = Date()
}

// MARK: - 純函式核心

/// M14 會議脈絡卡的純函式核心：query 建構、LLM prompt、JSON 解析、退化卡、任務關鍵詞匹配。
/// 不碰 CGWindowList / 網路 / SwiftData / 時鐘——測試全打這一層。
enum ContextCardContent {

    // MARK: - Query 建構（視窗標題 → 檢索查詢）

    /// 平台雜訊 token（lowercased 精確比對）。會議平台/瀏覽器產品名對「這場會在談什麼」
    /// 零資訊量，留著只會讓向量檢索被「Zoom」「Teams」這類詞拖走。
    /// 代價是標題裡真的叫這些名字的字也會被剝（例：開會討論「Chrome 擴充功能」），
    /// 接受——會議標題絕大多數情況下這些詞就是平台雜訊。
    static let noiseTokens: Set<String> = [
        "zoom", "zoom.us", "meeting", "meet", "google", "chrome",
        "microsoft", "teams", "webex", "cisco", "edge", "firefox", "mozilla",
        "safari", "brave", "vivaldi", "arc", "facetime", "slack", "discord", "huddle",
        "id", "call", "tab",
        "會議", "通話", "視訊", "分頁",
    ]

    /// 從視窗標題/會議 app 名建構檢索查詢。
    ///
    /// 步驟：剝 Google Meet 房間代碼（`abc-defg-hij`——必須在按 `-` 切段**之前**整顆剝掉，
    /// 否則切完的三段字母碎片會存活成假關鍵詞）→ 按分隔符與空白切 token →
    /// 剝平台雜訊 token、純數字/時間/ID 串、單字元 token → 去重保序。
    /// 剝完為空 → 退回 app 名（「Zoom Meeting」這種純平台標題就用「Zoom」查）。
    static func buildQuery(windowTitle: String?, appName: String) -> ContextCardQuery {
        let raw = (windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutRoomCode = raw.replacingOccurrences(
            of: #"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#, with: " ",
            options: [.regularExpression, .caseInsensitive])

        // 標題常見分隔符全部視為 token 邊界（含全形）。
        let separators = CharacterSet(charactersIn: "-|–—·:：,，()（）[]「」【】《》")
            .union(.whitespacesAndNewlines)
        var kept: [String] = []
        var seen = Set<String>()
        for piece in withoutRoomCode.components(separatedBy: separators) {
            let token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count >= 2 else { continue }   // 單字元（單一 CJK 字/字母）太泛
            let lower = token.lowercased()
            guard !noiseTokens.contains(lower) else { continue }
            // 純數字/日期/會議 ID 片段（分隔符已把 "10:30"、"2026-07-21" 切成純數字段）。
            guard token.range(of: #"^[0-9#/.]+$"#, options: .regularExpression) == nil else { continue }
            guard !seen.contains(lower) else { continue }
            seen.insert(lower)
            kept.append(token)
        }

        guard !kept.isEmpty else {
            let fallback = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            return ContextCardQuery(query: fallback, keywords: fallback.isEmpty ? [] : [fallback])
        }
        return ContextCardQuery(query: kept.joined(separator: " "),
                                keywords: Array(kept.prefix(6)))
    }

    // MARK: - LLM prompt

    static let systemPrompt = """
    你是會議前情提要整理器。使用者正要開始一場會議,下面提供「與這場會議可能相關的舊筆記/逐字稿片段」\
    與「可能相關的未結任務」。請整理成三組條列(繁體中文、每條一句、開會前 30 秒掃得完):
    - last_summary:上次與這個主題相關的討論重點(最多 3 條)
    - open_items:上次留下的行動項目/未結事項(最多 5 條)
    - my_promises:「我」答應過要做的事(最多 3 條)
    只根據提供的資料整理,絕不編造;某一組找不到就給空陣列。\
    資料整體太少、或看起來是第一次談這個主題時,把 first_meeting 設為 true。
    只輸出 JSON,不要 markdown、不要解釋:
    {"last_summary": [], "open_items": [], "my_promises": [], "first_meeting": false}
    """

    /// LLM user block：會議標題 + 編號片段（帶出處標題）+ 任務清單。純函式（供測試）。
    static func buildUserBlock(meetingTitle: String, chunks: [ContextChunkInfo],
                               taskTitles: [String]) -> String {
        var lines = ["會議標題:\(meetingTitle)"]
        if !chunks.isEmpty {
            lines.append("")
            lines.append("相關舊筆記/逐字稿片段:")
            for (i, chunk) in chunks.enumerated() {
                let origin = chunk.sourceTitle.map { "《\($0)》" } ?? ""
                lines.append("[\(i + 1)]\(origin) \(String(chunk.text.prefix(600)))")
            }
        }
        if !taskTitles.isEmpty {
            lines.append("")
            lines.append("可能相關的未結任務:")
            for title in taskTitles { lines.append("- \(title)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON 解析

    struct ParsedCard: Equatable {
        var lastSummary: [String]
        var openItems: [String]
        var myPromises: [String]
        var firstMeeting: Bool
    }

    /// 解析 LLM 輸出。code fence 剝除（沿用 `AskAIService.parseExpansions` 慣例）；
    /// 直接 decode 失敗再試「第一個 `{` 到最後一個 `}`」子字串（模型偶爾前後夾說明文字）。
    /// 全失敗 → nil（呼叫端退化卡）。
    static func parseCard(_ raw: String) -> ParsedCard? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = t.data(using: .utf8), let card = decodeCard(data) { return card }
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end,
              let data = String(t[start...end]).data(using: .utf8) else { return nil }
        return decodeCard(data)
    }

    private struct RawCard: Decodable {
        let last_summary: [String]?
        let open_items: [String]?
        let my_promises: [String]?
        let first_meeting: Bool?
    }

    private static func decodeCard(_ data: Data) -> ParsedCard? {
        guard let r = try? JSONDecoder().decode(RawCard.self, from: data) else { return nil }
        func clean(_ arr: [String]?, cap: Int) -> [String] {
            Array((arr ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(cap))
        }
        return ParsedCard(
            lastSummary: clean(r.last_summary, cap: 3),
            openItems: clean(r.open_items, cap: 5),
            myPromises: clean(r.my_promises, cap: 3),
            firstMeeting: r.first_meeting ?? false)
    }

    // MARK: - 相關筆記連結（正常卡與退化卡共用）

    /// 從檢索塊抽出可開啟的筆記連結：只有帶 `sourcePath` 的塊（= obsidian 筆記）能開
    /// `obsidian://`；轉錄塊（meeting）沒有檔案可開，略過。以 path 去重、保檢索排序
    ///（分數高的來源排前面）。標題缺失 → 檔名（去 .md）。
    static func noteLinks(from chunks: [ContextChunkInfo]) -> [MeetingContextCardModel.NoteLink] {
        var seen = Set<String>()
        var links: [MeetingContextCardModel.NoteLink] = []
        for chunk in chunks {
            guard let path = chunk.sourcePath, !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            let fallbackName = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".md", with: "")
            let title = (chunk.sourceTitle?.isEmpty == false) ? chunk.sourceTitle! : fallbackName
            links.append(MeetingContextCardModel.NoteLink(title: title, path: path))
        }
        return links
    }

    // MARK: - 任務關鍵詞匹配

    /// 本地字面比對：任一關鍵詞（大小寫不敏感）包含於任務標題 → 命中；保 API 回傳序、取前 limit。
    /// 空關鍵詞集 → 空結果（不整批放行）。已完成任務防禦性略過（listOpenTasks 理論上不會回）。
    static func matchTasks(_ tasks: [VikunjaService.TaskItem], keywords: [String],
                           limit: Int = 5) -> [VikunjaService.TaskItem] {
        let keys = keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !keys.isEmpty else { return [] }
        var matched: [VikunjaService.TaskItem] = []
        for task in tasks where !task.done {
            let title = task.title.lowercased()
            guard !title.isEmpty, keys.contains(where: { title.contains($0) }) else { continue }
            matched.append(task)
            if matched.count >= limit { break }
        }
        return matched
    }
}

// MARK: - 同場去重（純狀態機）

/// 兩個觸發入口（M11 偵測命中／手動開錄）共用一個 gate：先到者觸發，後到者在 cooldown 窗內
/// 被吃掉 = 同一場會只出一張卡。cooldown（10 分鐘）遠大於 M11 的全域冷卻（60s）——
/// 涵蓋「偵測到會議 → 過幾分鐘才真的按開始錄製」的常見時序。
struct ContextCardGate: Equatable {
    static let defaultCooldown: TimeInterval = 600

    private(set) var lastTriggerAt: Date?

    /// 回 true = 本次應觸發（並蓋章）；false = cooldown 窗內，去重吃掉。
    mutating func shouldTrigger(now: Date, cooldown: TimeInterval = ContextCardGate.defaultCooldown) -> Bool {
        if let last = lastTriggerAt, now.timeIntervalSince(last) < cooldown { return false }
        lastTriggerAt = now
        return true
    }

    mutating func reset() { lastTriggerAt = nil }
}
