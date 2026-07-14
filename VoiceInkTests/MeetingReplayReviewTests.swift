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
        // 後三則供 AC-42 的重跑吃(呼叫序繼續往下走)。
        let cueReplies = [
            #"{"cues":[{"text":"自我介紹一下","kind":"aboutMe","searchHint":"自介"}]}"#,
            #"{"cues":[{"text":"我們上週上線了 v2","kind":"informational","searchHint":""}]}"#,
            #"{"cues":[]}"#,
        ]
        let chat = ScriptedChat(replies: cueReplies + cueReplies)
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

        XCTAssertEqual(cues[1].kind, .informational)
        XCTAssertTrue(cues[1].tier1Opener.isEmpty, "informational cue 不跑 Tier 1")

        XCTAssertEqual(chat.callCount, 3, "每段一次抽取呼叫(序列)")
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
