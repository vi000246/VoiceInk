import Foundation

/// 會後包(M12)的純函式層:逐字稿組裝、prompt 建構、JSON 解析、markdown 組裝、Vikunja 映射。
/// 全部無副作用、可離線測試;編排(LLM 呼叫、vault 寫入、通知)在 `PostMeetingPackService`。

/// 逐字稿時間軸的一段(從 `MeetingLiveSegment` 映射來的值型別,讓組裝函式不依賴 SwiftData)。
struct MeetingPackSegment: Equatable {
    /// true = 我(mic);false = 對方(process tap)。
    var isLocal: Bool
    var text: String
    var committedAt: Date
}

/// 「我答應的」行動項目。
struct MeetingPackCommitment: Equatable {
    var title: String
    var dueDate: Date?
    var note: String
}

/// 對方的行動項目。
struct MeetingPackTheirAction: Equatable {
    var title: String
    var owner: String
    var note: String
}

/// LLM 抽出的完整會後包結構。
struct MeetingPackExtraction: Equatable {
    var shortTitle: String
    var topics: [String]
    var decisions: [String]
    var myCommitments: [MeetingPackCommitment]
    var theirActions: [MeetingPackTheirAction]
    var followups: [String]

    // MARK: - 逐字稿組裝(三層退階)

    /// 給 LLM 的逐字稿上限(約 24k 字元;超過走 `truncate` 截尾保留前後)。
    static let transcriptCharLimit = 24_000

    /// 三層退階:segments 時間軸(「我:」「對方:」按 committedAt 排序)→
    /// remote/local 累積快照 → Transcription 原始逐字稿。全空回空字串(呼叫端 guard)。
    static func assembleTranscript(
        segments: [MeetingPackSegment],
        remoteRaw: String,
        localRaw: String,
        transcriptionText: String
    ) -> String {
        let timeline = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.committedAt < $1.committedAt }
        if !timeline.isEmpty {
            return timeline
                .map { "\($0.isLocal ? "我" : "對方"):\($0.text)" }
                .joined(separator: "\n")
        }
        let remote = remoteRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = localRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty || !local.isEmpty {
            var parts: [String] = []
            if !remote.isEmpty { parts.append("對方(全程):\n\(remote)") }
            if !local.isEmpty { parts.append("我(全程):\n\(local)") }
            return parts.joined(separator: "\n\n")
        }
        return transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 過長截「中段」保留前後——會議的開場(議程)與收尾(結論/行動項)資訊密度最高。
    /// 回傳 `truncated` 供 prompt 註明「中段已省略」。
    static func truncate(_ text: String, limit: Int = transcriptCharLimit) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        let head = text.prefix(limit * 2 / 3)
        let tail = text.suffix(limit / 3)
        return ("\(head)\n\n……(中段省略)……\n\n\(tail)", true)
    }

    // MARK: - Prompt

    static let systemPrompt = """
    你是會後整理助手。根據會議逐字稿,整理出結構化的會後包。
    只輸出一個 JSON 物件,不要任何其他文字、解釋或 markdown 圍欄:
    {"short_title": "...", "topics": ["..."], "decisions": ["..."], \
    "my_commitments": [{"title": "...", "due_date": "..." 或 null, "note": "..."}], \
    "their_actions": [{"title": "...", "owner": "...", "note": "..."}], "followups": ["..."]}
    規則:
    - short_title:必填,12 字以內的會議主題摘要(當檔名用,不要標點)。
    - topics:本場討論的主題重點,每項一句話。
    - decisions:已經拍板的決定;沒有就給空陣列,不要把討論中的事當決定。
    - my_commitments:**「我」答應要做的事**(逐字稿中標記「我:」的發言人承諾的事項)。\
    due_date 用 RFC3339 含時區位移(例 "2026-07-20T09:00:00+08:00");「下週五前」等相對時間\
    以下方「現在時刻」換算;只講日期沒講時刻用當天 09:00;完全沒提時間就給 null,絕不編造。
    - their_actions:對方(其他與會者)要做的事;owner 填發言脈絡中的負責人,不確定就給空字串。
    - followups:沒有結論、需要後續追問或確認的事項。
    - 逐字稿若標明「(中段省略)」表示過長被截斷,僅就看得到的內容整理,不要臆測省略的部分。
    - 所有文字用繁體中文。
    """

    /// user message:會議メ他資料 + 現在時刻(due_date 換算基準,鏡射 Vikunja 捕捉)+ 逐字稿。
    /// `detectedCommitments` = 會中即時偵測到的承諾候選(M15;提升 my_commitments 召回率——
    /// 逐字稿被截尾時,即時記下的承諾仍在候選清單裡)。
    static func buildUserMessage(
        transcript: String,
        truncated: Bool,
        appName: String,
        startedAt: Date?,
        endedAt: Date?,
        brief: String,
        detectedCommitments: [String] = [],
        now: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
    ) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        lines.append("現在時刻:\(f.string(from: now))(時區 \(timeZone.identifier))")
        if !appName.isEmpty { lines.append("會議:\(appName)") }
        if let startedAt {
            let range = endedAt.map { "\(f.string(from: startedAt)) ~ \(f.string(from: $0))" }
                ?? f.string(from: startedAt)
            lines.append("時間:\(range)")
        }
        if !brief.isEmpty { lines.append("會前 brief:\(brief)") }
        if !detectedCommitments.isEmpty {
            lines.append("以下是會中即時偵測到的承諾候選(整理 my_commitments 時請與逐字稿合併、去重;候選可能有誤,與逐字稿矛盾時以逐字稿為準):")
            for c in detectedCommitments { lines.append("- \(c)") }
        }
        if truncated { lines.append("(逐字稿過長,中段已省略)") }
        lines.append("逐字稿:")
        lines.append(transcript)
        return lines.joined(separator: "\n")
    }

    // MARK: - Parse

    private struct CommitmentDTO: Decodable {
        var title: String?
        var due_date: String?
        var note: String?
    }
    private struct TheirActionDTO: Decodable {
        var title: String?
        var owner: String?
        var note: String?
    }
    private struct DTO: Decodable {
        var short_title: String?
        var topics: [String]?
        var decisions: [String]?
        var my_commitments: [CommitmentDTO]?
        var their_actions: [TheirActionDTO]?
        var followups: [String]?
    }

    /// 剝 ```json 圍欄後 JSONDecoder。解析失敗回 nil——呼叫端補一次重試再走 fallback
    /// (內容照樣落地,絕不因 LLM 失敗而不匯出)。due_date 解析與 "0001" sentinel
    /// 重用 `VikunjaCaptureExtraction.parseDueDate`。
    static func parse(_ raw: String) -> MeetingPackExtraction? {
        guard let data = VikunjaCaptureExtraction.extractJSONObject(from: raw)?.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else {
            return nil
        }
        func clean(_ items: [String]?) -> [String] {
            (items ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let commitments = (dto.my_commitments ?? []).compactMap { c -> MeetingPackCommitment? in
            let title = c.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return MeetingPackCommitment(
                title: title,
                dueDate: VikunjaCaptureExtraction.parseDueDate(c.due_date),
                note: c.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        let theirs = (dto.their_actions ?? []).compactMap { a -> MeetingPackTheirAction? in
            let title = a.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            return MeetingPackTheirAction(
                title: title,
                owner: a.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                note: a.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        return MeetingPackExtraction(
            shortTitle: dto.short_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            topics: clean(dto.topics),
            decisions: clean(dto.decisions),
            myCommitments: commitments,
            theirActions: theirs,
            followups: clean(dto.followups))
    }

    // MARK: - Markdown 組裝

    /// Dataview 行內欄位的 due 日期格式(`[due:: 2026-07-20]`;跟 vault 現有查詢對齊,日期粒度)。
    static func dataviewDueStamp(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 四段式 analysis markdown:## 主題重點 / ## 決定 / ## 行動項目 / ## 待追問。
    /// 空段整段省略。行動項目用 Dataview 行內欄位 `task:: title [due:: date]`,
    /// 現有 Dataview 查詢(`task` 欄位)直接查得到;note 縮排跟在項目下一行。
    static func buildAnalysisMarkdown(
        _ e: MeetingPackExtraction,
        timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
    ) -> String {
        var sections: [String] = []
        func bulletSection(_ heading: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            sections.append("## \(heading)\n\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        bulletSection("主題重點", e.topics)
        bulletSection("決定", e.decisions)

        if !e.myCommitments.isEmpty || !e.theirActions.isEmpty {
            var lines: [String] = ["## 行動項目"]
            if !e.myCommitments.isEmpty {
                lines.append("")
                lines.append("### 我答應的")
                lines.append("")
                for c in e.myCommitments {
                    var line = "- task:: \(c.title)"
                    if let due = c.dueDate { line += " [due:: \(dataviewDueStamp(due, timeZone: timeZone))]" }
                    lines.append(line)
                    if !c.note.isEmpty { lines.append("    - \(c.note)") }
                }
            }
            if !e.theirActions.isEmpty {
                lines.append("")
                lines.append("### 對方的")
                lines.append("")
                for a in e.theirActions {
                    var line = "- task:: \(a.title)"
                    if !a.owner.isEmpty { line += " [owner:: \(a.owner)]" }
                    lines.append(line)
                    if !a.note.isEmpty { lines.append("    - \(a.note)") }
                }
            }
            sections.append(lines.joined(separator: "\n"))
        }
        bulletSection("待追問", e.followups)
        return sections.joined(separator: "\n\n")
    }

    /// LLM 失敗(重試後仍失敗/回垃圾)時的 analysis:失敗註記。
    /// 原始逐字稿由 `buildMarkdown(includeRawTranscript: true)` 照常附在筆記底部——內容不因失敗而不落地。
    static func fallbackAnalysisMarkdown() -> String {
        "> ⚠️ 會後包 AI 生成失敗,本筆記僅含原始逐字稿(見下方)。可稍後在錄音管理對這筆錄音重新套用模板。"
    }

    // MARK: - Vikunja 映射(純函式)

    /// 建任務參數(與 `VikunjaService.createTask` 一一對應)。
    struct VikunjaDraft: Equatable {
        var title: String
        var description: String
        var dueDate: Date?
        var priority: Int
    }

    /// 「我答應的」→ Vikunja 任務草稿。due_date 原樣傳遞(nil 就不送,見 createTask 的 sentinel 註記);
    /// description = note + 來源筆記檔名(追溯用)。
    static func vikunjaDrafts(from commitments: [MeetingPackCommitment], noteFileName: String) -> [VikunjaDraft] {
        commitments.map { c in
            var desc = c.note
            if !noteFileName.isEmpty {
                desc += desc.isEmpty ? "來源:\(noteFileName)" : "\n\n來源:\(noteFileName)"
            }
            return VikunjaDraft(title: c.title, description: desc, dueDate: c.dueDate, priority: 0)
        }
    }

    /// 批次建立結果的通知文案。部分失敗據實回報,並指出失敗項仍在筆記裡(不遺失)。
    static func batchResultTitle(succeeded: Int, failed: Int) -> String {
        if failed == 0 { return "已加入 Vikunja:\(succeeded) 筆" }
        if succeeded == 0 { return "Vikunja 建立失敗(\(failed) 筆),項目仍完整保留在會後包筆記裡" }
        return "Vikunja 已建 \(succeeded) 筆、失敗 \(failed) 筆——失敗項仍在會後包筆記裡"
    }
}
