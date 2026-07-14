import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class MeetingCopilotControllerTests: XCTestCase {

    private let keys = [
        "meetingCopilotEnabledV1",
        "meetingCopilotShowInformationalCuesV1",
    ]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self, MeetingLiveSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// 只測展開狀態機時用:extractor 掛一個不會被呼叫的 fake(這條路徑不跑 cue 抽取,
    /// 也不讀 config —— `handleDeepCompleted`/`expand` 是純狀態轉移)。
    private func makeController() throws -> MeetingCopilotController {
        MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: FakeChatCompleting()),
            config: MeetingCopilotConfigStore(),
            modelContext: try makeContext())
    }

    /// AC-4:30 秒窗內兩句相似 committed → 只 persist 一則 cue。
    func testDedupesSimilarCuesWithinWindow() async throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(true)
        defer { config.setCopilotEnabled(false) }

        let fake = KeyedFakeChatCompleting(routes: [
            ("一個 rate limiter",
             #"{"cues":[{"text":"你會怎麼設計一個 rate limiter？","kind":"directQuestion"}]}"#),
            ("rate limiter",
             #"{"cues":[{"text":"你會怎麼設計 rate limiter？","kind":"directQuestion"}]}"#),
        ])
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: ctx)
        controller.beginSession(appName: "test")

        controller.handleRemoteCommitted("你會怎麼設計 rate limiter？")
        await controller.drainInflight()
        controller.handleRemoteCommitted("你會怎麼設計一個 rate limiter？")
        await controller.drainInflight()

        let persisted = try ctx.fetch(FetchDescriptor<MeetingLiveCue>())
        XCTAssertEqual(persisted.count, 1, "相似 cue 應被去重,只 persist 第一則")
        XCTAssertEqual(controller.cues.count, 1)
        XCTAssertEqual(fake.callCount, 2, "去重在 persist 層,抽取仍每 committed 一次")
    }

    /// AC-5:informational persist 但預設不暴露;打開開關後出現。
    func testInformationalPersistedButHiddenByDefault() async throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(true)
        defer { config.setCopilotEnabled(false) }
        XCTAssertFalse(config.showInformationalCues)

        let fake = FakeChatCompleting(
            reply: #"{"cues":[{"text":"我們上週上線了 v2","kind":"informational"}]}"#)
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: ctx)
        controller.beginSession(appName: "test")

        controller.handleRemoteCommitted("我們上週上線了 v2")
        await controller.drainInflight()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 1,
                       "informational 仍要 persist(事後可回顧)")
        XCTAssertTrue(controller.cues.isEmpty, "預設不納入 @Published 暴露面")

        config.setShowInformationalCues(true)
        controller.refreshPublishedCues()
        XCTAssertEqual(controller.cues.count, 1, "打開開關後即暴露")
    }

    /// AC-9:kill switch——extractor 未被呼叫、store 無新 cue、cues 為空。
    func testDisabledCopilotExtractsNothing() async throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(false)

        let fake = FakeChatCompleting(
            reply: #"{"cues":[{"text":"x?","kind":"directQuestion"}]}"#)
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: ctx)

        controller.beginSession(appName: "test")   // no-op
        controller.handleRemoteCommitted("你會怎麼設計 rate limiter？")
        await controller.drainInflight()

        XCTAssertEqual(fake.callCount, 0, "關閉時 ResponseCueExtractor 不得被呼叫")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSession>()).count, 0,
                       "關閉時連 session 都不建")
        XCTAssertTrue(controller.cues.isEmpty)
    }

    /// AC-35 / FR-51:deep 完成的自動展開只在「沒人在讀」時發生;有人在讀就只亮未讀標記。
    func testAutoExpandOnlyWhenNothingExpanded() throws {
        let c = try makeController()
        let a = UUID(), b = UUID()

        // 無展開 → 自動展開 a(沒人在讀,直接把分析推到眼前)
        c.handleDeepCompleted(cueId: a)
        XCTAssertEqual(c.expandedCueId, a)
        XCTAssertFalse(c.unreadDeepCueIds.contains(a), "已經展開給你看了,不該再標未讀")

        // a 展開中 → b 的分析完成:不搶展開,只進未讀
        c.handleDeepCompleted(cueId: b)
        XCTAssertEqual(c.expandedCueId, a, "使用者正在讀 a → 不得被 b 搶走")
        XCTAssertTrue(c.unreadDeepCueIds.contains(b))

        // 展開中那則自己的分析完成(手動點 a 之後其 Tier 2 回來)→ 不標未讀
        c.handleDeepCompleted(cueId: a)
        XCTAssertEqual(c.expandedCueId, a)
        XCTAssertFalse(c.unreadDeepCueIds.contains(a), "自己就是展開中那則,眼前就看得到")

        // 使用者點開 b(view 的點擊手勢走這條)→ 未讀清除
        c.expand(cueId: b)
        XCTAssertEqual(c.expandedCueId, b)
        XCTAssertFalse(c.unreadDeepCueIds.contains(b), "讀了就不再是未讀")
    }

    /// AC-36:展開 toggle 熱鍵的三條語意——收合 / 展開最新一則**有內容**的 cue / 無內容 no-op。
    /// 熱鍵端零邏輯(只呼叫 `toggleExpansion()`),所以「最新有內容者」的判斷在這裡驗。
    func testToggleExpansionSemantics() throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(true)
        defer { config.setCopilotEnabled(false) }

        let c = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: FakeChatCompleting()),
            config: config, modelContext: ctx)
        c.beginSession(appName: "test")

        let t0 = Date()

        // 只偵測到、tier 內容還沒回來的 cue:展開它等於展開一張空卡片 → 不算「有內容」
        let bare = addCue(c, ctx: ctx, text: "剛偵測到,還沒有任何 tier 內容", at: t0)
        c.toggleExpansion()
        XCTAssertNil(c.expandedCueId, "沒有任何有內容的 cue → no-op")

        // 較舊者只有開口稿、最新者只有深度分析 —— 兩者都算有內容,toggle 取最新
        let older = addCue(c, ctx: ctx, text: "舊題", at: t0.addingTimeInterval(1), opener: "嗨,我的看法是…")
        let newest = addCue(c, ctx: ctx, text: "新題", at: t0.addingTimeInterval(2), analysis: "深度分析內文")

        c.toggleExpansion()
        XCTAssertEqual(c.expandedCueId, newest, "無展開 → 展開最新一則有內容者")
        XCTAssertNotEqual(c.expandedCueId, bare, "沒有 tier 內容的 cue 不該被選中")

        c.toggleExpansion()
        XCTAssertNil(c.expandedCueId, "有展開者 → 收合")

        // 展開必須走 expand(cueId:) —— 否則未讀徽章清不掉,會永遠亮著
        c.expand(cueId: older)
        c.handleDeepCompleted(cueId: newest)                 // 在讀 older,newest 的分析只進未讀
        XCTAssertTrue(c.unreadDeepCueIds.contains(newest))
        c.toggleExpansion()                                  // 有展開者 → 先收合
        XCTAssertNil(c.expandedCueId)
        c.toggleExpansion()                                  // 再按 → 展開 newest
        XCTAssertEqual(c.expandedCueId, newest)
        XCTAssertFalse(c.unreadDeepCueIds.contains(newest), "toggle 展開要清未讀(走 expand(cueId:))")
    }

    /// 造一則掛在 session 底下的 cue 並同步到 `cues` 暴露面。回傳其 id。
    @discardableResult
    private func addCue(
        _ c: MeetingCopilotController, ctx: ModelContext, text: String, at: Date,
        opener: String = "", analysis: String = ""
    ) -> UUID {
        let cue = MeetingLiveCue(session: c.session, text: text, kind: .directQuestion, askedAt: at)
        cue.tier1Opener = opener
        cue.tier2Analysis = analysis
        ctx.insert(cue)
        try? ctx.save()
        c.refreshPublishedCues()
        return cue.id
    }
}
