import XCTest
import SwiftData
@testable import VoiceInk

/// 腳本化 LLM fake:依**原文內容**路由回覆,可指定人為延遲與第 N 次呼叫拋錯。
///
/// 為什麼不依呼叫序(既有 `MeetingReplayReviewTests.ScriptedChat` 的做法):翻譯是
/// **並行**的——兩段的 Task 幾乎同時進 `complete`,而 `complete` 是 nonisolated async
/// (會跳離 MainActor 到 global executor),誰先拿到號碼牌由排程決定。用呼叫序綁腳本,
/// 「延遲 0.2s 的那份」會偶爾發給第二段,ordering 斷言就隨機紅燈——那測到的是 executor
/// 排程,不是 `insertSorted`。依內容路由則與排程無關,腳本永遠跟著它該跟的那一段。
private final class ScriptedChat: ChatCompleting, @unchecked Sendable {

    struct StubError: Error {}

    /// 一次呼叫的腳本。`delay` 用來人為製造「後說的短句先譯完」的亂序完成。
    struct Step {
        var reply: String
        var delay: TimeInterval = 0
    }

    /// key = user prompt(`MeetingTranslationPrompt.build` 的 user 就是原文本身)。
    private let routes: [String: Step]
    /// 第 N 次呼叫(1-based)拋錯;0 = 不拋。
    private let throwOnCall: Int
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    init(routes: [String: Step] = [:], throwOnCall: Int = 0) {
        self.routes = routes
        self.throwOnCall = throwOnCall
    }

    func complete(system: String, user: String) async throws -> String {
        lock.lock(); _callCount += 1; let n = _callCount; lock.unlock()
        let step = routes[user]
        if let delay = step?.delay, delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if n == throwOnCall { throw StubError() }
        return step?.reply ?? ""
    }
}

/// 即時字幕翻譯(M8 D 組)。
///
/// 本檔的 golden test 鎖住翻譯 prompt 的三個核心指示——混語照譯、同語言原樣輸出、
/// 只輸出譯文。這三句就是翻譯品質的全部:任何一句被改掉,字幕就會開始出現
/// 「這句話的意思是…」之類的解釋文、或把已經是中文的句子硬翻一次(AC-45)。
///
/// 另一半是 `MeetingLiveTranslator` 的管線行為(AC-43/44/47):有序 feed、靜默容錯、關閉零呼叫。
final class MeetingTranslationTests: XCTestCase {

    /// 翻譯開關是 UserDefaults 全域狀態——測試改了要還原,否則污染同 process 的其他測試類。
    private let keys = ["meetingCopilotLiveTranslationV1"]
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

    // MARK: - AC-45:翻譯 prompt(純函式)

    /// source="auto"(混語會議的預設):prompt 不假設輸入語言,且要求同語言原樣輸出。
    func testPromptAutoDetectAndSameLanguagePassthrough() {
        let (system, user) = MeetingTranslationPrompt.build(
            text: "Let's discuss the cache design.", sourceLanguage: "auto", targetLanguage: "zh-TW")
        XCTAssertTrue(system.contains("無論輸入"), "混語(中英夾雜)會議:不可假設輸入語言")
        XCTAssertTrue(system.contains("繁體中文"), "目標語言要以人類看得懂的語言名出現")
        XCTAssertTrue(system.contains("原樣輸出"), "已是目標語言 → 不要硬翻")
        XCTAssertTrue(system.contains("只輸出"), "不要解釋、不要引號、不要標註語言")
        XCTAssertTrue(user.contains("cache design"), "user = 原文本身")
    }

    /// 明確指定來源語言時,prompt 要帶上來源提示(auto 時不帶)。
    func testPromptCarriesExplicitSourceHint() {
        let (system, _) = MeetingTranslationPrompt.build(
            text: "x", sourceLanguage: "en", targetLanguage: "zh-TW")
        XCTAssertTrue(system.contains("en"), "指定 source 時 prompt 要帶來源語言提示")
    }

    /// 語言碼 → 人類語言名;未知碼原樣返回(不崩、不硬轉)。
    func testTargetLanguageDisplayName() {
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "zh-TW"), "繁體中文")
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "zh-CN"), "简体中文")
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "en"), "English")
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "ja"), "日本語")
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "xx-YY"), "xx-YY", "未知碼原樣返回")
    }

    // MARK: - AC-43:feed 按 committedAt,不按完成序

    /// 第一段慢(0.2s)、第二段快(0s)→ **完成序與說話序相反**。
    /// 譯文各自回到自己的 segment,feed 仍按 committedAt 排——這正是字幕不跳動的保證。
    @MainActor
    func testTranslationWritesBackInCommittedOrder() async throws {
        let ctx = try makeContext()
        let t0 = Date()
        let chat = ScriptedChat(routes: [
            "one": ScriptedChat.Step(reply: "譯一", delay: 0.2),   // 先說、後譯完
            "two": ScriptedChat.Step(reply: "譯二", delay: 0),     // 後說、先譯完
        ])
        let translator = MeetingLiveTranslator(chat: chat, config: makeConfig(enabled: true))

        let s1 = makeSegment(ctx, text: "one", committedAt: t0)
        let s2 = makeSegment(ctx, text: "two", committedAt: t0.addingTimeInterval(1))
        translator.translate(segment: s1)
        translator.translate(segment: s2)
        await translator.drainForTest()

        XCTAssertEqual(chat.callCount, 2, "每段一次呼叫(與 cue 抽取平行,不是取代)")
        XCTAssertEqual(s1.translatedText, "譯一", "譯文 persist 回 segment(覆盤要雙語對照)")
        XCTAssertEqual(s2.translatedText, "譯二")
        XCTAssertEqual(translator.feed.map(\.translated), ["譯一", "譯二"],
                       "按 committedAt,不按完成序——短句先譯完就插隊的話,字幕會跳來跳去")
        XCTAssertEqual(translator.feed.map(\.id), [s1.id, s2.id])
        XCTAssertTrue(s1.translationError.isEmpty)
        XCTAssertGreaterThan(s1.translationElapsedMs, 0, "耗時是調校訊號(翻譯跟不跟得上說話速度)")
    }

    // MARK: - AC-44:失敗靜默,字幕顯示原文

    /// 翻譯呼叫失敗 → feed 仍有這一行、內容是**原文**(空白字幕比沒翻譯更糟),
    /// 錯誤只留在 segment(不跳 UI、不中斷後續段落)。
    @MainActor
    func testTranslationFailureShowsOriginalSilently() async throws {
        let ctx = try makeContext()
        let chat = ScriptedChat(throwOnCall: 1)
        let translator = MeetingLiveTranslator(chat: chat, config: makeConfig(enabled: true))

        let seg = makeSegment(ctx, text: "原文", committedAt: Date())
        translator.translate(segment: seg)
        await translator.drainForTest()

        XCTAssertEqual(chat.callCount, 1)
        XCTAssertEqual(translator.feed.count, 1, "失敗的段落仍要上字幕(缺行 = 字幕斷掉)")
        XCTAssertEqual(translator.feed.first?.translated, "原文", "失敗顯示原文")
        XCTAssertFalse(seg.translationError.isEmpty, "線索只留在 segment(靜默容錯的紀律)")
        XCTAssertTrue(seg.translatedText.isEmpty, "失敗不得寫進譯文欄(覆盤要分得出成功/失敗)")
    }

    // MARK: - AC-47:關閉 = 零 API 呼叫

    /// 硬需求:翻譯關閉時連一次 LLM 都不能打(這是每段一次的額外成本,單語會議純屬浪費)。
    @MainActor
    func testDisabledMakesZeroCalls() async throws {
        let ctx = try makeContext()
        let chat = ScriptedChat(routes: ["t": ScriptedChat.Step(reply: "x")])
        let translator = MeetingLiveTranslator(chat: chat, config: makeConfig(enabled: false))

        translator.translate(segment: makeSegment(ctx, text: "t", committedAt: Date()))
        await translator.drainForTest()

        XCTAssertEqual(chat.callCount, 0, "AC-47:翻譯關閉 → 零 API 呼叫")
        XCTAssertTrue(translator.feed.isEmpty)
    }

    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self, MeetingLiveSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// insert 進 context → `segment.modelContext` 非 nil,translator 才 save 得回去。
    private func makeSegment(_ ctx: ModelContext, text: String, committedAt: Date) -> MeetingLiveSegment {
        let seg = MeetingLiveSegment(session: nil, channel: .remote, text: text, committedAt: committedAt)
        ctx.insert(seg)
        try? ctx.save()
        return seg
    }

    @MainActor
    private func makeConfig(enabled: Bool) -> MeetingCopilotConfigStore {
        let config = MeetingCopilotConfigStore()
        config.setLiveTranslationEnabled(enabled)
        return config
    }
}
