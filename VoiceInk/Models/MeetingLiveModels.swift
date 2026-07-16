import Foundation
import SwiftData

/// meeting-copilot 的即時會議 session、偵測到的 cue、與逐字稿 segment 時間軸。
///
/// **三個 model 都存於獨立的 `meeting.store`**(`cloudKitDatabase: .none`,只存本機)——
/// 本模組 schema 初期必然反覆調整,獨立 store 檔案不可能破壞 `default.store` 的
/// migration,崩壞時可整檔刪除重來。先例:`index.store`(見 AskAIModels.swift 檔頭)。
///
/// 三處註冊見 VoiceInk.swift(master Schema / createPersistentContainer /
/// createInMemoryContainer)——漏任一處 = launch `fatalError`。

/// cue 的五分類(FR-8;M8 FR-45 加入 aboutMe)。String-in-raw 慣例:persist `kindRaw`,
/// computed `kind` 包住它。
enum MeetingCueKind: String, Codable, CaseIterable {
    /// 直接問句:「你會怎麼設計一個短網址服務?」
    case directQuestion
    /// 陳述句形式的質疑——沒有問號但期待回應:「我對這個寫入效能有點擔心」(umbrella AC-4 的核心)
    case impliedChallenge
    /// 點名/指派:「這塊 Logan 你來說明一下」
    case assignedToMe
    /// 關於我本人——需回憶「我做過什麼/我的貢獻/我的觀點」才能答:「你對X專案有什麼貢獻?」
    /// 即使非技術也歸此類,走個人筆記 RAG 而非技術回答(M8 FR-45)。
    case aboutMe
    /// 純資訊,不需回應:「我們上週上線了 v2」(FR-11:persist 但預設不暴露)
    case informational
}

/// cue 的生命週期狀態。M2 只寫入 `.detected`;`.answered` 屬 M3。
enum MeetingCueStatus: String, Codable {
    case detected
    case answered
}

/// 一場即時會議 session(copilot 啟用時每次 attach 建立一筆)。
@Model
final class MeetingLiveSession {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    /// 會議 app 名稱(例:"zoom" / "teams";M2 由呼叫端傳入,可空)。
    var appName: String = ""
    /// 使用者的會議 brief(M3 接地用;M2 只宣告)。
    var brief: String = ""
    /// 對方/我的累積逐字稿快照(session 結束時回填;M2 只宣告)。
    var remoteTranscriptRaw: String = ""
    var localTranscriptRaw: String = ""
    /// 對應的錄音檔內容指紋(= `Transcription.importFingerprint`,會議停止匯入時回填)。
    /// 錄音管理詳情頁靠這個找到本 session 顯示「會議copilot覆盤」按鈕。空字串 = 未關聯。
    var importFingerprint: String = ""
    /// 本場的執行設定快照(JSON,`MeetingCopilotRunConfig`;attach 時寫入)。
    /// 調校迴圈的錨點:沒有它,事後無法知道「這批 cue/回應是在哪組模型、開關、prompt 下產生的」。
    /// 空字串 = 舊資料(欄位引入前)。
    var configSnapshotRaw: String = ""

    // MARK: - M8 欄位(有預設值 = lightweight migration 安全;無新 @Model → 不必動三處註冊)

    /// session 的來源:`"live"`(即時會議)或 `"replay"`(離線覆盤,從既有逐字稿重演)。
    /// String-in-raw 慣例。覆盤列表靠這個對 replay 顯示「離線覆盤」badge——兩者資料同構,
    /// 只有產生方式不同,所以用一個標記而不是第二個 @Model(FR-59)。
    /// 同一錄音可多次 replay(各帶當下 `configSnapshotRaw`)= prompt 調校的 A/B 基礎。
    var sourceRaw: String = "live"
    /// 漏抓掃描結果(JSON `[SweepItem]`,JSON-in-raw 慣例,同 cue 的 tier 陣列)。
    /// 「無主題過濾的通用 prompt 掃全文 → 與已偵測 cue 匹配 → 未匹配項」= 即時抽取漏掉的東西,
    /// 是分類 prompt 的調校訊號。空字串 = 尚未掃描(FR-57)。
    var reviewSweepRaw: String = ""

    /// 父端:cascade + inverse(鏡射 AskAIThread.messages,AskAIModels.swift:45-46)。
    /// **OPTIONAL 陣列、預設 []** ——兩者缺一不可。
    @Relationship(deleteRule: .cascade, inverse: \MeetingLiveCue.session)
    var cues: [MeetingLiveCue]? = []

    /// 逐字稿時間軸(每段 committed 一筆,含 remote 段的偵測 provenance)。同上的 cascade 語法。
    @Relationship(deleteRule: .cascade, inverse: \MeetingLiveSegment.session)
    var segments: [MeetingLiveSegment]? = []

    init(startedAt: Date = Date(), appName: String = "", brief: String = "") {
        self.id = UUID()
        self.startedAt = startedAt
        self.appName = appName
        self.brief = brief
    }
}

/// 一則偵測到的 cue(「需要我回應的東西」)。
@Model
final class MeetingLiveCue {
    var id: UUID = UUID()
    /// 子端:**裸的可選反向參照,無 @Relationship**(非對稱 cascade 語法,
    /// 鏡射 AskAIMessage.thread,AskAIModels.swift:518)。
    var session: MeetingLiveSession?
    /// cue 原句。
    var text: String = ""
    var kindRaw: String = MeetingCueKind.informational.rawValue
    var askedAt: Date = Date()
    /// 觸發這則 cue 的 committed 片段節錄(供 M3 帶上下文、M5 顯示)。
    var contextExcerpt: String = ""
    var statusRaw: String = MeetingCueStatus.detected.rawValue

    // MARK: - M3 欄位(M2 宣告不寫入;每欄有預設值 = lightweight migration 安全)

    var tier0Keywords: String = ""
    var tier1Opener: String = ""
    var tier1BulletsRaw: String = ""
    var tier2Analysis: String = ""
    var tier2FollowUpsRaw: String = ""
    var tier2UncertaintiesRaw: String = ""
    /// 實際使用的模型("provider/model";歷史資料可能是佔位字串 "fast"/"deep")。
    var fastModelName: String = ""
    var deepModelName: String = ""
    var answeredAt: Date?

    // MARK: - 觀測欄位(調校迴圈用;每欄有預設值 = lightweight migration 安全)
    //
    // 目的:讓每則 cue 事後可完整重建「怎麼被偵測到、AI 回應時看到了什麼上下文、
    // 花了多久、哪裡失敗」。即時路徑只寫入,不讀取。

    /// 觸發本 cue 的 `MeetingLiveSegment.id`(完整偵測上下文從那裡查)。nil = 舊資料。
    var sourceSegmentId: UUID?
    /// committed 到 cue persist 的耗時(含 fast model 抽取往返)。
    var detectionElapsedMs: Int = 0
    /// Tier 1 實際送出的完整 user prompt(接地內容都在裡面 —— 即「AI 看到的上下文範圍」)。
    var tier1PromptUser: String = ""
    /// Tier 1 的原始模型回覆(解析前;parser 出問題時的唯一線索)。
    var tier1RawReply: String = ""
    var tier1ElapsedMs: Int = 0
    var tier1At: Date?
    /// Tier 1 失敗原因(成功時清空;FR-28 的 log-only 降級從此有資料可查)。
    var tier1Error: String = ""
    /// Tier 1 接地降級備註(例:RAG embed 失敗原因;空 = 無異常)。
    var tier1GroundingNote: String = ""
    /// Tier 2 實際送出的完整 user prompt(含 Tier 1 草稿 + 接地 + 螢幕 OCR)。
    var tier2PromptUser: String = ""
    var tier2RawReply: String = ""
    var tier2GroundingElapsedMs: Int = 0
    var tier2StreamElapsedMs: Int = 0
    var tier2Error: String = ""
    var tier2GroundingNote: String = ""
    /// aboutMe cue 的檢索改寫詞(fast model 把問題改寫成筆記檢索詞;其他類為空)。
    /// 檢索路由拿它取代 cue 原句做 embed 查詢——原句常是口語問法,直接嵌入命中率差(M8 FR-45)。
    var searchHint: String = ""
    /// Tier 2 觸發來源:"auto" = 自動深答、"manual" = 使用者點擊、空 = 未跑(M8 觀測用)。
    var tier2TriggerRaw: String = ""

    // MARK: - M10 中度自評升級訊號(中度分析產出,供深度分析閘門)

    /// 中度分析自評「這題是否需要深度分析」(多方案取捨/多步推導/架構演算法/實質不確定)。
    /// 自動觸發模式據此決定是否自動發起 Tier 3。缺鍵預設 false。
    var mediumNeedsDeep: Bool = false
    /// 中度自評需要深答的簡短原因(顯示在「深入分析」鈕的 tooltip)。空 = 無/不需要。
    var mediumDeepReason: String = ""

    // MARK: - M10 深度分析(Tier 3,深思模型;鏡射 tier2 觀測欄位)
    //
    // 中度分析(tier2*)= 即時模型的自動續寫;深度分析(tier3*)= 深思模型的閘門化推理。
    // M8 的「慢層」機制(latest-only 取消/展開保護/未讀徽章/spinner)由 tier2 平移到 tier3。

    var tier3Analysis: String = ""
    var tier3FollowUpsRaw: String = ""
    var tier3UncertaintiesRaw: String = ""
    var tier3PromptUser: String = ""
    var tier3RawReply: String = ""
    var tier3GroundingElapsedMs: Int = 0
    var tier3StreamElapsedMs: Int = 0
    var tier3Error: String = ""
    var tier3GroundingNote: String = ""
    var tier3At: Date?
    /// Tier 3 觸發來源:"auto" = 中度放行自動深答、"manual" = 使用者按深入鈕、"image" = 截圖深答、空 = 未跑。
    var tier3TriggerRaw: String = ""
    /// 深度分析實際用的深思模型("provider/model")。
    var deepThinkModelName: String = ""

    init(
        session: MeetingLiveSession?,
        text: String,
        kind: MeetingCueKind,
        askedAt: Date = Date(),
        contextExcerpt: String = ""
    ) {
        self.id = UUID()
        self.session = session
        self.text = text
        self.kindRaw = kind.rawValue
        self.askedAt = askedAt
        self.contextExcerpt = contextExcerpt
    }

    // MARK: - 列舉存取器(String-in-raw,鏡射 AskAIMessage.role 的裸 String 模式)

    var kind: MeetingCueKind {
        get { MeetingCueKind(rawValue: kindRaw) ?? .informational }
        set { kindRaw = newValue.rawValue }
    }

    var status: MeetingCueStatus {
        get { MeetingCueStatus(rawValue: statusRaw) ?? .detected }
        set { statusRaw = newValue.rawValue }
    }

    // MARK: - tier 陣列存取器(JSON-in-raw + @Transient 快取,
    //          鏡射 Transcription.speakerSegments,Transcription.swift:73-92;
    //          raw 為非 optional String,get 端以 isEmpty 取代 nil 檢查)

    @Transient private var bulletsCacheRaw: String = ""
    @Transient private var bulletsCacheValue: [String] = []
    var tier1Bullets: [String] {
        get {
            guard !tier1BulletsRaw.isEmpty, let data = tier1BulletsRaw.data(using: .utf8) else { return [] }
            if bulletsCacheRaw == tier1BulletsRaw { return bulletsCacheValue }
            let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            bulletsCacheRaw = tier1BulletsRaw
            bulletsCacheValue = decoded
            return decoded
        }
        set {
            tier1BulletsRaw = newValue.isEmpty
                ? ""
                : ((try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            bulletsCacheRaw = tier1BulletsRaw
            bulletsCacheValue = newValue
        }
    }

    @Transient private var followUpsCacheRaw: String = ""
    @Transient private var followUpsCacheValue: [String] = []
    var tier2FollowUps: [String] {
        get {
            guard !tier2FollowUpsRaw.isEmpty, let data = tier2FollowUpsRaw.data(using: .utf8) else { return [] }
            if followUpsCacheRaw == tier2FollowUpsRaw { return followUpsCacheValue }
            let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            followUpsCacheRaw = tier2FollowUpsRaw
            followUpsCacheValue = decoded
            return decoded
        }
        set {
            tier2FollowUpsRaw = newValue.isEmpty
                ? ""
                : ((try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            followUpsCacheRaw = tier2FollowUpsRaw
            followUpsCacheValue = newValue
        }
    }

    @Transient private var uncertaintiesCacheRaw: String = ""
    @Transient private var uncertaintiesCacheValue: [String] = []
    var tier2Uncertainties: [String] {
        get {
            guard !tier2UncertaintiesRaw.isEmpty, let data = tier2UncertaintiesRaw.data(using: .utf8) else { return [] }
            if uncertaintiesCacheRaw == tier2UncertaintiesRaw { return uncertaintiesCacheValue }
            let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            uncertaintiesCacheRaw = tier2UncertaintiesRaw
            uncertaintiesCacheValue = decoded
            return decoded
        }
        set {
            tier2UncertaintiesRaw = newValue.isEmpty
                ? ""
                : ((try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            uncertaintiesCacheRaw = tier2UncertaintiesRaw
            uncertaintiesCacheValue = newValue
        }
    }

    // MARK: - M10 Tier 3 陣列存取器(JSON-in-raw + @Transient 快取,鏡射 tier2)

    @Transient private var t3FollowUpsCacheRaw: String = ""
    @Transient private var t3FollowUpsCacheValue: [String] = []
    var tier3FollowUps: [String] {
        get {
            guard !tier3FollowUpsRaw.isEmpty, let data = tier3FollowUpsRaw.data(using: .utf8) else { return [] }
            if t3FollowUpsCacheRaw == tier3FollowUpsRaw { return t3FollowUpsCacheValue }
            let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            t3FollowUpsCacheRaw = tier3FollowUpsRaw
            t3FollowUpsCacheValue = decoded
            return decoded
        }
        set {
            tier3FollowUpsRaw = newValue.isEmpty
                ? ""
                : ((try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            t3FollowUpsCacheRaw = tier3FollowUpsRaw
            t3FollowUpsCacheValue = newValue
        }
    }

    @Transient private var t3UncertaintiesCacheRaw: String = ""
    @Transient private var t3UncertaintiesCacheValue: [String] = []
    var tier3Uncertainties: [String] {
        get {
            guard !tier3UncertaintiesRaw.isEmpty, let data = tier3UncertaintiesRaw.data(using: .utf8) else { return [] }
            if t3UncertaintiesCacheRaw == tier3UncertaintiesRaw { return t3UncertaintiesCacheValue }
            let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            t3UncertaintiesCacheRaw = tier3UncertaintiesRaw
            t3UncertaintiesCacheValue = decoded
            return decoded
        }
        set {
            tier3UncertaintiesRaw = newValue.isEmpty
                ? ""
                : ((try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            t3UncertaintiesCacheRaw = tier3UncertaintiesRaw
            t3UncertaintiesCacheValue = newValue
        }
    }
}

/// segment 的來源聲道。String-in-raw 慣例同 `MeetingCueKind`。
enum MeetingSegmentChannel: String, Codable {
    /// 對方(process tap)——只有這條會跑 cue 抽取。
    case remote
    /// 我(mic)——純上下文,不抽 cue。
    case local
}

/// 一段 committed 逐字稿 + 它觸發的 cue 抽取結果(偵測 provenance)。
///
/// 這是調校迴圈的原始資料:漏抓(該回應卻沒偵測到)只能從「完整的 committed 時間軸
/// vs 已偵測 cue」對照出來;誤抓/錯分類要靠 `extractionReplyRaw` 還原 fast model
/// 當下的判斷。unified log 只保留數小時,persist 才能跨場次累積。
@Model
final class MeetingLiveSegment {
    var id: UUID = UUID()
    /// 子端:裸的可選反向參照(非對稱 cascade 語法,同 `MeetingLiveCue.session`)。
    var session: MeetingLiveSession?
    var channelRaw: String = MeetingSegmentChannel.remote.rawValue
    /// committed 原文(= 當下送進 cue 抽取的輸入)。
    var text: String = ""
    var committedAt: Date = Date()

    // MARK: - 偵測 provenance(remote 段才寫;local 段恆為預設值)

    /// 抽取時一併送入的滑動窗上下文(`ResponseCueExtractor.extract` 的 `recentContext`)。
    /// 目前實作恆為空 —— 照實記錄,窗口調校(spec Open Question)時改這裡就有 A/B 資料。
    var recentContext: String = ""
    /// 實際用的 fast model("provider/model")。
    var extractionModel: String = ""
    /// fast model 的原始回覆(JSON 或壞掉的字串;解析失敗時的唯一線索)。
    var extractionReplyRaw: String = ""
    var extractionElapsedMs: Int = 0
    /// 本段抽出的 cue 數。**-1 = 沒跑抽取**(local 段,或抽取尚未完成)。
    var extractedCount: Int = -1
    /// 抽出但被 FR-10 去重丟棄的數量(dedup 過猛/過鬆的調校訊號)。
    var dedupDroppedCount: Int = 0
    /// 抽取失敗原因(LLM 呼叫失敗;空 = 成功)。
    var extractionError: String = ""

    // MARK: - M8 即時翻譯(remote 段才寫;有預設值 = lightweight migration 安全,FR-64)

    /// 即時翻譯結果(空 = 未翻譯:翻譯關閉、local 段、或尚未完成)。
    /// 與原文一起 persist,覆盤詳情的逐段時間軸才能顯示雙語對照。
    var translatedText: String = ""
    /// 單段翻譯往返耗時(調校訊號:翻譯是否跟得上說話速度)。
    var translationElapsedMs: Int = 0
    /// 翻譯失敗原因(空 = 成功)。失敗對使用者靜默——該句 overlay 顯示原文,
    /// 只有這裡留得下線索(同 `extractionError` 的紀律)。
    var translationError: String = ""

    init(
        session: MeetingLiveSession?,
        channel: MeetingSegmentChannel,
        text: String,
        committedAt: Date = Date(),
        recentContext: String = ""
    ) {
        self.id = UUID()
        self.session = session
        self.channelRaw = channel.rawValue
        self.text = text
        self.committedAt = committedAt
        self.recentContext = recentContext
    }

    var channel: MeetingSegmentChannel {
        get { MeetingSegmentChannel(rawValue: channelRaw) ?? .remote }
        set { channelRaw = newValue.rawValue }
    }
}
