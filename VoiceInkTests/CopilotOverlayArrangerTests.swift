import XCTest
@testable import VoiceInk

/// FR-26:opener 最大字級的載體是「focus」emphasis——**最新一則 cue,無論是否已回答**
/// (已回答仍保持展開,深度分析才不會剛完成就被收合;見 CopilotOverlayArranger 註解)。
/// generic 純函式,用素 struct 測,不碰 SwiftData。
final class CopilotOverlayArrangerTests: XCTestCase {

    private struct StubCue {
        let name: String
        let askedAt: Date
        let answered: Bool
    }

    /// 素 struct 沒有 UUID——用 `name` 當 hashable 身分(arranger 的 `id` 是 generic
    /// `(C) -> AnyHashable`,view 端傳 `cue.id`、測試端傳 `cue.name`,走同一條路徑)。
    private func arrange(
        _ cues: [StubCue],
        maxCount: Int = 5,
        pinned: String? = nil
    ) -> [(cue: StubCue, emphasis: CopilotOverlayEmphasis)] {
        CopilotOverlayArranger.arrange(
            cues,
            askedAt: { $0.askedAt },
            isAnswered: { $0.answered },
            maxCount: maxCount,
            pinnedId: pinned,
            id: { $0.name }
        )
    }

    private func cue(_ name: String, secondsAgo: TimeInterval, answered: Bool = false) -> StubCue {
        StubCue(name: name, askedAt: Date(timeIntervalSinceNow: -secondsAgo), answered: answered)
    }

    func testNewestUnansweredIsFocusAndFirst() {
        let out = arrange([cue("old", secondsAgo: 60), cue("new", secondsAgo: 5), cue("mid", secondsAgo: 30)])
        XCTAssertEqual(out.map(\.cue.name), ["new", "mid", "old"], "由新到舊")
        XCTAssertEqual(out.map(\.emphasis), [.focus, .recent, .recent])
    }

    func testNewestAnsweredStaysFocusOlderAnsweredDims() {
        let out = arrange([cue("answered", secondsAgo: 5, answered: true), cue("open", secondsAgo: 30)])
        XCTAssertEqual(out.map(\.cue.name), ["answered", "open"], "順序仍按時間,不重排")
        XCTAssertEqual(out[0].emphasis, .focus, "最新者已回答仍保持 focus——深度分析不被收合")
        XCTAssertEqual(out[1].emphasis, .recent)

        let older = arrange([cue("new", secondsAgo: 5), cue("oldAnswered", secondsAgo: 30, answered: true)])
        XCTAssertEqual(older[0].emphasis, .focus)
        XCTAssertEqual(older[1].emphasis, .answered, "非最新的已回答者才下沉")
    }

    func testCapsAtMaxCount() {
        let cues = (0..<10).map { cue("c\($0)", secondsAgo: TimeInterval($0)) }
        let out = arrange(cues, maxCount: 3)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.cue.name), ["c0", "c1", "c2"])
    }

    func testEmptyAndZeroMax() {
        XCTAssertTrue(arrange([]).isEmpty)
        XCTAssertTrue(arrange([cue("x", secondsAgo: 1)], maxCount: 0).isEmpty)
    }

    func testAllAnsweredNewestKeepsFocus() {
        let out = arrange([cue("a", secondsAgo: 5, answered: true), cue("b", secondsAgo: 10, answered: true)])
        XCTAssertEqual(out[0].emphasis, .focus, "全部已回答時,最新者仍展開(讀分析)")
        XCTAssertEqual(out[1].emphasis, .answered)
    }

    // MARK: - AC-37:展開中的 cue 不被 maxCount 擠出

    /// 展開中 = 使用者正在讀。被 maxCount 截掉等於「讀到一半整段消失」——M8 要修的痛點。
    func testPinnedCueSurvivesMaxCountEviction() {
        // c0 最新 … c5 最舊(secondsAgo 越大越舊);maxCount 5 → 正常會截掉 c5。
        let cues = (0..<6).map { cue("c\($0)", secondsAgo: TimeInterval($0)) }
        let out = arrange(cues, maxCount: 5, pinned: "c5")   // pinned = 最舊那則

        XCTAssertTrue(out.contains { $0.cue.name == "c5" }, "展開中 cue 不被擠出")
        XCTAssertEqual(out.count, 5, "總數仍受 maxCount 約束(擠掉最舊的非 pinned)")
        XCTAssertEqual(out.first?.cue.name, "c0", "最新仍在最上")
        XCTAssertEqual(out.first?.emphasis, .focus, "最新仍為 focus(pinned 只保命,不搶 focus)")
        XCTAssertEqual(out.map(\.cue.name), ["c0", "c1", "c2", "c3", "c5"],
                       "被讓位的是最舊的非 pinned(c4);輸出仍由新到舊")
    }

    /// 回歸鎖:pinnedId = nil 時,輸出與加 pinned 參數前**完全一致**。
    /// 兩種呼叫形式對照:舊形式(不帶新參數)vs 新形式(pinnedId: nil)。
    func testNilPinnedKeepsExistingBehavior() {
        let cues = [cue("new", secondsAgo: 5),
                    cue("mid", secondsAgo: 30, answered: true),
                    cue("old", secondsAgo: 60)]

        // 舊呼叫形式:新參數有預設值,既有呼叫端不得被破壞。
        let legacy = CopilotOverlayArranger.arrange(
            cues, askedAt: { $0.askedAt }, isAnswered: { $0.answered }, maxCount: 2)
        let pinnedNil = arrange(cues, maxCount: 2, pinned: nil)

        XCTAssertEqual(legacy.map(\.cue.name), pinnedNil.map(\.cue.name), "pinnedId=nil 不改變順序")
        XCTAssertEqual(legacy.map(\.emphasis), pinnedNil.map(\.emphasis), "pinnedId=nil 不改變 emphasis")
        XCTAssertEqual(pinnedNil.map(\.cue.name), ["new", "mid"], "仍由新到舊、仍截斷至 maxCount")
        XCTAssertEqual(pinnedNil.map(\.emphasis), [.focus, .answered], "emphasis 規則不變")
    }

    /// pinned 已在截斷範圍內、或 pinned 指向不存在的 cue(過期的 expandedCueId)→ 一律不動輸出。
    func testPinnedAlreadyShownOrUnknownIsNoOp() {
        let cues = (0..<6).map { cue("c\($0)", secondsAgo: TimeInterval($0)) }
        let baseline = arrange(cues, maxCount: 5).map(\.cue.name)

        XCTAssertEqual(arrange(cues, maxCount: 5, pinned: "c1").map(\.cue.name), baseline,
                       "pinned 本來就在列表上 → 不做替換")
        XCTAssertEqual(arrange(cues, maxCount: 5, pinned: "ghost").map(\.cue.name), baseline,
                       "pinned 已不存在(換 session/被清掉)→ 不做替換,也不崩")
    }
}
