import Foundation

/// 晨間簡報的顯示模型(純資料,由 `BriefingContent.buildModel` 組裝)。
struct MorningBriefingModel: Equatable {
    struct TaskRow: Equatable, Identifiable {
        let id: Int
        let title: String
        /// 副標(「3 天前到期」「今天 15:00 到期」);nil = 不顯示。
        let subtitle: String?
    }

    struct PackRow: Equatable, Identifiable {
        var id: String { fileName }
        let fileName: String
    }

    var overdue: [TaskRow] = []
    var dueToday: [TaskRow] = []
    /// 無期限待辦(已截斷至 `BriefingContent.noDueLimit`)。
    var noDue: [TaskRow] = []
    /// 無期限清單截斷後的剩餘筆數(「還有 N 筆」;0 = 沒截斷)。
    var noDueOverflow: Int = 0
    /// 任務區塊的狀態說明(「Vikunja 未連線」);nil = 任務資料正常。
    var vikunjaNote: String?
    var packs: [PackRow] = []
    /// 「今日第一件事」AI 建議;LLM 失敗/停用 → nil,整塊省略。
    var aiSuggestion: String?

    /// 「所有區塊皆空且無錯誤」= false → 今天不自動彈(有 note 也算有內容:
    /// 連線壞了本身就是使用者該知道的事)。
    var hasAnyContent: Bool {
        !overdue.isEmpty || !dueToday.isEmpty || !noDue.isEmpty || !packs.isEmpty
            || vikunjaNote != nil || aiSuggestion != nil
    }
}

/// 晨間簡報的內容組裝——全部純函式(任務分桶/排序/截斷、會後包檔名判定、AI prompt)。
enum BriefingContent {

    /// 無期限待辦最多列這麼多筆,其餘收進「還有 N 筆」——簡報要 30 秒掃完,不是完整清單。
    static let noDueLimit = 5

    // MARK: - due date 解析

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Vikunja 用 "0001-01-01…" 開頭的日期當「未設定」sentinel(慣例來自使用者的
    /// Python client)——以 "0001" 前綴判定,視同無期限。
    static func parseDueDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty, !raw.hasPrefix("0001") else { return nil }
        return isoFormatter.date(from: raw) ?? isoFractionalFormatter.date(from: raw)
    }

    // MARK: - 分桶

    struct Buckets: Equatable {
        var overdue: [VikunjaService.TaskItem] = []
        var dueToday: [VikunjaService.TaskItem] = []
        var noDue: [VikunjaService.TaskItem] = []
    }

    /// 逾期 = due < 今天 00:00(本地);今天 = due 落在今天(已過現在時刻也算);
    /// 未來(明天以後)不進晨間簡報;sentinel/無 due → 無期限。
    /// done 任務防禦性排除(API filter 已擋,但 filter 語法失效時不該把已完成當逾期羞辱人)。
    static func bucket(tasks: [VikunjaService.TaskItem], now: Date, calendar: Calendar = .current) -> Buckets {
        let startOfToday = calendar.startOfDay(for: now)
        var overdue: [(VikunjaService.TaskItem, Date)] = []
        var dueToday: [(VikunjaService.TaskItem, Date)] = []
        var result = Buckets()
        for task in tasks where !task.done {
            guard let due = parseDueDate(task.dueDateRaw) else {
                result.noDue.append(task)
                continue
            }
            if due < startOfToday {
                overdue.append((task, due))
            } else if calendar.isDate(due, inSameDayAs: now) {
                dueToday.append((task, due))
            }
        }
        // 逾期最久的排最前(那通常是最卡的一件);今天的按時刻先後。
        result.overdue = overdue.sorted { $0.1 < $1.1 }.map(\.0)
        result.dueToday = dueToday.sorted { $0.1 < $1.1 }.map(\.0)
        return result
    }

    /// 逾期天數(日曆日差,不是 86400 秒差——昨天 23:59 到期在今天 00:01 就算 1 天)。
    static func daysOverdue(due: Date, now: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: due)
        let to = calendar.startOfDay(for: now)
        return max(calendar.dateComponents([.day], from: from, to: to).day ?? 0, 0)
    }

    // MARK: - 顯示模型組裝

    /// `tasks` nil = 任務資料不可用(未設定/連線失敗),原因寫在 `vikunjaNote`。
    static func buildModel(
        tasks: [VikunjaService.TaskItem]?,
        vikunjaNote: String?,
        packFileNames: [String],
        aiSuggestion: String?,
        now: Date,
        calendar: Calendar = .current
    ) -> MorningBriefingModel {
        var model = MorningBriefingModel()
        model.vikunjaNote = vikunjaNote
        if let tasks {
            let buckets = bucket(tasks: tasks, now: now, calendar: calendar)
            model.overdue = buckets.overdue.map { task in
                let days = parseDueDate(task.dueDateRaw).map { daysOverdue(due: $0, now: now, calendar: calendar) } ?? 0
                // 文案中性:陳述事實(「3 天前到期」),不是指責(「你又逾期了」)。
                return MorningBriefingModel.TaskRow(
                    id: task.id, title: task.title,
                    subtitle: days <= 0 ? "已到期" : "\(days) 天前到期")
            }
            model.dueToday = buckets.dueToday.map { task in
                MorningBriefingModel.TaskRow(
                    id: task.id, title: task.title,
                    subtitle: parseDueDate(task.dueDateRaw).map { dueTimeSubtitle(for: $0, calendar: calendar) })
            }
            model.noDue = buckets.noDue.prefix(noDueLimit).map {
                MorningBriefingModel.TaskRow(id: $0.id, title: $0.title, subtitle: nil)
            }
            model.noDueOverflow = max(buckets.noDue.count - noDueLimit, 0)
        }
        // 檔名以 "yyyy-MM-dd HHmm" 開頭 → 降冪 = 最新的在最上面。
        model.packs = packFileNames.sorted(by: >).map { MorningBriefingModel.PackRow(fileName: $0) }
        model.aiSuggestion = aiSuggestion
        return model
    }

    /// 今天到期的副標:「今天 15:00 到期」;00:00(date-only 任務)只說「今天到期」。
    private static func dueTimeSubtitle(for due: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: due)
        let hour = c.hour ?? 0, minute = c.minute ?? 0
        if hour == 0 && minute == 0 { return "今天到期" }
        return String(format: "今天 %02d:%02d 到期", hour, minute)
    }

    // MARK: - 會後包檔名判定

    /// 昨天/今天的會後包:.md 且檔名以昨天或今天的 "yyyy-MM-dd" 開頭
    /// (檔名格式由 `VaultExportService.suggestedFileName` 固定產出)。
    static func isRecentPackFile(_ fileName: String, now: Date, calendar: Calendar = .current) -> Bool {
        guard fileName.hasSuffix(".md") else { return false }
        let today = BriefingScheduler.dayKey(for: now, calendar: calendar)
        guard let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now) else {
            return fileName.hasPrefix(today)
        }
        let yesterday = BriefingScheduler.dayKey(for: yesterdayDate, calendar: calendar)
        return fileName.hasPrefix(today) || fileName.hasPrefix(yesterday)
    }

    // MARK: - AI 建議(今日第一件事)

    static let aiSystemPrompt = """
    你是幫使用者決定「今天第一件事」的助理。使用者有 ADHD,起步最難——你的工作是替他做掉「選哪件」這個決定。
    從清單裡選一件最該先做的事(逾期且影響他人的優先,其次今天有明確時限的),\
    輸出格式:第一行是任務名原文,第二行是一句理由(50 字以內,語氣中性,不說教、不提醒他過去拖延)。
    只輸出這兩行,不要其他文字。
    """

    /// 餵給 LLM 的任務清單;三桶皆空 → nil(沒任務就沒有「第一件事」可選,整塊省略)。
    static func buildAIUserMessage(overdue: [String], dueToday: [String], noDue: [String]) -> String? {
        guard !(overdue.isEmpty && dueToday.isEmpty && noDue.isEmpty) else { return nil }
        var lines: [String] = ["今天日期已知,以下是目前的待辦清單:"]
        if !overdue.isEmpty {
            lines.append("【已逾期】")
            lines.append(contentsOf: overdue.map { "- \($0)" })
        }
        if !dueToday.isEmpty {
            lines.append("【今天到期】")
            lines.append(contentsOf: dueToday.map { "- \($0)" })
        }
        if !noDue.isEmpty {
            lines.append("【無期限】")
            lines.append(contentsOf: noDue.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}
