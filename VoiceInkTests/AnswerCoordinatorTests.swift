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

    private func makeConfig() -> MeetingCopilotConfigStore {
        let c = MeetingCopilotConfigStore()
        c.setUseHistoryRAG(false)
        c.setUseScreenContext(false)
        c.setPrefetchEnabled(true)
        // M8 筆記 RAG:顯式設定,避免測試吃到 UserDefaults 殘留值。
        c.setUseNotesRAG(true)
        c.setNotesInTechnicalRAG(false)
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
}
