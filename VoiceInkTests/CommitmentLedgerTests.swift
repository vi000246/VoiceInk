import XCTest
import SwiftData
@testable import VoiceInk

// MARK: - 純函式:pre-filter 詞表 / prompt / JSON 解析

final class CommitmentCueDetectorTests: XCTestCase {

    // MARK: pre-filter 中文

    func testZhMarkersHit() {
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "我會把報告寄給你").isEmpty)
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "這塊我來處理").isEmpty)
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "我幫你查一下 log").isEmpty)
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "我確認後回覆你").isEmpty)
    }

    func testZhDeadlineComboHit() {
        // 「時間詞 … 前」組合:明天之前 / 下週五以前。
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "明天之前給你").contains("明天…前"))
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "下週五以前弄完").contains("下週…前"))
        // 時間詞後 4 字內沒有「前」→ 不算組合。
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "明天再說吧要不要做都不一定之後看前面")
            .contains("明天…前"))
    }

    func testZhNegationExcluded() {
        // 否定前綴:詞表詞(給你/寄給)前面直接掛否定 → 排除。
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "我不會給你這份文件").isEmpty)
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "這個沒寄給他").isEmpty)
        // 「我不會」「我怎麼會」本身不含「我會」連續子字串,天然不命中。
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "我怎麼會知道").isEmpty)
    }

    func testZhRhetoricalExcluded() {
        // 反問尾:子句以「嗎」收尾 → 排除。
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "你覺得我會嗎?").isEmpty)
        // 同一個詞出現在非反問子句 → 照常命中。
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "我會嗎?好啦,我會處理").isEmpty)
    }

    func testZhNegationNotOverTriggered() {
        // 否定字出現在**非緊鄰**位置不得誤殺:「這個不難,我來處理」仍是承諾候選。
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "這個不難,我來處理").isEmpty)
    }

    func testZhInformationalMiss() {
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "我們上週上線了 v2").isEmpty)
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "這是他們團隊的決定").isEmpty)
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "").isEmpty)
    }

    // MARK: pre-filter 英文

    func testEnMarkersHit() {
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "I'll send the report by Friday").isEmpty)
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "Let me check the logs").isEmpty)
        XCTAssertFalse(CommitmentCueDetector.candidates(in: "I can send you the doc").isEmpty)
    }

    func testEnNegationExcluded() {
        // "i will " 命中但被 "i will not" 片語覆蓋 → 排除。
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "I will not send it").isEmpty)
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "I'm not going to do that").isEmpty)
        // "I won't" 不含任何承諾詞,天然不命中。
        XCTAssertTrue(CommitmentCueDetector.candidates(in: "I won't be able to make it").isEmpty)
    }

    // MARK: prompt(純函式)

    func testBuildPromptDeterministicAndIncludesContext() {
        let a = CommitmentCueDetector.buildPrompt(committed: "我會寄給你", previousLocal: "剛剛講到報告")
        let b = CommitmentCueDetector.buildPrompt(committed: "我會寄給你", previousLocal: "剛剛講到報告")
        XCTAssertEqual(a.system, b.system)
        XCTAssertEqual(a.user, b.user)
        XCTAssertTrue(a.user.contains("剛剛講到報告"))
        XCTAssertTrue(a.user.contains("我剛說:"))

        let noContext = CommitmentCueDetector.buildPrompt(committed: "我會寄給你")
        XCTAssertFalse(noContext.user.contains("前一段"))
    }

    // MARK: JSON 解析(保守丟棄)

    func testParseValidCommitment() throws {
        let d = try XCTUnwrap(CommitmentCueDetector.parse(
            #"{"is_commitment": true, "title": "寄效能報告給 Alex", "due_hint": "下週五之前"}"#))
        XCTAssertEqual(d.title, "寄效能報告給 Alex")
        XCTAssertEqual(d.dueHint, "下週五之前")
        XCTAssertFalse(d.unconfirmed)
    }

    func testParseNullDueHintBecomesEmpty() throws {
        let d = try XCTUnwrap(CommitmentCueDetector.parse(
            #"{"is_commitment": true, "title": "更新 wiki", "due_hint": null}"#))
        XCTAssertEqual(d.dueHint, "")
    }

    func testParseStripsMarkdownFence() throws {
        let raw = "```json\n{\"is_commitment\": true, \"title\": \"更新 wiki\", \"due_hint\": null}\n```"
        let d = try XCTUnwrap(CommitmentCueDetector.parse(raw))
        XCTAssertEqual(d.title, "更新 wiki")
    }

    /// remote 分類器契約不含 commitment——模型腦補該 kind 時整則丟棄,不得漏進承諾帳本。
    func testRemoteExtractorRejectsCommitmentKind() {
        let cues = ResponseCueExtractor.parse(
            #"{"cues":[{"text":"我會寄報告","kind":"commitment"},{"text":"你會怎麼設計?","kind":"directQuestion"}]}"#)
        XCTAssertEqual(cues.map(\.kind), [.directQuestion])
    }

    func testParseRejectsNonCommitmentAndGarbage() {
        XCTAssertNil(CommitmentCueDetector.parse(
            #"{"is_commitment": false, "title": "", "due_hint": null}"#))
        XCTAssertNil(CommitmentCueDetector.parse(
            #"{"is_commitment": true, "title": "  ", "due_hint": null}"#), "title 空 → 保守丟棄")
        XCTAssertNil(CommitmentCueDetector.parse("我覺得這是承諾"))
        XCTAssertNil(CommitmentCueDetector.parse(""))
    }

    // MARK: detect(pre-filter → LLM;fake completer scripted)

    func testDetectSkipsLLMWhenPrefilterMisses() async {
        let fake = FakeChatCompleting(reply: #"{"is_commitment": true, "title": "x", "due_hint": null}"#)
        let detector = CommitmentCueDetector(chat: fake)
        let result = await detector.detect(committed: "我們上週上線了 v2")
        XCTAssertNil(result)
        XCTAssertEqual(fake.callCount, 0, "pre-filter 沒中不得呼叫 LLM(省錢)")
    }

    func testDetectConfirmsViaLLM() async throws {
        let fake = FakeChatCompleting(
            reply: #"{"is_commitment": true, "title": "寄效能報告給 Alex", "due_hint": "下週五之前"}"#)
        let detector = CommitmentCueDetector(chat: fake)
        let detected = await detector.detect(
            committed: "我會把效能報告寄給 Alex", previousLocal: "剛提到效能")
        let result = try XCTUnwrap(detected)
        XCTAssertEqual(result.title, "寄效能報告給 Alex")
        XCTAssertEqual(result.dueHint, "下週五之前")
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertTrue(fake.lastUser?.contains("剛提到效能") == true, "前一段 local 要進上下文")
    }

    func testDetectDropsWhenLLMRejectsOrFails() async {
        let rejecting = FakeChatCompleting(reply: #"{"is_commitment": false, "title": "", "due_hint": null}"#)
        let r1 = await CommitmentCueDetector(chat: rejecting).detect(committed: "我會考慮看看")
        XCTAssertNil(r1)

        let garbage = FakeChatCompleting(reply: "not json at all")
        let r2 = await CommitmentCueDetector(chat: garbage).detect(committed: "我會考慮看看")
        XCTAssertNil(r2, "解析失敗 → 保守丟棄")

        let throwing = FakeChatCompleting(shouldThrow: true)
        let r3 = await CommitmentCueDetector(chat: throwing).detect(committed: "我會考慮看看")
        XCTAssertNil(r3, "LLM 失敗 → 保守丟棄(寧漏勿誤)")
    }

    func testDetectWordlistOnlyWhenConfirmDisabled() async throws {
        let fake = FakeChatCompleting(reply: #"{"is_commitment": true, "title": "x", "due_hint": null}"#)
        let detector = CommitmentCueDetector(chat: fake, llmConfirmEnabled: false)
        let detected = await detector.detect(committed: " 我會把報告寄給你 ")
        let result = try XCTUnwrap(detected)
        XCTAssertEqual(result.title, "我會把報告寄給你", "純詞表模式記 committed 原文(trim 後)")
        XCTAssertTrue(result.unconfirmed)
        XCTAssertEqual(fake.callCount, 0, "關掉 LLM 確認就不得打 LLM")
    }
}

// MARK: - Config round-trip(注入 in-memory 後端;紅線:不碰 UserDefaults.standard)

@MainActor
final class CommitmentLedgerConfigStoreTests: XCTestCase {

    func testDefaults() {
        let store = CommitmentLedgerConfigStore(defaults: InMemoryDefaults())
        XCTAssertTrue(store.enabled)
        XCTAssertTrue(store.liveToastEnabled)
        XCTAssertTrue(store.llmConfirmEnabled)
    }

    func testRoundTrip() {
        let backend = InMemoryDefaults()
        let store = CommitmentLedgerConfigStore(defaults: backend)
        store.setEnabled(false)
        store.setLiveToastEnabled(false)
        store.setLLMConfirmEnabled(false)

        let reloaded = CommitmentLedgerConfigStore(defaults: backend)
        XCTAssertFalse(reloaded.enabled)
        XCTAssertFalse(reloaded.liveToastEnabled)
        XCTAssertFalse(reloaded.llmConfirmEnabled)
    }
}

// MARK: - 帳本狀態轉移(純函式)

final class CommitmentLedgerLogicTests: XCTestCase {

    func testTransitionOnlyFromDetected() {
        XCTAssertEqual(CommitmentLedgerLogic.transition(from: .detected, action: .convert), .converted)
        XCTAssertEqual(CommitmentLedgerLogic.transition(from: .detected, action: .dismiss), .dismissed)
        XCTAssertNil(CommitmentLedgerLogic.transition(from: .converted, action: .dismiss), "已處理不再轉移")
        XCTAssertNil(CommitmentLedgerLogic.transition(from: .dismissed, action: .convert))
        XCTAssertNil(CommitmentLedgerLogic.transition(from: .answered, action: .convert))
    }

    func testIsPendingFallsBackToDetectedOnUnknownRaw() {
        XCTAssertTrue(CommitmentLedgerLogic.isPending(statusRaw: "detected"))
        XCTAssertTrue(CommitmentLedgerLogic.isPending(statusRaw: "某個未來新增的值"),
                      "未知 rawValue 與 model accessor 同語意:當 detected(不吞資料)")
        XCTAssertFalse(CommitmentLedgerLogic.isPending(statusRaw: "converted"))
        XCTAssertFalse(CommitmentLedgerLogic.isPending(statusRaw: "dismissed"))
    }

    func testVisibleFiltersProcessedByDefault() {
        let rows = [("a", "detected"), ("b", "converted"), ("c", "dismissed")]
        let pendingOnly = CommitmentLedgerLogic.visible(rows, statusRaw: { $0.1 }, showProcessed: false)
        XCTAssertEqual(pendingOnly.map(\.0), ["a"])
        let all = CommitmentLedgerLogic.visible(rows, statusRaw: { $0.1 }, showProcessed: true)
        XCTAssertEqual(all.map(\.0), ["a", "b", "c"])
    }
}

// MARK: - 偵測器對 segment 流的整合(controller 掛點;fake completer scripted)

@MainActor
final class CommitmentLedgerControllerTests: XCTestCase {

    /// 每個測試一份 in-memory 設定後端(紅線:不碰 `.standard`)。
    private let defaultsSuite = InMemoryDefaults()

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self, MeetingLiveSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makeController(ctx: ModelContext) -> MeetingCopilotController {
        MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: FakeChatCompleting()),
            config: MeetingCopilotConfigStore(defaults: defaultsSuite),
            modelContext: ctx)
    }

    func testLocalCommitmentRecordedAndHiddenFromOverlay() async throws {
        let ctx = try makeContext()
        let controller = makeController(ctx: ctx)
        let fake = FakeChatCompleting(
            reply: #"{"is_commitment": true, "title": "寄效能報告給 Alex", "due_hint": "下週五之前"}"#)
        controller.commitmentDetector = CommitmentCueDetector(chat: fake)
        var toasts: [String] = []
        controller.onCommitmentRecorded = { toasts.append($0.text) }
        controller.beginSession(appName: "test")

        controller.handleLocalCommitted("我會把效能報告寄給 Alex")
        await controller.drainInflight()

        let cues = try ctx.fetch(FetchDescriptor<MeetingLiveCue>())
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].kind, .commitment)
        XCTAssertEqual(cues[0].status, .detected)
        XCTAssertEqual(cues[0].text, "寄效能報告給 Alex")
        XCTAssertEqual(cues[0].dueHint, "下週五之前")
        XCTAssertFalse(cues[0].commitmentUnconfirmed)
        XCTAssertEqual(controller.commitmentCount, 1)
        XCTAssertEqual(toasts, ["寄效能報告給 Alex"])

        // 絕不進 overlay 待答清單(即使 informational 開關打開)。
        controller.refreshPublishedCues()
        XCTAssertTrue(controller.cues.isEmpty)

        // local segment 照舊落入時間軸(承諾偵測不取代原本的 segment 記錄)。
        let segments = try ctx.fetch(FetchDescriptor<MeetingLiveSegment>())
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].channel, .local)
        XCTAssertEqual(segments[0].extractedCount, -1, "local 段不跑 response cue 抽取")
    }

    func testDedupWithin120sWindow() async throws {
        let ctx = try makeContext()
        let controller = makeController(ctx: ctx)
        // 兩段話 LLM 都回同一個 title → 第二筆應被 120s 去重窗擋下。
        let fake = FakeChatCompleting(
            reply: #"{"is_commitment": true, "title": "寄效能報告給 Alex", "due_hint": null}"#)
        controller.commitmentDetector = CommitmentCueDetector(chat: fake)
        controller.beginSession(appName: "test")

        controller.handleLocalCommitted("我會把效能報告寄給 Alex")
        await controller.drainInflight()
        controller.handleLocalCommitted("那份效能報告我會寄給 Alex")
        await controller.drainInflight()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 1, "相似承諾應去重")
        XCTAssertEqual(controller.commitmentCount, 1)
        XCTAssertEqual(fake.callCount, 2, "去重在 persist 層,確認呼叫仍每段一次")
    }

    func testLLMFailureDropsCandidateButKeepsSegment() async throws {
        let ctx = try makeContext()
        let controller = makeController(ctx: ctx)
        controller.commitmentDetector = CommitmentCueDetector(chat: FakeChatCompleting(shouldThrow: true))
        controller.beginSession(appName: "test")

        controller.handleLocalCommitted("我會把效能報告寄給 Alex")
        await controller.drainInflight()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0, "LLM 失敗 → 保守丟棄")
        XCTAssertEqual(controller.commitmentCount, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSegment>()).count, 1, "segment 照舊落地")
    }

    func testPrefilterMissNeverCallsLLM() async throws {
        let ctx = try makeContext()
        let controller = makeController(ctx: ctx)
        let fake = FakeChatCompleting(reply: #"{"is_commitment": true, "title": "x", "due_hint": null}"#)
        controller.commitmentDetector = CommitmentCueDetector(chat: fake)
        controller.beginSession(appName: "test")

        controller.handleLocalCommitted("我們上週上線了 v2")
        await controller.drainInflight()

        XCTAssertEqual(fake.callCount, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSegment>()).count, 1)
    }

    func testNoDetectorRecordsSegmentOnly() async throws {
        let ctx = try makeContext()
        let controller = makeController(ctx: ctx)   // commitmentDetector 未接線
        controller.beginSession(appName: "test")

        controller.handleLocalCommitted("我會把效能報告寄給 Alex")
        await controller.drainInflight()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSegment>()).count, 1)
    }

    func testWordlistOnlyModeMarksUnconfirmed() async throws {
        let ctx = try makeContext()
        let controller = makeController(ctx: ctx)
        let fake = FakeChatCompleting()
        controller.commitmentDetector = CommitmentCueDetector(chat: fake, llmConfirmEnabled: false)
        controller.beginSession(appName: "test")

        controller.handleLocalCommitted("我會把效能報告寄給 Alex")
        await controller.drainInflight()

        let cues = try ctx.fetch(FetchDescriptor<MeetingLiveCue>())
        XCTAssertEqual(cues.count, 1)
        XCTAssertTrue(cues[0].commitmentUnconfirmed)
        XCTAssertEqual(cues[0].text, "我會把效能報告寄給 Alex")
        XCTAssertEqual(fake.callCount, 0)
    }

    /// M15 危險點迴歸:kind round-trip + 舊資料安全(未知 kind 落回 informational 的既有語意不變)。
    func testCommitmentKindRoundTripsInModel() throws {
        let ctx = try makeContext()
        let session = MeetingLiveSession()
        ctx.insert(session)
        let cue = MeetingLiveCue(session: session, text: "寄報告", kind: .commitment)
        cue.status = .converted
        ctx.insert(cue)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<MeetingLiveCue>())
        XCTAssertEqual(fetched[0].kind, .commitment)
        XCTAssertEqual(fetched[0].kindRaw, "commitment")
        XCTAssertEqual(fetched[0].status, .converted)
    }
}
