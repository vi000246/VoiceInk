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

    private func arrange(_ cues: [StubCue], maxCount: Int = 5) -> [(cue: StubCue, emphasis: CopilotOverlayEmphasis)] {
        CopilotOverlayArranger.arrange(
            cues,
            askedAt: { $0.askedAt },
            isAnswered: { $0.answered },
            maxCount: maxCount
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
}
