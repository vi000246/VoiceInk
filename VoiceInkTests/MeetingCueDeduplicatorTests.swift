import XCTest
@testable import VoiceInk

final class MeetingCueDeduplicatorTests: XCTestCase {

    func testNormalizeStripsPunctuationAndCase() {
        XCTAssertEqual(
            MeetingCueDeduplicator.normalize("你會怎麼設計 Rate Limiter？"),
            MeetingCueDeduplicator.normalize("你會怎麼設計 rate limiter?"))
    }

    /// AC-4 的純函式半部:「一個」之差的變體在 30 秒內 = 重覆。
    func testSimilarVariantIsDuplicateWithinWindow() {
        let base = Date()
        XCTAssertTrue(MeetingCueDeduplicator.isDuplicate(
            text: "你會怎麼設計一個 rate limiter？",
            at: base.addingTimeInterval(5),
            existing: [(text: "你會怎麼設計 rate limiter？", askedAt: base)]))
    }

    func testDifferentQuestionIsNotDuplicate() {
        let base = Date()
        XCTAssertFalse(MeetingCueDeduplicator.isDuplicate(
            text: "資料庫要選 SQL 還是 NoSQL？",
            at: base.addingTimeInterval(5),
            existing: [(text: "你會怎麼設計 rate limiter？", askedAt: base)]))
    }

    /// 同句超出 30 秒窗 → 不算重覆(對方可能真的又問了一次,這次要重新接)。
    func testSameTextOutsideWindowIsNotDuplicate() {
        let base = Date()
        XCTAssertFalse(MeetingCueDeduplicator.isDuplicate(
            text: "你會怎麼設計 rate limiter？",
            at: base.addingTimeInterval(31),
            existing: [(text: "你會怎麼設計 rate limiter？", askedAt: base)]))
    }

    func testEmptyInputsAreNeverDuplicate() {
        XCTAssertFalse(MeetingCueDeduplicator.isDuplicate(text: "", at: .now, existing: []))
        XCTAssertEqual(MeetingCueDeduplicator.jaccard("", "abc"), 0)
        XCTAssertEqual(MeetingCueDeduplicator.jaccard("", ""), 0)
    }
}
