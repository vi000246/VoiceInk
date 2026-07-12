import XCTest
import SwiftData
@testable import VoiceInk

/// 接地 noop（回空，不碰網路/索引/螢幕）。
private struct NoopGrounding: MeetingGroundingProviding {
    func gather(cueText: String, brief: String, includeRAG: Bool, includeScreen: Bool) async -> MeetingGrounding {
        .empty
    }
}

@MainActor
final class AnswerCoordinatorTests: XCTestCase {

    private var ctx: ModelContext!

    override func setUpWithError() throws {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        ctx = ModelContext(container)
    }

    private func makeCue(text: String) -> MeetingLiveCue {
        let session = MeetingLiveSession(appName: "test", brief: "訂單分庫 review")
        ctx.insert(session)
        let cue = MeetingLiveCue(session: session, text: text, kind: .directQuestion)
        ctx.insert(cue)
        try? ctx.save()
        return cue
    }

    private func makeConfig() -> MeetingCopilotConfigStore {
        let c = MeetingCopilotConfigStore()
        c.setUseHistoryRAG(false)
        c.setUseScreenContext(false)
        c.setPrefetchEnabled(true)
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
    }
}
