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
}
