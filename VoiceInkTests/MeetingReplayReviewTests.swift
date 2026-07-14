import XCTest
@testable import VoiceInk

/// 離線覆盤(M8 C 組)。本檔先只涵蓋 AC-39 的分段純函式;
/// replay 管線與漏抓掃描的測試在後續 task 追加到同一檔。
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

    // MARK: - helpers

    private func strippingWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
