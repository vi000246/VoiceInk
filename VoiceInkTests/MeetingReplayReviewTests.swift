import XCTest
import SwiftData
@testable import VoiceInk

/// 依**呼叫序**回覆的 LLM fake:第 N 次呼叫回 `replies[N-1]`(超出 → 回最後一則;replies 空 → 空 cue)。
///
/// 為什麼不用既有的 `KeyedFakeChatCompleting`(靠 prompt 內容路由):replay 是**序列**全量抽取,
/// 一段一次呼叫 → 呼叫序 == 段落序,可以直接逐段對稿;靠內容路由反而把測試綁死在段落文字上。
private final class ScriptedChat: ChatCompleting, @unchecked Sendable {
    private let replies: [String]
    private let lock = NSLock()
    private var _callCount = 0

    /// 每次呼叫**回覆前**執行(參數 = 第幾次呼叫,0-based)。取消測試用它在「第一段抽取完成的當下」
    /// 取消 Task —— 這樣 session 與第一段 segment 都已經 persist,刪除路徑才不是空跑。
    var onCall: (@Sendable (Int) -> Void)?

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }

    init(replies: [String]) { self.replies = replies }

    func complete(system: String, user: String) async throws -> String {
        lock.lock()
        let index = _callCount
        _callCount += 1
        lock.unlock()
        onCall?(index)
        guard let last = replies.last else { return #"{"cues":[]}"# }
        return index < replies.count ? replies[index] : last
    }
}

/// 接地 noop(不碰網路/索引/螢幕)。鏡射 `AnswerCoordinatorTests.NoopGrounding`。
private struct ReplayNoopGrounding: MeetingGroundingProviding {
    func gather(query: String, brief: String, includeRAG: Bool, includeScreen: Bool,
                sources: Set<String>?) async -> MeetingGrounding {
        .empty
    }
}

/// 排序用的素 struct(不碰 SwiftData)。`MeetingReviewOrdering.tiers` generic over protocol,
/// 所以純函式測試不必開 in-memory container —— 鏡射 `CopilotOverlayArrangerTests` 的素 struct 測法。
private struct ReviewCueStub: MeetingReviewOrderable {
    let text: String
    let askedAt: Date
    var tier1Opener: String = ""
    var tier2Analysis: String = ""
}

/// 離線覆盤(M8 C 組):AC-39 的分段純函式 + AC-38/AC-42 的 replay 管線。
final class MeetingReplayReviewTests: XCTestCase {

    // MARK: - AC-39 分段策略

    /// 有講者輪次 → 一輪一段、內容為該輪原文(不加「講者N:」前綴),空輪次過濾。
    func testSegmentationPrefersSpeakerTurns() {
        let segs = [
            SpeakerSegment(speaker: "1", text: "你好,先自我介紹一下。", start: 0, end: 3),
            SpeakerSegment(speaker: "2", text: "   ", start: 3, end: 4),   // 空輪次:應被濾掉
            SpeakerSegment(speaker: "2", text: "我是 Logan。", start: 4, end: 6)
        ]
        let units = ReplaySegmentation.segments(text: "整段原文", speakerSegments: segs)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0], "你好,先自我介紹一下。")
        XCTAssertEqual(units[1], "我是 Logan。")
    }

    /// 純文字(無輪次)→ 按句群切多段,且不丟內容(忽略空白差異)。
    func testSegmentationFallsBackToSentenceGroups() {
        let text = "第一句。第二句!第三句?第四句。第五句。第六句。"
        let units = ReplaySegmentation.segments(text: text, speakerSegments: [])
        XCTAssertGreaterThan(units.count, 1, "純文字按句群切多段")
        XCTAssertEqual(strippingWhitespace(units.joined()),
                       strippingWhitespace(text),
                       "不丟內容:所有段串接 == 原文")
    }

    // MARK: - AC-38 replay 管線 + AC-42 重跑並存

    /// AC-38:一份逐字稿 → 一場 replay session(逐段抽取 provenance + cue + 非 informational 跑 Tier 1)。
    /// AC-42:同一份逐字稿再跑一次 → 新 session,舊的原封不動並存(= prompt 調校的 A/B 基礎)。
    ///
    /// **成本紅線也在這裡鎖**:config 的 auto-deep 是**開著**的(正式預設),replay 仍不得碰 deep model。
    @MainActor
    func testReplayBuildsSessionWithCuesAndTier1() async throws {
        let ctx = try makeContext()
        // 三段講者輪次 → 三次抽取呼叫(序列),依序回:aboutMe / informational / 無 cue。
        // 每輪 generateReview 尾端還會多打一次漏抓掃描(Task 14)→ 一輪吃掉 4 則腳本。
        // 兩輪份供 AC-42 的重跑吃(呼叫序繼續往下走)。
        let cueReplies = [
            #"{"cues":[{"text":"自我介紹一下","kind":"aboutMe","searchHint":"自介"}]}"#,
            #"{"cues":[{"text":"我們上週上線了 v2","kind":"informational","searchHint":""}]}"#,
            #"{"cues":[]}"#,
        ]
        let sweepReply = #"{"items":[{"text":"自我介紹一下","suggestedKind":"aboutMe"}]}"#
        let round = cueReplies + [sweepReply]
        let chat = ScriptedChat(replies: round + round)
        let fast = FakeStreamingChatCompleting(script: ["OPENER: 嗨\n- a\n- b\n- c"])
        let deep = FakeStreamingChatCompleting(script: [
            #"{"analysis":"不該跑","followUps":[],"uncertainties":[]}"#
        ])
        let config = makeConfig()
        let coordinator = AnswerCoordinator(
            fast: fast, deep: deep, grounding: ReplayNoopGrounding(), config: config)
        let svc = MeetingReplayReviewService(
            extractorChat: chat, coordinator: coordinator, modelContext: ctx,
            extractionModelLabel: "groq/llama-3.1-8b", config: config)
        let transcription = makeTranscription(in: ctx)

        let session = try await svc.generateReview(for: transcription)

        // 身分:replay 標記 + 與錄音的指紋關聯(錄音詳情頁靠它找到這場覆盤)+ 設定快照(A/B 錨點)。
        XCTAssertEqual(session.sourceRaw, "replay")
        XCTAssertEqual(session.importFingerprint, "fp-1")
        XCTAssertFalse(session.configSnapshotRaw.isEmpty, "覆盤也要留執行設定快照")
        XCTAssertNotNil(session.endedAt, "endedAt nil 會被列表顯示成「進行中」")

        // 分段:一輪一段(native 講者輪次),每段都有抽取 provenance —— 漏抓只能從完整時間軸對照出來。
        let segments = (session.segments ?? []).sorted { $0.committedAt < $1.committedAt }
        XCTAssertEqual(segments.count, 3, "segments 數 == 分段數")
        XCTAssertEqual(segments.map(\.text), speakerTurns)
        XCTAssertTrue(segments.allSatisfy { $0.channel == .remote })
        XCTAssertEqual(segments.map(\.extractedCount), [1, 1, 0])
        XCTAssertTrue(segments.allSatisfy { $0.extractionModel == "groq/llama-3.1-8b" })
        XCTAssertTrue(segments[0].extractionReplyRaw.contains("aboutMe"),
                      "原始回覆要 persist(解析出問題時的唯一線索)")
        XCTAssertTrue(segments.allSatisfy { $0.extractionError.isEmpty })

        let cues = (session.cues ?? []).sorted { $0.askedAt < $1.askedAt }
        XCTAssertEqual(cues.count, 2, "informational 也 persist(FR-11)")
        XCTAssertEqual(cues[0].kind, .aboutMe)
        XCTAssertEqual(cues[0].searchHint, "自介", "searchHint 要跟著 persist(檢索路由用)")
        XCTAssertEqual(cues[0].sourceSegmentId, segments[0].id, "cue → segment 的 provenance")
        XCTAssertTrue(cues[0].contextExcerpt.contains("自我介紹"))
        XCTAssertFalse(cues[0].tier1Opener.isEmpty, "非 informational cue 有 Tier 1")
        XCTAssertFalse(cues[0].tier0Keywords.isEmpty,
                       "Tier 0 是純函式、零 LLM —— replay 也要補,否則 replay/live 的 cue 欄位不可比")

        XCTAssertEqual(cues[1].kind, .informational)
        XCTAssertTrue(cues[1].tier1Opener.isEmpty, "informational cue 不跑 Tier 1")
        XCTAssertTrue(cues[1].tier0Keywords.isEmpty,
                      "informational 不進三層 —— 鏡射 live 的 onNewCue 觸發條件(kind != informational)")

        XCTAssertEqual(chat.callCount, 4, "每段一次抽取呼叫(序列)+ 尾端一次漏抓掃描")
        XCTAssertEqual(fast.callCount, 1, "Tier 1 只跑非 informational 的那一則")
        XCTAssertEqual(deep.callCount, 0, "replay 不得觸發 deep model(成本)——即使 auto-deep 開著")
        XCTAssertNil(svc.progress, "跑完歸零,不留下卡住的進度條")

        // AC-42:重跑並存。
        let again = try await svc.generateReview(for: transcription)
        XCTAssertNotEqual(again.id, session.id, "重跑 = 新 session")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSession>()).count, 2,
                       "舊覆盤不被覆蓋(同一錄音的多次 replay 並存 = A/B 對照)")
        XCTAssertEqual((again.cues ?? []).count, 2, "第二次是完整獨立的覆盤")
        XCTAssertEqual((session.cues ?? []).count, 2, "第一次的 cue 沒被搬走/刪掉")
        XCTAssertEqual(deep.callCount, 0)
    }

    /// 取消 → **不留半套**:已建立的 session(含 cascade 的 segment/cue)整場刪掉,錯誤往外拋。
    /// 半套的覆盤比沒有更糟——它看起來像「這段逐字稿只有 N 則 cue」,實際是跑到一半被中斷,
    /// 而事後沒有任何欄位分得出這兩件事,調校時會把「中斷」誤讀成「抽取漏抓」。
    @MainActor
    func testCancelledReplayLeavesNoPartialSession() async throws {
        let ctx = try makeContext()
        let chat = ScriptedChat(replies: [
            #"{"cues":[{"text":"自我介紹一下","kind":"aboutMe","searchHint":"自介"}]}"#
        ])
        let svc = MeetingReplayReviewService(
            extractorChat: chat, coordinator: nil, modelContext: ctx, config: makeConfig())
        let transcription = makeTranscription(in: ctx)

        // Task body 要等我們讓出 main actor 才會開跑 → onCall 必然在它之前掛好。
        // 在第一段抽取**完成的當下**取消:此刻 session 與第一段 segment 都已 insert+save,
        // 所以走到的是「已建立 → 取消 → 整場刪掉」那條路,不是空跑。
        let task = Task { try await svc.generateReview(for: transcription) }
        chat.onCall = { index in if index == 0 { task.cancel() } }

        do {
            _ = try await task.value
            XCTFail("取消後 generateReview 必須 rethrow")
        } catch is CancellationError {
            // 預期
        }

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSession>()).count, 0,
                       "半套 session 必須刪掉")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSegment>()).count, 0,
                       "cascade:已 persist 的段落一併清掉")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0)
        XCTAssertEqual(chat.callCount, 1, "取消後不再打第二段的 LLM")
        XCTAssertNil(svc.progress)
    }

    // MARK: - AC-40 漏抓掃描(miss sweep)

    /// 掃描結果只留「未被即時抽取匹配到」的項目 —— 漏抓清單裡混進已抓到的題目就是雜訊,
    /// 調校時會照著一個假的漏抓率改 prompt。
    ///
    /// 注意匹配用的是**改寫過的問法**(「請自我介紹」vs 已抓到的「自我介紹一下」):sweep 的 item
    /// 出自另一次 LLM 呼叫,措辭與長度都不會與 live 抽到的原句一致 —— 匹配必須吃得下這種落差。
    func testSweepKeepsOnlyUnmatched() {
        let existing = ["你對X專案有什麼貢獻", "怎麼設計快取", "自我介紹一下"]
        let sweepItems = [
            SweepItem(text: "你對 X 專案有什麼貢獻?", suggestedKind: "aboutMe"),              // 與 [0] 匹配
            SweepItem(text: "請自我介紹", suggestedKind: "aboutMe"),                          // 與 [2] 匹配
            SweepItem(text: "預期的上線時程是什麼時候", suggestedKind: "directQuestion"),      // 漏抓
            SweepItem(text: "快取要怎麼設計", suggestedKind: "directQuestion"),                // 與 [1] 匹配
            SweepItem(text: "團隊規模多大", suggestedKind: "informational")]                   // 漏抓
        let missed = MeetingReviewSweep.unmatched(sweep: sweepItems, existingCueTexts: existing)
        XCTAssertEqual(missed.map(\.text), ["預期的上線時程是什麼時候", "團隊規模多大"])
        XCTAssertEqual(missed.map(\.suggestedKind), ["directQuestion", "informational"],
                       "建議分類要跟著留下 —— 它是「該歸哪類卻沒抓到」的調校線索")
    }

    /// sweep 的**價值就在於沒有主題過濾**:正式抽取 prompt 會把非技術問題壓成 informational,
    /// 掃描器若沿用同一套過濾,就只會回報「抽取已經抓到的東西」,永遠掃不出漏抓。
    func testSweepPromptIsGenericNoTopicFilter() {
        let p = MeetingReviewSweep.systemPrompt
        XCTAssertTrue(p.contains("所有"))
        XCTAssertFalse(p.contains("技術"), "sweep 不帶主題過濾——這正是它與正式抽取的差異")
    }

    /// 容錯鏡射 `ResponseCueExtractor.parse`:code fence 剝掉照解;壞字串回 [](不 throw、不當機)。
    func testSweepParseToleratesCodeFenceAndGarbage() {
        let fenced = """
        ```json
        {"items":[{"text":"團隊規模多大","suggestedKind":"informational"}]}
        ```
        """
        XCTAssertEqual(MeetingReviewSweep.parse(fenced),
                       [SweepItem(text: "團隊規模多大", suggestedKind: "informational")])
        XCTAssertEqual(MeetingReviewSweep.parse("抱歉,我無法處理"), [])
        XCTAssertEqual(MeetingReviewSweep.decode("{壞掉的 JSON"), [])
    }

    /// AC-40 整合:`generateReview` 尾端自動跑 sweep,未匹配項 persist 到 `reviewSweepRaw`。
    /// 這裡刻意讓即時抽取「只抓到一題」,sweep 卻列出三題 —— 落差正是覆盤要交付的東西。
    @MainActor
    func testGenerateReviewRunsSweepAndPersists() async throws {
        let ctx = try makeContext()
        // 三段 → 三次抽取:只在第一段抽到一則 cue,後兩段空手(= 即時管線漏了東西)。
        let cueReplies = [
            #"{"cues":[{"text":"先自我介紹一下你的經歷","kind":"aboutMe","searchHint":"自介"}]}"#,
            #"{"cues":[]}"#,
            #"{"cues":[]}"#,
        ]
        // 第四次呼叫 = 漏抓掃描(無主題過濾,寧可多列):三題,其中第一題是已抓到的那題的改寫。
        let sweepReply = """
        {"items":[
          {"text":"請自我介紹","suggestedKind":"aboutMe"},
          {"text":"預期的上線時程是什麼時候","suggestedKind":"directQuestion"},
          {"text":"團隊規模多大","suggestedKind":"informational"}
        ]}
        """
        let chat = ScriptedChat(replies: cueReplies + [sweepReply])
        // coordinator = nil:本測試只驗掃描,不必燒 Tier 1 的 fake(抽取/掃描的呼叫序才不被干擾)。
        let svc = MeetingReplayReviewService(
            extractorChat: chat, coordinator: nil, modelContext: ctx, config: makeConfig())
        let transcription = makeTranscription(in: ctx)

        let session = try await svc.generateReview(for: transcription)

        XCTAssertEqual(chat.callCount, 4, "三段抽取 + 尾端一次全文漏抓掃描(同一顆 fast model)")
        XCTAssertFalse(session.reviewSweepRaw.isEmpty, "掃描結果要 persist(空字串 = 尚未掃描)")

        let missed = MeetingReviewSweep.decode(session.reviewSweepRaw)
        XCTAssertEqual(missed.map(\.text), ["預期的上線時程是什麼時候", "團隊規模多大"],
                       "已被即時抽取到的那題(改寫問法)不算漏抓")
        XCTAssertEqual(missed.map(\.suggestedKind), ["directQuestion", "informational"])
        XCTAssertNil(svc.progress, "sweep 也算進分母 —— 跑完歸零,不停在 99%")
    }

    /// sweep 失敗必須**靜默**:覆盤主體(cue/segment/Tier 1)已經成立,不能因為掃描打不通就整場作廢。
    @MainActor
    func testSweepFailureLeavesReviewIntact() async throws {
        let ctx = try makeContext()
        let chat = ScriptedChat(replies: [
            #"{"cues":[{"text":"先自我介紹一下你的經歷","kind":"aboutMe","searchHint":"自介"}]}"#,
            #"{"cues":[]}"#,
            #"{"cues":[]}"#,
            "我不知道怎麼回答",   // 掃描回了無法解析的東西 → 視為失敗
        ])
        let svc = MeetingReplayReviewService(
            extractorChat: chat, coordinator: nil, modelContext: ctx, config: makeConfig())

        let session = try await svc.generateReview(for: makeTranscription(in: ctx))

        XCTAssertEqual((session.cues ?? []).count, 1, "掃描失敗不影響覆盤主體")
        XCTAssertEqual((session.segments ?? []).count, 3)
        XCTAssertTrue(session.reviewSweepRaw.isEmpty,
                      "解析不出東西 ≠ 零漏抓 —— 寧可留空(UI 顯示補跑按鈕),不要謊報「沒有漏抓」")
    }

    // MARK: - AC-41 覆盤三層排序

    /// 覆盤詳情分兩層:**有回應**(tier1 開口稿 或 tier2 分析,任一有內容)/ **未回應**(informational、
    /// tier1 失敗)。層內依 `askedAt` 升冪 —— 覆盤是回顧,照會議時間讀,不是 overlay 的「最新優先」。
    ///
    /// 判準寫死在純函式內(不是呼叫端傳的 closure):這條判準**就是**本測試要鎖的東西,
    /// 交給呼叫端傳就變成「測試在驗自己寫的 closure」,view 大可用另一套判準而測試照樣綠。
    func testReviewOrderingThreeTiers() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let answered = ReviewCueStub(text: "有回應", askedAt: t0, tier1Opener: "OPENER")
        let info = ReviewCueStub(text: "資訊", askedAt: t0.addingTimeInterval(-10))
        let failed = ReviewCueStub(text: "tier1失敗", askedAt: t0.addingTimeInterval(5))
        // tier1 失敗但 deep 成功(Tier 2 直出)→ 仍算「有回應」:判準是 `||`,不是只看 tier1。
        let deepOnly = ReviewCueStub(text: "只有深度分析", askedAt: t0.addingTimeInterval(20),
                                     tier2Analysis: "分析內容")

        let groups = MeetingReviewOrdering.tiers(cues: [failed, deepOnly, info, answered])

        XCTAssertEqual(groups.responded.map(\.text), ["有回應", "只有深度分析"], "層內依 askedAt 升冪")
        XCTAssertEqual(groups.unresponded.map(\.text), ["資訊", "tier1失敗"], "層內依 askedAt 升冪")
    }

    // MARK: - helpers

    private func strippingWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// Transcription(default.store)與 MeetingLive*(meeting.store)正式是兩個 store,
    /// 但測試只需要「同一個 in-memory container 含兩邊 schema」——store 分檔是 migration 的隔離手段,
    /// 與本測試要驗的接線無關。
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self, MeetingLiveSegment.self,
            Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private let speakerTurns = ["先自我介紹一下你的經歷。", "我們上週上線了 v2。", "好的,謝謝。"]

    /// 有 **native** 講者輪次的逐字稿 = replay 的主路徑(一輪一段,分段數確定)。
    private func makeTranscription(in ctx: ModelContext) -> Transcription {
        let t = Transcription(
            text: speakerTurns.joined(), duration: 300, importFingerprint: "fp-1")
        t.speakerSegments = speakerTurns.enumerated().map { i, text in
            SpeakerSegment(speaker: i == 1 ? "2" : "1", text: text,
                           start: Double(i) * 5, end: Double(i + 1) * 5)
        }
        t.speakerSegmentsAreNative = true
        ctx.insert(t)
        try? ctx.save()
        return t
    }

    /// auto-deep **開著**(= 正式預設)。replay 仍不得碰 deep model —— 用「全域開啟」的設定測才有意義。
    @MainActor
    private func makeConfig() -> MeetingCopilotConfigStore {
        let c = MeetingCopilotConfigStore()
        c.setPrefetchEnabled(true)
        c.setAutoDeepEnabled(true)
        c.setUseHistoryRAG(false)
        c.setUseNotesRAG(false)
        c.setNotesInTechnicalRAG(false)
        c.setUseScreenContext(false)
        return c
    }
}
