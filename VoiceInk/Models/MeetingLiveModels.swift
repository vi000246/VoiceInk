import Foundation
import SwiftData

/// meeting-copilot 的即時會議 session 與偵測到的 cue。
///
/// **兩個 model 都存於獨立的 `meeting.store`**(`cloudKitDatabase: .none`,只存本機)——
/// 本模組 schema 初期必然反覆調整,獨立 store 檔案不可能破壞 `default.store` 的
/// migration,崩壞時可整檔刪除重來。先例:`index.store`(見 AskAIModels.swift 檔頭)。
///
/// 三處註冊見 VoiceInk.swift(master Schema / createPersistentContainer /
/// createInMemoryContainer)——漏任一處 = launch `fatalError`。

/// cue 的四分類(FR-8)。String-in-raw 慣例:persist `kindRaw`,computed `kind` 包住它。
enum MeetingCueKind: String, Codable, CaseIterable {
    /// 直接問句:「你會怎麼設計一個短網址服務?」
    case directQuestion
    /// 陳述句形式的質疑——沒有問號但期待回應:「我對這個寫入效能有點擔心」(umbrella AC-4 的核心)
    case impliedChallenge
    /// 點名/指派:「這塊 Logan 你來說明一下」
    case assignedToMe
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

    /// 父端:cascade + inverse(鏡射 AskAIThread.messages,AskAIModels.swift:45-46)。
    /// **OPTIONAL 陣列、預設 []** ——兩者缺一不可。
    @Relationship(deleteRule: .cascade, inverse: \MeetingLiveCue.session)
    var cues: [MeetingLiveCue]? = []

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
    var fastModelName: String = ""
    var deepModelName: String = ""
    var answeredAt: Date?

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
}
