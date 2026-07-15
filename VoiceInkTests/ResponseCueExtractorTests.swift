import XCTest
@testable import VoiceInk

// MARK: - 共用 fakes(鏡射 AskAIAnswerTests.FixedCompleter;非 private——
//         MeetingCopilotControllerTests / MeetingCueDetectionReplayTests 共用)

/// 固定回覆 + 呼叫記錄的 LLM fake。
final class FakeChatCompleting: ChatCompleting, @unchecked Sendable {
    struct StubError: Error {}
    private let reply: String
    private let shouldThrow: Bool
    private let lock = NSLock()
    private var systems: [String] = []
    private var users: [String] = []

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return users.count }
    var lastUser: String? { lock.lock(); defer { lock.unlock() }; return users.last }
    var lastSystem: String? { lock.lock(); defer { lock.unlock() }; return systems.last }

    init(reply: String = #"{"cues":[]}"#, shouldThrow: Bool = false) {
        self.reply = reply
        self.shouldThrow = shouldThrow
    }

    func complete(system: String, user: String) async throws -> String {
        lock.lock(); systems.append(system); users.append(user); lock.unlock()
        if shouldThrow { throw StubError() }
        return reply
    }
}

/// 依 user prompt 內容路由回覆的 LLM fake(多段 committed 的測試不吃時序)。
final class KeyedFakeChatCompleting: ChatCompleting, @unchecked Sendable {
    private let routes: [(contains: String, json: String)]
    private let lock = NSLock()
    private var count = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(routes: [(contains: String, json: String)]) { self.routes = routes }

    func complete(system: String, user: String) async throws -> String {
        lock.lock(); count += 1; lock.unlock()
        for r in routes where user.contains(r.contains) { return r.json }
        return #"{"cues":[]}"#
    }
}

// MARK: - Tests

final class ResponseCueExtractorTests: XCTestCase {

    /// AC-3:prompt 純函式——同輸入同輸出,含四分類定義,不讀 UserDefaults/不發網路。
    func testPromptIsPureAndDeterministic() {
        let a = ResponseCueExtractor.buildPrompt(
            committed: "我對這個寫入效能有點擔心", recentContext: "先前在討論 schema")
        let b = ResponseCueExtractor.buildPrompt(
            committed: "我對這個寫入效能有點擔心", recentContext: "先前在討論 schema")
        XCTAssertEqual(a.system, b.system)
        XCTAssertEqual(a.user, b.user)

        for kind in MeetingCueKind.allCases {
            XCTAssertTrue(a.system.contains(kind.rawValue), "system prompt 缺 \(kind.rawValue) 定義")
        }
        XCTAssertTrue(a.system.contains("不要只靠問號"), "必須明示陳述句質疑不可漏(umbrella AC-4)")
        XCTAssertTrue(a.user.contains("我對這個寫入效能有點擔心"))
        XCTAssertTrue(a.user.contains("先前在討論 schema"))
    }

    /// AC-1(realizes umbrella AC-4):三句 → 三 cue,陳述句質疑(無問號)不得漏。
    /// fake 回腳本化 JSON——這裡鎖的是 extract→parse→分類的管線;
    /// 真實 fast model 的行為由 Task 8 的 DEBUG 人工驗證把關。
    func testDetectsStatementFormChallenge() async {
        let json = """
        {"cues":[
          {"text":"你會怎麼設計一個短網址服務？","kind":"directQuestion"},
          {"text":"我對這個寫入效能有點擔心","kind":"impliedChallenge"},
          {"text":"我們上週上線了 v2","kind":"informational"}
        ]}
        """
        let extractor = ResponseCueExtractor(chat: FakeChatCompleting(reply: json))
        let outcome = await extractor.extract(
            committed: "你會怎麼設計一個短網址服務？我對這個寫入效能有點擔心。我們上週上線了 v2。")
        let cues = outcome.cues

        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].kind, .directQuestion)
        XCTAssertEqual(cues[1].kind, .impliedChallenge, "陳述句質疑(無問號)必須被偵測")
        XCTAssertEqual(cues[1].text, "我對這個寫入效能有點擔心")
        XCTAssertEqual(cues[2].kind, .informational)

        // 觀測資料:原始回覆完整保留(誤抓/錯分類的覆盤線索),成功時無錯誤。
        XCTAssertEqual(outcome.rawReply, json)
        XCTAssertTrue(outcome.errorDescription.isEmpty)
    }

    /// AC-2:抽取+四分類 = 恰一次呼叫(單趟非串流,未分兩趟)。
    func testExtractionIsSingleNonStreamingCall() async {
        let fake = FakeChatCompleting(
            reply: #"{"cues":[{"text":"x?","kind":"directQuestion"}]}"#)
        let extractor = ResponseCueExtractor(chat: fake)
        _ = await extractor.extract(committed: "x?")
        XCTAssertEqual(fake.callCount, 1, "抽取與四分類必須合併為單次 completeChat")
    }

    /// 靜默容錯:LLM throw → 空 cues(不 throw、不跳 UI);失敗原因留在 outcome 供覆盤。
    func testLLMFailureReturnsEmpty() async {
        let extractor = ResponseCueExtractor(chat: FakeChatCompleting(shouldThrow: true))
        let outcome = await extractor.extract(committed: "任何話")
        XCTAssertTrue(outcome.cues.isEmpty)
        XCTAssertFalse(outcome.errorDescription.isEmpty, "失敗原因必須留下(→ segment.extractionError)")
        XCTAssertTrue(outcome.rawReply.isEmpty)
    }

    /// JSON 契約 golden:欄位名 text/kind、envelope key cues——鎖定,M3 依賴此契約。
    func testGoldenJSONContract() {
        let golden = #"{"cues":[{"text":"這塊 Logan 你來說明一下","kind":"assignedToMe"}]}"#
        let parsed = ResponseCueExtractor.parse(golden)
        XCTAssertEqual(parsed, [ExtractedCue(text: "這塊 Logan 你來說明一下", kind: .assignedToMe)])
    }

    /// M8 AC-31:aboutMe cue 帶 searchHint(fast model 把問題改寫成筆記檢索詞)。
    func testParseAboutMeWithSearchHint() {
        let raw = #"{"cues":[{"text":"你對X專案有什麼貢獻？","kind":"aboutMe","searchHint":"X專案 貢獻 成果"}]}"#
        let cues = ResponseCueExtractor.parse(raw)
        XCTAssertEqual(cues, [ExtractedCue(text: "你對X專案有什麼貢獻？", kind: .aboutMe,
                                           searchHint: "X專案 貢獻 成果")])
    }

    /// searchHint 缺漏(模型省略欄位)→ 預設空字串,整則 cue 不得因此丟棄。
    func testParseMissingSearchHintDefaultsEmpty() {
        let raw = #"{"cues":[{"text":"你會怎麼設計快取？","kind":"directQuestion"}]}"#
        XCTAssertEqual(ResponseCueExtractor.parse(raw).first?.searchHint, "")
    }

    /// M8 golden:五分類 prompt 必含 aboutMe 判準關鍵詞與 searchHint 契約。
    func testSystemPromptCoversFiveKindsAndReviewExamples() {
        let p = ResponseCueExtractor.systemPrompt
        XCTAssertTrue(p.contains("aboutMe"))
        XCTAssertTrue(p.contains("貢獻"))       // 績效考核正例必須在 prompt 裡
        XCTAssertTrue(p.contains("自我介紹"))   // 從 informational 搬到 aboutMe 的關鍵例
        XCTAssertTrue(p.contains("searchHint"))
    }

    /// 解析容錯:壞 JSON / 未知 kind / 空 text / markdown fence。
    func testParseToleratesGarbage() {
        XCTAssertEqual(ResponseCueExtractor.parse("這不是 JSON"), [])
        XCTAssertEqual(ResponseCueExtractor.parse(#"{"cues":[{"text":"x","kind":"notAKind"}]}"#), [],
                       "未知 kind 整則丟棄")
        XCTAssertEqual(ResponseCueExtractor.parse(#"{"cues":[{"text":"  ","kind":"directQuestion"}]}"#), [],
                       "空 text 丟棄")
        let fenced = """
        ```json
        {"cues":[{"text":"x?","kind":"directQuestion"}]}
        ```
        """
        XCTAssertEqual(ResponseCueExtractor.parse(fenced),
                       [ExtractedCue(text: "x?", kind: .directQuestion)],
                       "模型包 code fence 要能剝掉")
    }

    // MARK: - 抽取前守門(2026-07-15 碎片誤判事故)

    /// 連續語音被切碎的英文殘尾以小寫開頭 → 擋掉,不送 LLM 腦補成問題。
    func testGateBlocksLowercaseLatinFragments() {
        XCTAssertFalse(ResponseCueExtractor.isExtractable("e conflict."))
        XCTAssertFalse(ResponseCueExtractor.isExtractable("utes."))
        XCTAssertFalse(ResponseCueExtractor.isExtractable("ile the diplomatic efforts"))
    }

    /// 純標點/空白(切段接縫殘渣)→ 擋掉。
    func testGateBlocksPunctuationOnly() {
        XCTAssertFalse(ResponseCueExtractor.isExtractable("..."))
        XCTAssertFalse(ResponseCueExtractor.isExtractable("   "))
        XCTAssertFalse(ResponseCueExtractor.isExtractable("—— "))
    }

    /// 完整句子放行:CJK 短句(無大小寫)、大寫開頭英文、數字開頭都是合法輸入。
    func testGateAllowsCompleteUtterances() {
        XCTAssertTrue(ResponseCueExtractor.isExtractable("你負責哪一塊?"))
        XCTAssertTrue(ResponseCueExtractor.isExtractable("How would you design it?"))
        XCTAssertTrue(ResponseCueExtractor.isExtractable("3 個服務怎麼拆?"))
        XCTAssertTrue(ResponseCueExtractor.isExtractable("Redis 快取要怎麼設計?"))
    }

    /// 反腦補:cue.text 必須確實出自 committed;模型虛構(committed 裡沒有)→ 丟棄。
    func testGroundingRejectsHallucinatedCue() {
        let committed = "我們上週把服務上線了"
        XCTAssertTrue(ResponseCueExtractor.isGrounded("我們上週把服務上線了", in: committed))
        XCTAssertFalse(ResponseCueExtractor.isGrounded("你最有成就感的專案是什麼?", in: committed),
                       "committed 裡完全沒有的內容 = 腦補,應丟棄")
        XCTAssertFalse(ResponseCueExtractor.isGrounded("a", in: committed), "過短丟棄")
    }

    /// grounded 過濾實際生效:模型回一則出自 committed、一則虛構 → 只留前者。
    func testExtractFiltersUngroundedCues() async {
        let reply = #"{"cues":[{"text":"你會怎麼設計 rate limiter","kind":"directQuestion"},{"text":"完全無關的虛構問題","kind":"aboutMe"}]}"#
        let extractor = ResponseCueExtractor(chat: FakeChatCompleting(reply: reply))
        let outcome = await extractor.extract(committed: "你會怎麼設計 rate limiter")
        XCTAssertEqual(outcome.cues.map(\.text), ["你會怎麼設計 rate limiter"],
                       "只留確實出自 committed 的 cue,虛構的丟棄")
        XCTAssertEqual(outcome.rawReply, reply, "rawReply 保留原樣供診斷比對")
    }

    // MARK: - 分類器 prompt 覆寫(2026-07-15 可調 prompt)

    /// 建構時注入的 systemPrompt 覆寫要真的送到 LLM;不傳(或空)則用內建預設。
    func testSystemPromptOverrideIsSentToLLM() async {
        let fake = FakeChatCompleting(reply: #"{"cues":[]}"#)
        let extractor = ResponseCueExtractor(chat: fake, systemPrompt: "我的自訂分類器 prompt")
        _ = await extractor.extract(committed: "你好")
        XCTAssertEqual(fake.lastSystem, "我的自訂分類器 prompt", "覆寫的 system prompt 應原樣送出")

        let fakeDefault = FakeChatCompleting(reply: #"{"cues":[]}"#)
        let defaultExtractor = ResponseCueExtractor(chat: fakeDefault)   // 不傳 → 內建
        _ = await defaultExtractor.extract(committed: "你好")
        XCTAssertEqual(fakeDefault.lastSystem, ResponseCueExtractor.systemPrompt, "未覆寫 → 內建分類器 prompt")
    }
}
