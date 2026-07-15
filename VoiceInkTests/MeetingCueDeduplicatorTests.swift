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

    // MARK: - 包含度(2026-07-15 碎片去重事故)

    /// 短碎片完全被較長既有 cue 涵蓋 → 純 Jaccard 因聯集被撐大而壓不過門檻,包含度救得回來。
    /// 這正是「e conflict.」⊂「…efforts to resolve the conflict.」躲過去重的情境。
    func testShortFragmentContainedInLongerPriorIsDuplicate() {
        let base = Date()
        let prior = "efforts to resolve the conflict."
        // 純 Jaccard 壓不過 0.6(碎片 bigram 少、聯集大)。
        XCTAssertLessThan(MeetingCueDeduplicator.jaccard("e conflict.", prior), 0.6)
        // similarity(取 max 包含度)認得出這是被涵蓋的碎片。
        XCTAssertGreaterThanOrEqual(MeetingCueDeduplicator.similarity("e conflict.", prior), 0.6)
        XCTAssertTrue(MeetingCueDeduplicator.isDuplicate(
            text: "e conflict.",
            at: base.addingTimeInterval(3),
            existing: [(text: prior, askedAt: base)]),
            "被較長既有 cue 涵蓋的碎片應視為重覆,不再獨立 persist")
    }

    /// 兩個真正不同的短句不因包含度而誤判重覆(包含度不該把無關短句黏在一起)。
    func testUnrelatedShortPhrasesAreNotDuplicateByContainment() {
        let base = Date()
        XCTAssertFalse(MeetingCueDeduplicator.isDuplicate(
            text: "快取要怎麼設計",
            at: base.addingTimeInterval(3),
            existing: [(text: "資料庫怎麼選型", askedAt: base)]))
    }
}
