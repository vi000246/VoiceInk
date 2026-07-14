import XCTest
import SwiftData
@testable import VoiceInk

/// M9 覆盤生命週期共用 in-memory container（房子風格：MeetingLiveModelsTests.makeContext）。
/// 刻意把 `Transcription` 與 meeting 三 model 放進**同一個** container——正式環境 mainContext
/// 同時涵蓋 default.store 與 meeting.store，reconciler 才能在單一 ModelContext 內比對指紋。
@MainActor
func makeInMemoryMeetingContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: MeetingLiveSession.self, MeetingLiveCue.self, MeetingLiveSegment.self,
        Transcription.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return ModelContext(container)
}

struct WaitUntilTimeout: Error {}

/// 輪詢至條件成立。背景佇列跑在自己的 `Task` 裡，**沒有可以 await 的 handle**；用
/// `XCTestExpectation` 就得把 fulfil 埋進生產程式碼（為了測試而開的後門）。輪詢只讀
/// 公開狀態，測到的東西跟 UI 看到的完全同一份。逾時直接 `XCTFail` 並丟出——不 fail 的
/// 話呼叫端會繼續往下斷言，錯誤訊息會指向下一行，離真正的原因很遠。
@MainActor
func waitUntil(
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 2_000_000)   // 2ms
    }
    XCTFail("waitUntil 逾時（\(timeout)s）條件未成立", file: file, line: line)
    throw WaitUntilTimeout()
}

@MainActor
final class MeetingReplayQueueTests: XCTestCase {

    /// AC-53：X 的 live＋replay 全刪；Y 與空 fingerprint 不動；cue cascade。
    func testReconcileDeletesAllSessionsOfDeletedRecording() throws {
        let ctx = try makeInMemoryMeetingContext()
        let keepT = Transcription(text: "y", duration: 1)
        keepT.importFingerprint = "Y"
        ctx.insert(keepT)   // X 的錄音「不存在」＝已被刪

        let liveX = MeetingLiveSession()
        liveX.importFingerprint = "X"
        liveX.sourceRaw = "live"
        let replayX = MeetingLiveSession()
        replayX.importFingerprint = "X"
        replayX.sourceRaw = "replay"
        let sessionY = MeetingLiveSession()
        sessionY.importFingerprint = "Y"
        let legacy = MeetingLiveSession()   // fingerprint = ""（未關聯）
        [liveX, replayX, sessionY, legacy].forEach { ctx.insert($0) }
        ctx.insert(MeetingLiveCue(session: liveX, text: "q", kind: .directQuestion,
                                  askedAt: Date(), contextExcerpt: ""))
        try ctx.save()

        // shared 是 bootstrap 專用；測試一律用新實例，避免跨測試污染。
        let reconciler = MeetingSessionReconciler()
        reconciler.configure(modelContext: ctx)
        reconciler.reconcile()

        let remaining = try ctx.fetch(FetchDescriptor<MeetingLiveSession>())
        XCTAssertEqual(Set(remaining.map(\.importFingerprint)), ["Y", ""],
                       "X 全刪（live＋replay）；Y 與空 fingerprint 不動")
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).isEmpty,
                      "cue 由 @Relationship cascade 帶走")
    }

    /// AC-54：有 live → 只能查看；無 live 有 replay → 查看＋重新產生；皆無 → 產生。
    func testReviewButtonTriState() {
        let live = (id: UUID(), sourceRaw: "live", startedAt: Date())
        let replay = (id: UUID(), sourceRaw: "replay", startedAt: Date().addingTimeInterval(60))

        switch CopilotReviewButtons.state(sessions: [(live.id, live.sourceRaw, live.startedAt),
                                                     (replay.id, replay.sourceRaw, replay.startedAt)]) {
        case .viewOnly(let id): XCTAssertEqual(id, replay.id, "查看開最新那場")
        default: XCTFail("有 live → viewOnly")
        }

        switch CopilotReviewButtons.state(sessions: [(replay.id, replay.sourceRaw, replay.startedAt)]) {
        case .viewAndRegenerate(let id): XCTAssertEqual(id, replay.id)
        default: XCTFail("只有 replay → 可重新產生（A/B 保留）")
        }

        if case .generate = CopilotReviewButtons.state(sessions: []) {} else { XCTFail("皆無 → 產生") }
    }

    /// AC-55＋AC-57：重複 enqueue 是 no-op；兩筆不同錄音 FIFO **序列**跑（一次一場）。
    ///
    /// runner 注入 seam：佇列的排程語意與「真的跑一場覆盤」無關，用一個掛在 continuation 上的
    /// fake 才能精準卡住「t1 還沒跑完」這個瞬間去斷言 t2 沒偷跑——真 service 只能等它自己結束。
    func testQueueDeduplicatesAndRunsSerially() async throws {
        var started: [UUID] = []
        var finish: [CheckedContinuation<Void, Never>] = []
        let queue = MeetingReplayQueue(runner: { t in
            started.append(t.id)
            await withCheckedContinuation { finish.append($0) }   // 掛住直到測試放行
        })

        let t1 = Transcription(text: "a", duration: 1)
        let t2 = Transcription(text: "b", duration: 1)

        queue.enqueue(t1)
        queue.enqueue(t1)   // AC-57：同一筆重複按 → no-op
        queue.enqueue(t2)

        XCTAssertTrue(queue.isBusy(t1.id), "排隊中也算「覆盤中」（badge 要立刻亮）")
        XCTAssertTrue(queue.isBusy(t2.id))

        try await waitUntil { !started.isEmpty }
        await Task.yield()
        XCTAssertEqual(started, [t1.id], "序列：t1 未結束前 t2 不得啟動")

        finish.removeFirst().resume()   // 放行 t1
        try await waitUntil { started.count == 2 && !finish.isEmpty }
        XCTAssertEqual(started, [t1.id, t2.id], "FIFO：t1 跑完才輪到 t2；重複的 t1 沒有跑第二次")
        try await waitUntil { !queue.isBusy(t1.id) }
        XCTAssertTrue(queue.isBusy(t2.id), "t2 還在跑")

        finish.removeFirst().resume()   // 放行 t2
        try await waitUntil { !queue.isBusy(t1.id) && !queue.isBusy(t2.id) }
        XCTAssertNil(queue.progress, "跑完清空狀態")
        XCTAssertNil(queue.activeSessionId)
    }
}
