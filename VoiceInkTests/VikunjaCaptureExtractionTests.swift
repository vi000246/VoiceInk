import XCTest
@testable import VoiceInk

/// LLM 抽取結果的解析(純函式,零網路)。
/// 紅線:任何解析失敗都必須退回保留原文的 fallback——捕捉內容絕不因 LLM 失敗而遺失。
final class VikunjaCaptureExtractionTests: XCTestCase {

    private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    // MARK: - 正常解析

    func testParseNormalJSON() {
        let raw = #"{"title":"買牛奶","description":"回家路上","due_date":"2026-07-19T15:00:00+08:00","priority":3}"#
        let result = VikunjaCaptureExtraction.parse(raw, transcript: "原文")
        XCTAssertEqual(result.title, "買牛奶")
        XCTAssertEqual(result.description, "回家路上")
        XCTAssertEqual(result.dueDate, utcDate(year: 2026, month: 7, day: 19, hour: 7))
        XCTAssertEqual(result.priority, 3)
    }

    func testParseStripsMarkdownFence() {
        let raw = """
        ```json
        {"title": "繳電費", "description": "", "due_date": null, "priority": 5}
        ```
        """
        let result = VikunjaCaptureExtraction.parse(raw, transcript: "原文")
        XCTAssertEqual(result.title, "繳電費")
        XCTAssertNil(result.dueDate)
        XCTAssertEqual(result.priority, 5)
    }

    func testParseDueDateNull() {
        let raw = #"{"title":"x","description":"","due_date":null,"priority":0}"#
        XCTAssertNil(VikunjaCaptureExtraction.parse(raw, transcript: "原文").dueDate)
    }

    // MARK: - fallback(紅線)

    func testInvalidJSONFallsBackToTranscriptTitle() {
        let result = VikunjaCaptureExtraction.parse("抱歉,我無法解析這段話。", transcript: "  幫我記得買牛奶  ")
        XCTAssertEqual(result.title, "幫我記得買牛奶")   // trim 後原文
        XCTAssertEqual(result.description, "")
        XCTAssertNil(result.dueDate)
        XCTAssertEqual(result.priority, 0)
    }

    func testEmptyTitleFallsBack() {
        let raw = #"{"title":"  ","description":"d","due_date":null,"priority":2}"#
        let result = VikunjaCaptureExtraction.parse(raw, transcript: "原文內容")
        XCTAssertEqual(result.title, "原文內容")
        XCTAssertEqual(result.priority, 0)
    }

    func testFallbackTruncatesTitleTo120AndKeepsFullTextInDescription() {
        let transcript = String(repeating: "字", count: 150)
        let result = VikunjaCaptureExtraction.fallback(transcript: transcript)
        XCTAssertEqual(result.title.count, 120)
        XCTAssertEqual(result.title, String(repeating: "字", count: 120))
        XCTAssertEqual(result.description, transcript)   // 全文保留,一字不丟
        XCTAssertNil(result.dueDate)
        XCTAssertEqual(result.priority, 0)
    }

    func testFallbackShortTranscriptHasEmptyDescription() {
        let result = VikunjaCaptureExtraction.fallback(transcript: "買牛奶")
        XCTAssertEqual(result.title, "買牛奶")
        XCTAssertEqual(result.description, "")
    }

    // MARK: - due_date 邊界

    func testSentinelDateTreatedAsNil() {
        // Vikunja 的「未設定」sentinel——絕不能當成真日期送回去。
        XCTAssertNil(VikunjaCaptureExtraction.parseDueDate("0001-01-01T00:00:00Z"))
    }

    func testFractionalSecondsAccepted() {
        XCTAssertEqual(
            VikunjaCaptureExtraction.parseDueDate("2026-07-19T15:00:00.500+08:00"),
            utcDate(year: 2026, month: 7, day: 19, hour: 7).addingTimeInterval(0.5))
    }

    func testGarbageDueDateIsNil() {
        XCTAssertNil(VikunjaCaptureExtraction.parseDueDate("明天下午三點"))
        XCTAssertNil(VikunjaCaptureExtraction.parseDueDate(""))
        XCTAssertNil(VikunjaCaptureExtraction.parseDueDate(nil))
    }

    // MARK: - priority 夾取

    func testPriorityClamped() {
        XCTAssertEqual(VikunjaCaptureExtraction.clampPriority(9), 5)
        XCTAssertEqual(VikunjaCaptureExtraction.clampPriority(-3), 0)
        XCTAssertEqual(VikunjaCaptureExtraction.clampPriority(3.0), 3)
        XCTAssertEqual(VikunjaCaptureExtraction.clampPriority(nil), 0)
        XCTAssertEqual(VikunjaCaptureExtraction.clampPriority(.nan), 0)
    }

    func testPriorityOutOfRangeInJSONIsClamped() {
        let raw = #"{"title":"x","description":"","due_date":null,"priority":99}"#
        XCTAssertEqual(VikunjaCaptureExtraction.parse(raw, transcript: "t").priority, 5)
    }

    // MARK: - prompt 素材

    func testBuildUserMessageContainsNowAndTranscript() {
        // 2026-07-18T06:30:00Z == 台北 2026-07-18(六) 14:30
        let now = utcDate(year: 2026, month: 7, day: 18, hour: 6, minute: 30)
        let message = VikunjaCaptureExtraction.buildUserMessage(transcript: "明天下午三點開會", now: now)
        XCTAssertTrue(message.contains("2026-07-18 14:30"), message)
        XCTAssertTrue(message.contains("星期六"), message)
        XCTAssertTrue(message.contains("+08:00"), message)
        XCTAssertTrue(message.contains("明天下午三點開會"), message)
    }

    // MARK: - 剪貼簿保底通知(紅線:據實回報)

    func testClipboardRescueTitleWhenCopySucceeded() {
        XCTAssertEqual(
            VikunjaCaptureCoordinator.clipboardRescueTitle(prefix: "建立任務失敗", copied: true),
            "建立任務失敗,轉錄內容已複製到剪貼簿"
        )
    }

    func testClipboardRescueTitleWhenCopyFailedMustNotClaimCopied() {
        // 剪貼簿寫入失敗(可被剪貼簿管理工具搶佔)不得謊稱「已複製」——要指向語音歷史保底。
        let title = VikunjaCaptureCoordinator.clipboardRescueTitle(prefix: "Vikunja token 不見了", copied: false)
        XCTAssertFalse(title.contains("已複製"), title)
        XCTAssertTrue(title.contains("語音管理"), title)
    }
}
