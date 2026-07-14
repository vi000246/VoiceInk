import XCTest
import SwiftData
@testable import VoiceInk

/// 接地 noop（回空，不碰網路/索引/螢幕）。
private struct NoopGrounding: MeetingGroundingProviding {
    func gather(query: String, brief: String, includeRAG: Bool, includeScreen: Bool,
                sources: Set<String>?) async -> MeetingGrounding {
        .empty
    }
}

/// 記錄 gather 收到的參數（AC-32 檢索路由斷言用），回空接地。形狀鏡射 GroundingTests.FakeScreen。
private final class SpyGrounding: MeetingGroundingProviding {
    private(set) var lastQuery = ""
    private(set) var lastIncludeRAG = false
    private(set) var lastSources: Set<String>?
    func gather(query: String, brief: String, includeRAG: Bool, includeScreen: Bool,
                sources: Set<String>?) async -> MeetingGrounding {
        lastQuery = query
        lastIncludeRAG = includeRAG
        lastSources = sources
        return .empty
    }
}

/// 可掛起的串流 fake:`stream` 開著但**不吐字**,直到測試呼叫 `releaseAll()` 才吐完 reply 並結束。
///
/// 為什麼需要它:展開保護（FR-54）只在「某則 cue 的 Tier 2 還在途」的那段時間窗內有意義,
/// 而既有 `FakeStreamingChatCompleting` 是同步吐完就結束——根本製造不出在途狀態。
/// 形狀鏡射它（NSLock + `@unchecked Sendable`）,只是多一道閘門。
///
/// 若在途的 task 被錯誤取消,`for try await` 會因 task cancellation 直接終止(AsyncThrowingStream
/// 的 onCancel 會 finish 串流),迴圈後的 `guard !Task.isCancelled` 就攔下寫回 → 斷言看得見,不會掛住。
private final class GatedStreamingChatCompleting: StreamingChatCompleting, @unchecked Sendable {
    private let reply: String
    private let lock = NSLock()
    private var _callCount = 0
    private var _gates: [AsyncThrowingStream<String, Error>.Continuation] = []
    private var _startWaiters: [CheckedContinuation<Void, Never>] = []
    /// 閘門開了之後才來的串流:直接放行,不再登記。
    /// **這是防「測試掛死」的關鍵**:保護若壞掉,會多冒出一條我們沒預期的 deep,它可能晚一步才
    /// 進到 stream(Task 是排程後才跑)。若讓它登記進一個已經沒人會再打開的閘門,測試會卡住而不是紅燈——
    /// 掛死的測試比失敗的測試難查十倍。
    private var _released = false

    init(reply: String) { self.reply = reply }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        // build closure 在 init 當下同步執行 → stream() 一回傳,閘門就已登記。
        AsyncThrowingStream { c in
            lock.lock()
            _callCount += 1
            let alreadyReleased = _released
            if !alreadyReleased { _gates.append(c) }
            let waiters = _startWaiters
            _startWaiters = []
            lock.unlock()
            for w in waiters { w.resume() }
            if alreadyReleased {
                c.yield(reply)
                c.finish()
            }
        }
    }

    /// 等到至少一條串流真的進到在途狀態（免 sleep 輪詢的同步點）。
    func waitForFirstCall() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _callCount > 0 {
                lock.unlock()
                c.resume()
                return
            }
            _startWaiters.append(c)
            lock.unlock()
        }
    }

    /// 放行所有在途串流(以及之後才來的):吐完 reply 後結束。
    func releaseAll() {
        lock.lock()
        let gates = _gates
        _gates = []
        _released = true
        lock.unlock()
        for g in gates {
            g.yield(reply)
            g.finish()
        }
    }
}

@MainActor
final class AnswerCoordinatorTests: XCTestCase {

    private var ctx: ModelContext!

    override func setUpWithError() throws {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self, MeetingLiveSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = ModelContext(container)
    }

    private func makeCue(text: String, kind: MeetingCueKind = .directQuestion,
                         searchHint: String = "") -> MeetingLiveCue {
        let session = MeetingLiveSession(appName: "test", brief: "訂單分庫 review")
        ctx.insert(session)
        let cue = MeetingLiveCue(session: session, text: text, kind: kind)
        cue.searchHint = searchHint
        ctx.insert(cue)
        try? ctx.save()
        return cue
    }

    /// - Parameter autoDeep: M8 auto-deep。**這裡預設關**(正式預設是開):既有測試鎖的是
    ///   「手動 requestDeep」路徑,若 tier1 順手掛出一條 auto-deep,那個在途 task 會再打一次
    ///   grounding/deep fake,把 spy 斷言變成競態。auto 行為由下面專屬的 auto-deep 測試明確開啟驗證。
    private func makeConfig(autoDeep: Bool = false) -> MeetingCopilotConfigStore {
        let c = MeetingCopilotConfigStore()
        c.setUseHistoryRAG(false)
        c.setUseScreenContext(false)
        c.setPrefetchEnabled(true)
        // M8 筆記 RAG:顯式設定,避免測試吃到 UserDefaults 殘留值。
        c.setUseNotesRAG(true)
        c.setNotesInTechnicalRAG(false)
        c.setAutoDeepEnabled(autoDeep)
        return c
    }

    /// AC-7 + AC-8:預跑 Tier1（fast 只呼叫一次）；Tier2 帶入 Tier1 草稿。
    func testPrefetchNewestAndDeepReceivesFastDraft() async {
        let fast = FakeStreamingChatCompleting(script: ["OPENER: 我會先確認規模\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(script: [
            #"{"analysis":"深度分析","followUps":[{"question":"要分片嗎？","oneLineAnswer":"先加快取"}],"uncertainties":["需壓測"]}"#
        ])
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: NoopGrounding(), config: makeConfig())
        let cue = makeCue(text: "設計短網址服務")

        await coord.onNewCue(cue)        // Tier0 + 預跑 Tier1
        await coord.requestDeep(cue)     // 點擊 Tier2

        XCTAssertEqual(fast.callCount, 1, "AC-7:預跑後點擊不再發新 Tier1 請求")
        XCTAssertTrue(deep.lastUser.contains("我會先確認規模"), "AC-8:Tier2 user 帶入 Tier1 opener")
        XCTAssertEqual(cue.tier1Opener, "我會先確認規模")
        XCTAssertEqual(cue.tier2Analysis, "深度分析")
        XCTAssertEqual(cue.tier2FollowUps.count, 1)
        XCTAssertTrue(cue.tier2FollowUps[0].contains("要分片嗎"))
        XCTAssertEqual(cue.status, .answered)

        // Tier0 也寫了（領域關鍵字）。
        XCTAssertFalse(cue.tier0Keywords.isEmpty)

        // 觀測資料:兩層的實際 prompt 與原始回覆都 persist(覆盤時能還原模型看到/回了什麼)。
        XCTAssertEqual(cue.tier1PromptUser, fast.lastUser, "persist 的 prompt 必須 = 實際送出的")
        XCTAssertEqual(cue.tier2PromptUser, deep.lastUser)
        XCTAssertTrue(cue.tier1RawReply.contains("我會先確認規模"))
        XCTAssertTrue(cue.tier2RawReply.contains("深度分析"))
        XCTAssertTrue(cue.tier1Error.isEmpty)
        XCTAssertTrue(cue.tier2Error.isEmpty)
    }

    /// 觀測資料:注入實名 label → fastModelName/deepModelName 記真實 "provider/model";
    /// 未注入(空)→ 維持 M3 佔位標記 "fast"/"deep"(向後相容)。
    func testModelLabelsPersisted() async {
        let fast = FakeStreamingChatCompleting(script: ["OPENER: 好\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(script: [#"{"analysis":"x","followUps":[],"uncertainties":[]}"#])
        let coord = AnswerCoordinator(
            fast: fast, deep: deep, grounding: NoopGrounding(), config: makeConfig(),
            fastLabel: "groq/llama-3.1-8b-instant", deepLabel: "anthropic/claude-sonnet-4")
        let cue = makeCue(text: "設計 rate limiter")

        await coord.onNewCue(cue)
        await coord.requestDeep(cue)

        XCTAssertEqual(cue.fastModelName, "groq/llama-3.1-8b-instant")
        XCTAssertEqual(cue.deepModelName, "anthropic/claude-sonnet-4")
    }

    /// AC-13:Tier2 失敗 → 保留 Tier1、status 不變 .answered、無可見 UI。
    func testDeepFailureKeepsFastDraftAndNoAnswered() async {
        let fast = FakeStreamingChatCompleting(script: ["OPENER: 開口\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(error: StreamingChatError.http(500, "boom"))
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: NoopGrounding(), config: makeConfig())
        let cue = makeCue(text: "x")

        await coord.onNewCue(cue)
        await coord.requestDeep(cue)

        XCTAssertEqual(cue.tier1Opener, "開口", "Tier1 保留")
        XCTAssertNotEqual(cue.status, .answered, "Tier2 失敗 → 不標 answered（降級）")
        XCTAssertTrue(cue.tier2Analysis.isEmpty)
        XCTAssertFalse(cue.tier2Error.isEmpty, "觀測資料:Tier2 失敗原因必須 persist(原本 log-only 查不到)")
    }

    /// Tier1 失敗 → 保留 Tier0，不跑 Tier2。
    func testTier1FailureKeepsTier0() async {
        let fast = FakeStreamingChatCompleting(error: StreamingChatError.http(500, "x"))
        let deep = FakeStreamingChatCompleting(script: ["should not run"])
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: NoopGrounding(), config: makeConfig())
        let cue = makeCue(text: "設計快取")

        await coord.onNewCue(cue)
        await coord.requestDeep(cue)

        XCTAssertFalse(cue.tier0Keywords.isEmpty, "Tier0 保留")
        XCTAssertTrue(cue.tier1Opener.isEmpty, "Tier1 失敗未寫")
        XCTAssertEqual(deep.callCount, 0, "Tier1 失敗 → 不跑 Tier2")
        XCTAssertFalse(cue.tier1Error.isEmpty, "觀測資料:Tier1 失敗原因必須 persist")
        XCTAssertFalse(cue.tier2Error.isEmpty, "觀測資料:Tier2 中止原因必須 persist")
    }

    // MARK: - M8 AC-32:檢索路由（gather sources 按 cue 種類分流）

    /// aboutMe cue → sources 鎖個人筆記、query 用 searchHint 改寫詞（口語原句嵌入命中率差），
    /// includeRAG 看 useNotesRAG 總開關——makeConfig 的 useHistoryRAG=false 必須不影響。
    func testAboutMeRoutesToObsidianWithSearchHint() async {
        let spy = SpyGrounding()
        let fast = FakeStreamingChatCompleting(script: ["OPENER: x\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(script: ["{}"])
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: spy, config: makeConfig())
        let cue = makeCue(text: "最有成就的專案？", kind: .aboutMe, searchHint: "專案 成果 上線")

        await coord.onNewCue(cue)
        await coord.drainPrefetchForTest()

        XCTAssertEqual(spy.lastSources, ["obsidian"])
        XCTAssertEqual(spy.lastQuery, "專案 成果 上線", "檢索 query 用 searchHint,不用口語原句")
        XCTAssertTrue(spy.lastIncludeRAG, "aboutMe 強制 RAG(useNotesRAG 總開關),不看 useHistoryRAG")
    }

    /// aboutMe cue 沒有 searchHint（抽取模型可能省略）→ 檢索 query 退回 cue 原句,
    /// 不能拿空字串去 embed（必命中零筆記）。
    func testAboutMeEmptySearchHintFallsBackToCueText() async {
        let spy = SpyGrounding()
        let fast = FakeStreamingChatCompleting(script: ["OPENER: x\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(script: ["{}"])
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: spy, config: makeConfig())
        let cue = makeCue(text: "最有成就的專案？", kind: .aboutMe)   // searchHint 預設 ""

        await coord.onNewCue(cue)
        await coord.drainPrefetchForTest()

        XCTAssertEqual(spy.lastQuery, "最有成就的專案？", "searchHint 空 → query 退回 cue 原句")
        XCTAssertEqual(spy.lastSources, ["obsidian"], "退回原句仍鎖個人筆記來源")
    }

    /// NFR（既有行為不變）:技術 cue 維持逐字稿三來源、**明確排除 obsidian**;
    /// notesInTechnicalRAG 顯式開啟才納入個人筆記。
    func testTechnicalCueKeepsTranscriptSources() async {
        let spy = SpyGrounding()
        let config = makeConfig()
        config.setUseHistoryRAG(true)
        let fast = FakeStreamingChatCompleting(script: ["OPENER: x\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(script: ["{}"])
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: spy, config: config)

        let cue = makeCue(text: "怎麼設計快取？")
        await coord.onNewCue(cue)
        await coord.drainPrefetchForTest()

        XCTAssertEqual(spy.lastSources, ["dictation", "recorder", "meeting"], "技術 cue 明確排除 obsidian")
        XCTAssertEqual(spy.lastQuery, "怎麼設計快取？", "非 aboutMe 用 cue 原句")
        XCTAssertTrue(spy.lastIncludeRAG, "技術 cue 沿用 useHistoryRAG")

        // 第二段:notesInTechnicalRAG=true → 技術檢索加入 obsidian。
        config.setNotesInTechnicalRAG(true)
        let cue2 = makeCue(text: "資料庫要分片嗎？")
        await coord.onNewCue(cue2)
        await coord.drainPrefetchForTest()
        XCTAssertEqual(spy.lastSources, ["dictation", "recorder", "meeting", "obsidian"])
    }

    // MARK: - M8 AC-34:auto-deep 與展開保護的取消語意

    /// FR-53:Tier 1 一寫完就自動接 Tier 2（不必手點），且觸發來源記 "auto"
    /// （覆盤要分得出「自動深答」與「使用者點的」——兩者的品質期待不同）。
    func testAutoDeepRunsAfterTier1AndMarksTrigger() async {
        let fast = FakeStreamingChatCompleting(script: ["OPENER: 先確認規模\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(script: [
            #"{"analysis":"深","followUps":[],"uncertainties":[]}"#
        ])
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: NoopGrounding(),
                                      config: makeConfig(autoDeep: true))
        let cue = makeCue(text: "怎麼設計快取？")

        await coord.onNewCue(cue)
        await coord.awaitQuiescentForTest()   // 等整條鏈:prefetch(tier1) → 掛出的 auto-deep

        XCTAssertEqual(cue.tier1Opener, "先確認規模")
        XCTAssertEqual(cue.tier2Analysis, "深", "Tier 1 完成後自動跑完 Tier 2")
        XCTAssertEqual(cue.tier2TriggerRaw, "auto")
        XCTAssertEqual(deep.callCount, 1, "自動深答只跑一次")
        XCTAssertEqual(cue.status, .answered)
    }

    /// 手動點擊路徑（auto-deep 關）→ 觸發來源記 "manual"。
    func testManualRequestDeepMarksManual() async {
        let fast = FakeStreamingChatCompleting(script: ["OPENER: x\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(script: [
            #"{"analysis":"深","followUps":[],"uncertainties":[]}"#
        ])
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: NoopGrounding(),
                                      config: makeConfig(autoDeep: false))
        let cue = makeCue(text: "怎麼設計快取？")

        await coord.onNewCue(cue)
        await coord.requestDeep(cue)

        XCTAssertEqual(cue.tier2Analysis, "深")
        XCTAssertEqual(cue.tier2TriggerRaw, "manual")
    }

    /// autoDeepEnabled=false → Tier 1 照跑,但**完全不碰 deep model**（不燒 token）。
    func testAutoDeepDisabledDoesNotRunTier2() async {
        let fast = FakeStreamingChatCompleting(script: ["OPENER: 先確認規模\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(script: [
            #"{"analysis":"不該跑","followUps":[],"uncertainties":[]}"#
        ])
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: NoopGrounding(),
                                      config: makeConfig(autoDeep: false))
        let cue = makeCue(text: "怎麼設計快取？")

        await coord.onNewCue(cue)
        await coord.awaitQuiescentForTest()

        XCTAssertEqual(cue.tier1Opener, "先確認規模", "Tier 1 仍自動預跑")
        XCTAssertTrue(cue.tier2Analysis.isEmpty, "關閉 auto-deep → Tier 2 不自動跑")
        XCTAssertEqual(deep.callCount, 0, "連呼叫都不該發生")
        XCTAssertTrue(cue.tier2TriggerRaw.isEmpty, "沒跑 → 觸發來源為空")
    }

    /// FR-54 閱讀保護（AC-34 的核心不變量）:cue A 展開中（使用者正在讀）且它的 Tier 2 還在途,
    /// 這時 cue B 進來觸發 auto-deep → **不得取消 A 的 deep**（取消 = 使用者眼前的分析被清空）。
    /// A 最終要完整寫回;B 的 auto-deep 則整個跳過（不排隊——排到時 B 早就不是最新的了）。
    func testNewCueDoesNotCancelExpandedCuesInflightDeep() async {
        let fast = FakeStreamingChatCompleting(script: ["OPENER: x\n- a\n- b\n- c"])
        let deep = GatedStreamingChatCompleting(
            reply: #"{"analysis":"深A","followUps":[],"uncertainties":[]}"#)
        let coord = AnswerCoordinator(fast: fast, deep: deep, grounding: NoopGrounding(),
                                      config: makeConfig(autoDeep: true))
        var expanded: UUID?
        coord.expandedCueIdProvider = { expanded }   // live 端是 controller.expandedCueId

        // cue A:tier1 → auto-deep 掛在閘門上（= 在途）。
        let a = makeCue(text: "A 的問題")
        await coord.onNewCue(a)
        await coord.drainPrefetchForTest()
        await deep.waitForFirstCall()
        expanded = a.id                              // 使用者正在讀 A 的分析

        // cue B 進來:tier1 跑完後的 auto-deep 必須因展開保護而跳過。
        let b = makeCue(text: "B 的問題")
        await coord.onNewCue(b)
        await coord.drainPrefetchForTest()

        deep.releaseAll()                            // 放行 A 的 deep 串流
        await coord.awaitQuiescentForTest()

        XCTAssertEqual(a.tier2Analysis, "深A", "展開中 cue 的在途 deep 不被新 cue 取消,且完整寫回")
        XCTAssertEqual(a.status, .answered)
        XCTAssertEqual(deep.callCount, 1, "B 的 auto-deep 被跳過（沒有第二次 deep 呼叫）")
        XCTAssertTrue(b.tier2Analysis.isEmpty)
        XCTAssertFalse(b.tier1Opener.isEmpty, "B 的 Tier 1 不受影響(保護只擋 deep)")
    }
}
