import XCTest
@testable import VoiceInk

// M14 會議脈絡卡測試：純函式核心（query 建構、JSON 解析與退化卡、任務關鍵詞匹配、
// 同場去重 cooldown 窗語意、config round-trip）＋ service 編排（trigger 去重、generation
// 過期丟棄、present/通知分流、零命中與退化卡分流、遲到降級）。全部零 I/O——不碰網路/
// SwiftData/NSPanel/`UserDefaults.standard`（見 TestDefaults.swift 教訓）。

// MARK: - Query 建構

final class ContextCardQueryTests: XCTestCase {

    func testPureZoomTitleFallsBackToAppName() {
        // 「Zoom Meeting」剝完全是平台雜訊 → 退 app 名。
        let q = ContextCardContent.buildQuery(windowTitle: "Zoom Meeting", appName: "Zoom")
        XCTAssertEqual(q.query, "Zoom")
        XCTAssertEqual(q.keywords, ["Zoom"])
    }

    func testGoogleMeetTabTitleKeepsSubject() {
        let q = ContextCardContent.buildQuery(
            windowTitle: "週會 sync - Google Meet - Google Chrome", appName: "Google Chrome")
        XCTAssertEqual(q.query, "週會 sync")
        XCTAssertEqual(q.keywords, ["週會", "sync"])
    }

    func testMeetRoomCodeStripped() {
        // 房間代碼 abc-defg-hij 必須整顆剝掉，不能被 `-` 切成 abc/defg/hij 三個假關鍵詞。
        let q = ContextCardContent.buildQuery(
            windowTitle: "Meet – abc-defg-hij", appName: "Google Chrome")
        XCTAssertEqual(q.query, "Google Chrome")
        XCTAssertEqual(q.keywords, ["Google Chrome"])
    }

    func testTeamsTitleWithPipe() {
        let q = ContextCardContent.buildQuery(
            windowTitle: "產品規劃討論 | Microsoft Teams", appName: "Microsoft Teams")
        XCTAssertEqual(q.query, "產品規劃討論")
    }

    func testDigitsDatesAndMeetingIdStripped() {
        // 日期/時間/會議 ID 的數字串全剝；「ID」「會議」是雜訊詞。
        let q = ContextCardContent.buildQuery(
            windowTitle: "Zoom 會議 ID: 123 4567 8901 產品週會 2026-07-21 10:30",
            appName: "Zoom")
        XCTAssertEqual(q.query, "產品週會")
        XCTAssertEqual(q.keywords, ["產品週會"])
    }

    func testEmptyAndNilTitleFallBackToAppName() {
        let empty = ContextCardContent.buildQuery(windowTitle: "  ", appName: "Microsoft Teams")
        XCTAssertEqual(empty.query, "Microsoft Teams")
        let missing = ContextCardContent.buildQuery(windowTitle: nil, appName: "Zoom")
        XCTAssertEqual(missing.query, "Zoom")
        XCTAssertEqual(missing.keywords, ["Zoom"])
    }

    func testEmptyTitleAndAppNameYieldsNoKeywords() {
        let q = ContextCardContent.buildQuery(windowTitle: nil, appName: "")
        XCTAssertEqual(q.query, "")
        XCTAssertTrue(q.keywords.isEmpty)
    }

    func testMixedCJKEnglishKeepsBoth() {
        let q = ContextCardContent.buildQuery(
            windowTitle: "Q3 Roadmap 評審會 - Zoom", appName: "Zoom")
        XCTAssertEqual(q.query, "Q3 Roadmap 評審會")
        XCTAssertEqual(q.keywords, ["Q3", "Roadmap", "評審會"])
    }

    func testDedupAndKeywordCap() {
        let q = ContextCardContent.buildQuery(
            windowTitle: "alpha beta alpha gamma delta epsilon zeta eta theta",
            appName: "Zoom")
        // 去重（alpha 只留一個）、keywords 上限 6；query 保留全部有效 token。
        XCTAssertEqual(q.keywords.count, 6)
        XCTAssertEqual(q.keywords, ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"])
        XCTAssertTrue(q.query.contains("theta"))
    }

    func testSingleCharacterTokensDropped() {
        // 單一 CJK 字/字母太泛，不當關鍵詞。
        let q = ContextCardContent.buildQuery(windowTitle: "會 A 面試準備", appName: "Zoom")
        XCTAssertEqual(q.query, "面試準備")
    }
}

// MARK: - JSON 解析與退化卡

final class ContextCardContentTests: XCTestCase {

    func testParseCardPlainJSON() {
        let raw = """
        {"last_summary": ["定了 Q3 目標"], "open_items": ["補齊規格文件"], \
        "my_promises": ["週五前給估時"], "first_meeting": false}
        """
        let parsed = ContextCardContent.parseCard(raw)
        XCTAssertEqual(parsed?.lastSummary, ["定了 Q3 目標"])
        XCTAssertEqual(parsed?.openItems, ["補齊規格文件"])
        XCTAssertEqual(parsed?.myPromises, ["週五前給估時"])
        XCTAssertEqual(parsed?.firstMeeting, false)
    }

    func testParseCardWithCodeFence() {
        let raw = """
        ```json
        {"last_summary": ["a"], "open_items": [], "my_promises": [], "first_meeting": true}
        ```
        """
        let parsed = ContextCardContent.parseCard(raw)
        XCTAssertEqual(parsed?.lastSummary, ["a"])
        XCTAssertEqual(parsed?.firstMeeting, true)
    }

    func testParseCardWithSurroundingProse() {
        let raw = """
        好的，以下是整理結果：
        {"last_summary": ["x"], "open_items": ["y"], "my_promises": [], "first_meeting": false}
        希望有幫助！
        """
        let parsed = ContextCardContent.parseCard(raw)
        XCTAssertEqual(parsed?.lastSummary, ["x"])
        XCTAssertEqual(parsed?.openItems, ["y"])
    }

    func testParseCardCapsTrimsAndDropsEmpties() {
        let raw = """
        {"last_summary": [" a ", "b", "", "c", "d"], \
        "open_items": ["1","2","3","4","5","6","7"], \
        "my_promises": ["p1","p2","p3","p4"], "first_meeting": false}
        """
        let parsed = ContextCardContent.parseCard(raw)
        XCTAssertEqual(parsed?.lastSummary, ["a", "b", "c"])        // 空條剔除 + cap 3
        XCTAssertEqual(parsed?.openItems.count, 5)                   // cap 5
        XCTAssertEqual(parsed?.myPromises.count, 3)                  // cap 3
    }

    func testParseCardMissingFieldsDefault() {
        let parsed = ContextCardContent.parseCard(#"{"first_meeting": true}"#)
        XCTAssertEqual(parsed?.lastSummary, [])
        XCTAssertEqual(parsed?.openItems, [])
        XCTAssertEqual(parsed?.myPromises, [])
        XCTAssertEqual(parsed?.firstMeeting, true)
    }

    func testParseCardGarbageReturnsNil() {
        XCTAssertNil(ContextCardContent.parseCard("完全不是 JSON 的回答"))
        XCTAssertNil(ContextCardContent.parseCard(""))
        XCTAssertNil(ContextCardContent.parseCard("{broken json"))
    }

    func testNoteLinksDedupTitleFallbackAndSkipTranscripts() {
        let chunks = [
            // meeting 塊沒有 sourcePath → 沒檔案可開，略過。
            ContextChunkInfo(text: "t1", sourceKind: "meeting", sourceTitle: nil, sourcePath: nil),
            ContextChunkInfo(text: "t2", sourceKind: "obsidian",
                             sourceTitle: "專案 A 週會", sourcePath: "工作/專案A.md"),
            // 同 path 第二塊 → 去重。
            ContextChunkInfo(text: "t3", sourceKind: "obsidian",
                             sourceTitle: "專案 A 週會", sourcePath: "工作/專案A.md"),
            // 無標題 → 檔名（去 .md）當標題。
            ContextChunkInfo(text: "t4", sourceKind: "obsidian",
                             sourceTitle: nil, sourcePath: "日記/2026-07-14.md"),
        ]
        let links = ContextCardContent.noteLinks(from: chunks)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].title, "專案 A 週會")
        XCTAssertEqual(links[0].path, "工作/專案A.md")
        XCTAssertEqual(links[1].title, "2026-07-14")
    }

    func testBuildUserBlockContainsAllParts() {
        let block = ContextCardContent.buildUserBlock(
            meetingTitle: "產品週會",
            chunks: [ContextChunkInfo(text: "上次談到定價", sourceKind: "obsidian",
                                      sourceTitle: "定價筆記", sourcePath: "p.md")],
            taskTitles: ["補定價試算表"])
        XCTAssertTrue(block.contains("會議標題:產品週會"))
        XCTAssertTrue(block.contains("[1]《定價筆記》 上次談到定價"))
        XCTAssertTrue(block.contains("- 補定價試算表"))
    }
}

// MARK: - 任務關鍵詞匹配

final class ContextCardTaskMatchTests: XCTestCase {

    private func task(_ id: Int, _ title: String, done: Bool = false) -> VikunjaService.TaskItem {
        VikunjaService.TaskItem(id: id, title: title, done: done)
    }

    func testCaseInsensitiveMatch() {
        let matched = ContextCardContent.matchTasks(
            [task(1, "Fix ROADMAP doc"), task(2, "買菜")], keywords: ["roadmap"])
        XCTAssertEqual(matched.map(\.id), [1])
    }

    func testPartialContainsMatch() {
        // 關鍵詞是任務標題的子字串即可（包含比對，非全等）。
        let matched = ContextCardContent.matchTasks(
            [task(1, "整理產品週會簡報"), task(2, "回覆信件")], keywords: ["週會"])
        XCTAssertEqual(matched.map(\.id), [1])
    }

    func testEmptyKeywordsMatchNothing() {
        let tasks = [task(1, "a"), task(2, "b")]
        XCTAssertTrue(ContextCardContent.matchTasks(tasks, keywords: []).isEmpty)
        // 空白字串關鍵詞也不得整批放行（"" 包含於任何字串）。
        XCTAssertTrue(ContextCardContent.matchTasks(tasks, keywords: ["  ", ""]).isEmpty)
    }

    func testSkipsDoneAndAppliesLimit() {
        let tasks = [
            task(1, "週會 A", done: true),
            task(2, "週會 B"), task(3, "週會 C"), task(4, "週會 D"),
            task(5, "週會 E"), task(6, "週會 F"), task(7, "週會 G"),
        ]
        let matched = ContextCardContent.matchTasks(tasks, keywords: ["週會"])
        XCTAssertEqual(matched.map(\.id), [2, 3, 4, 5, 6])   // done 略過、上限 5、保序
    }

    func testMultipleKeywordsAnyHit() {
        let matched = ContextCardContent.matchTasks(
            [task(1, "定價試算"), task(2, "roadmap 檢視"), task(3, "無關")],
            keywords: ["定價", "roadmap"])
        XCTAssertEqual(matched.map(\.id), [1, 2])
    }
}

// MARK: - 同場去重（cooldown 窗語意）

final class ContextCardGateTests: XCTestCase {

    func testFirstTriggerPasses() {
        var gate = ContextCardGate()
        XCTAssertTrue(gate.shouldTrigger(now: Date(timeIntervalSince1970: 1000)))
    }

    func testSecondWithinCooldownBlocked() {
        // M11 偵測命中 → 幾分鐘後使用者按開錄：第二個入口必須被吃掉（同場只出一張卡）。
        var gate = ContextCardGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(gate.shouldTrigger(now: t0, cooldown: 600))
        XCTAssertFalse(gate.shouldTrigger(now: t0.addingTimeInterval(180), cooldown: 600))
        XCTAssertFalse(gate.shouldTrigger(now: t0.addingTimeInterval(599), cooldown: 600))
    }

    func testBlockedTriggerDoesNotExtendWindow() {
        // 被吃掉的觸發**不得**重新蓋章——否則連續觸發會把窗無限延長，下一場會也被吃。
        var gate = ContextCardGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(gate.shouldTrigger(now: t0, cooldown: 600))
        XCTAssertFalse(gate.shouldTrigger(now: t0.addingTimeInterval(599), cooldown: 600))
        // 距**第一次**觸發 600s → 新場次放行（若被 599 那次延長，這裡會 false）。
        XCTAssertTrue(gate.shouldTrigger(now: t0.addingTimeInterval(600), cooldown: 600))
    }

    func testResetAllowsImmediateRetrigger() {
        var gate = ContextCardGate()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(gate.shouldTrigger(now: t0))
        gate.reset()
        XCTAssertTrue(gate.shouldTrigger(now: t0.addingTimeInterval(1)))
    }
}

// MARK: - Service 編排（fake seams）

@MainActor
private final class CardFakeRetriever: ContextCardRetrieving {
    var chunks: [ContextChunkInfo] = []
    private(set) var calls = 0
    func retrieve(query: String) async -> [ContextChunkInfo] {
        calls += 1
        return chunks
    }
}

@MainActor
private final class CardFakeTaskLister: ContextCardTaskListing {
    var tasks: [VikunjaService.TaskItem] = []
    func openTasks() async throws -> [VikunjaService.TaskItem] { tasks }
}

/// 立即回覆或立即失敗。
@MainActor
private final class CardScriptedCompleter: ContextCardCompleting {
    enum Behavior {
        case reply(String)
        case fail
    }
    private let behavior: Behavior
    private(set) var calls = 0
    init(_ behavior: Behavior) { self.behavior = behavior }
    func complete(system: String, user: String) async throws -> String {
        calls += 1
        switch behavior {
        case .reply(let s): return s
        case .fail: throw NSError(domain: "test", code: 1)
        }
    }
}

/// 掛起直到測試手動 resume——製造「生成期間又觸發新一輪」「結果遲到」的時序。
@MainActor
private final class CardPendingCompleter: ContextCardCompleting {
    private(set) var continuations: [CheckedContinuation<String, Error>] = []
    func complete(system: String, user: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func resume(_ index: Int, with reply: String) {
        continuations[index].resume(returning: reply)
    }
}

@MainActor
private final class CardFakePresenter: ContextCardPresenting {
    private(set) var shows = 0
    private(set) var notifies = 0
    func showCard() { shows += 1 }
    func notifyCardReady() { notifies += 1 }
}

// MARK: - Service 編排測試

@MainActor
final class MeetingContextCardServiceTests: XCTestCase {

    /// 可變時鐘（注入 service 的 `now`，測時間語意不 sleep）。
    private final class ClockBox { var now = Date(timeIntervalSince1970: 1_000_000) }

    private var config: MeetingContextCardConfigStore!
    private var service: MeetingContextCardService!
    private var retriever: CardFakeRetriever!
    private var taskLister: CardFakeTaskLister!
    private var presenter: CardFakePresenter!
    private var clock: ClockBox!

    private let goodJSON = """
    {"last_summary": ["上次定了 Q3 目標"], "open_items": ["補規格"], \
    "my_promises": [], "first_meeting": false}
    """
    private let obsidianChunk = ContextChunkInfo(
        text: "上次談到定價", sourceKind: "obsidian",
        sourceTitle: "定價筆記", sourcePath: "工作/定價.md")

    override func setUp() async throws {
        try await super.setUp()
        config = MeetingContextCardConfigStore(defaults: InMemoryDefaults())
        service = MeetingContextCardService(config: config)
        retriever = CardFakeRetriever()
        taskLister = CardFakeTaskLister()
        presenter = CardFakePresenter()
        clock = ClockBox()
    }

    private func wire(_ completer: ContextCardCompleting) {
        let box = clock!
        service.configureForTesting(
            retriever: retriever, taskLister: taskLister, completer: completer,
            presenter: presenter, now: { box.now })
    }

    /// 等背景生成 Task 走到目標狀態（生成全在 main actor，yield/短 sleep 即可交錯）。
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "waitUntil 逾時", file: file, line: line)
    }

    /// 再多讓幾拍——確認「不該發生的事」沒有晚一步才發生。
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // 紅線 1：同一偵測窗內兩個入口（M11 偵測 → 幾分鐘後手動開錄）只生成一次、只出一張卡。
    func testSecondTriggerInSameWindowIsDeduped() async {
        retriever.chunks = [obsidianChunk]
        let completer = CardScriptedCompleter(.reply(goodJSON))
        wire(completer)

        service.noteMeetingDetected(bundleId: "us.zoom.xos", displayName: "Zoom")
        await waitUntil { self.presenter.shows == 1 }

        // 幾分鐘後才按「開始會議錄製」（常見時序）→ 第二個入口必須被同場 gate 吃掉。
        clock.now = clock.now.addingTimeInterval(180)
        service.noteRecordingStarted(appName: "Zoom")
        await settle()
        XCTAssertEqual(completer.calls, 1)
        XCTAssertEqual(retriever.calls, 1)
        XCTAssertEqual(presenter.shows, 1)
        XCTAssertEqual(presenter.notifies, 0)
    }

    func testNewMeetingAfterCooldownTriggersAgain() async {
        retriever.chunks = [obsidianChunk]
        let completer = CardScriptedCompleter(.reply(goodJSON))
        wire(completer)

        service.noteRecordingStarted(appName: "Zoom")
        await waitUntil { self.presenter.shows == 1 }

        clock.now = clock.now.addingTimeInterval(ContextCardGate.defaultCooldown + 1)
        service.noteRecordingStarted(appName: "Teams")
        await waitUntil { self.presenter.shows == 2 }
        XCTAssertEqual(completer.calls, 2)
    }

    // 紅線 2：生成期間又觸發新一輪 → 舊 generation 的結果丟棄，不得蓋掉新卡。
    func testStaleGenerationResultIsDropped() async {
        retriever.chunks = [obsidianChunk]
        let completer = CardPendingCompleter()
        wire(completer)

        service.noteRecordingStarted(appName: "AlphaApp")
        await waitUntil { completer.continuations.count == 1 }

        clock.now = clock.now.addingTimeInterval(ContextCardGate.defaultCooldown + 1)
        service.noteRecordingStarted(appName: "BetaApp")
        await waitUntil { completer.continuations.count == 2 }

        // 新一輪（Beta）先完成 → 上卡。
        completer.resume(1, with: goodJSON)
        await waitUntil { self.presenter.shows == 1 }
        XCTAssertEqual(service.model?.meetingTitle, "BetaApp")

        // 舊一輪（Alpha）遲到完成 → 整包丟棄：model 不變、不再 present 也不降級成通知。
        completer.resume(0, with: goodJSON)
        await settle()
        XCTAssertEqual(service.model?.meetingTitle, "BetaApp")
        XCTAssertEqual(presenter.shows, 1)
        XCTAssertEqual(presenter.notifies, 0)
    }

    // 紅線 3a：RAG 零命中且無任務、showWhenEmpty=false（預設）→ 完全不打擾、不花 LLM。
    func testZeroHitStaysQuietByDefault() async {
        let completer = CardScriptedCompleter(.reply(goodJSON))
        wire(completer)

        service.noteRecordingStarted(appName: "Zoom")
        await waitUntil { self.retriever.calls == 1 }
        await settle()
        XCTAssertEqual(completer.calls, 0)
        XCTAssertEqual(presenter.shows, 0)
        XCTAssertEqual(presenter.notifies, 0)
        XCTAssertNil(service.model)
    }

    // 紅線 3b：showWhenEmpty=true → 中性空卡（firstMeeting），仍不花 LLM。
    func testZeroHitShowsNeutralCardWhenOptedIn() async {
        config.setShowWhenEmpty(true)
        let completer = CardScriptedCompleter(.reply(goodJSON))
        wire(completer)

        service.noteRecordingStarted(appName: "Zoom")
        await waitUntil { self.presenter.shows == 1 }
        XCTAssertEqual(completer.calls, 0)
        XCTAssertEqual(service.model?.firstMeeting, true)
        XCTAssertEqual(service.model?.isFallback, false)
    }

    // 紅線 4a：LLM 失敗 → 退化卡（來源連結保留、內容不捏造），照樣呈現。
    func testLLMFailureFallsBackToSourceOnlyCard() async {
        retriever.chunks = [obsidianChunk]
        wire(CardScriptedCompleter(.fail))

        service.noteRecordingStarted(appName: "Zoom")
        await waitUntil { self.presenter.shows == 1 }
        XCTAssertEqual(service.model?.isFallback, true)
        XCTAssertEqual(service.model?.noteLinks.map(\.path), ["工作/定價.md"])
        XCTAssertEqual(service.model?.lastSummary, [])
    }

    // 紅線 4b：LLM 回非 JSON → 同樣退化卡。
    func testParseFailureFallsBackToSourceOnlyCard() async {
        retriever.chunks = [obsidianChunk]
        wire(CardScriptedCompleter(.reply("完全不是 JSON 的回答")))

        service.noteRecordingStarted(appName: "Zoom")
        await waitUntil { self.presenter.shows == 1 }
        XCTAssertEqual(service.model?.isFallback, true)
    }

    // 分流：autoShow=false → 通知路徑，不直接浮卡。
    func testAutoShowOffRoutesToNotification() async {
        config.setAutoShow(false)
        retriever.chunks = [obsidianChunk]
        wire(CardScriptedCompleter(.reply(goodJSON)))

        service.noteRecordingStarted(appName: "Zoom")
        await waitUntil { self.presenter.notifies == 1 }
        XCTAssertEqual(presenter.shows, 0)
        XCTAssertNotNil(service.model)
    }

    // 遲到降級：生成超過 autoShowStaleAfter 才完成 → 即便 autoShow=true 也不搶畫面，改發通知。
    func testLateResultDowngradesAutoShowToNotification() async {
        retriever.chunks = [obsidianChunk]
        let completer = CardPendingCompleter()
        wire(completer)

        service.noteRecordingStarted(appName: "Zoom")
        await waitUntil { completer.continuations.count == 1 }

        clock.now = clock.now.addingTimeInterval(MeetingContextCardService.autoShowStaleAfter + 1)
        completer.resume(0, with: goodJSON)
        await waitUntil { self.presenter.notifies == 1 }
        XCTAssertEqual(presenter.shows, 0)
        XCTAssertNotNil(service.model)   // 卡片仍就緒，點通知才開
    }

    // 總開關關閉 → 兩個入口都零工作（不檢索、不生成、不動 gate）。
    func testDisabledConfigDoesNothing() async {
        config.setEnabled(false)
        retriever.chunks = [obsidianChunk]
        let completer = CardScriptedCompleter(.reply(goodJSON))
        wire(completer)

        service.noteRecordingStarted(appName: "Zoom")
        await settle()
        XCTAssertEqual(retriever.calls, 0)
        XCTAssertEqual(completer.calls, 0)
        XCTAssertNil(service.model)
    }
}

// MARK: - Config round-trip

@MainActor
final class MeetingContextCardConfigStoreTests: XCTestCase {

    func testDefaults() {
        let store = MeetingContextCardConfigStore(defaults: InMemoryDefaults())
        XCTAssertTrue(store.enabled)
        XCTAssertTrue(store.autoShow)
        XCTAssertFalse(store.showWhenEmpty)
    }

    func testRoundTrip() {
        let defaults = InMemoryDefaults()
        let store = MeetingContextCardConfigStore(defaults: defaults)

        store.setEnabled(false)
        store.setAutoShow(false)
        store.setShowWhenEmpty(true)
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(store.autoShow)
        XCTAssertTrue(store.showWhenEmpty)

        // 同一後端重建 → 全部載回。
        let reloaded = MeetingContextCardConfigStore(defaults: defaults)
        XCTAssertFalse(reloaded.enabled)
        XCTAssertFalse(reloaded.autoShow)
        XCTAssertTrue(reloaded.showWhenEmpty)
    }
}
