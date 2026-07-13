import XCTest
@testable import VoiceInk

final class MeetingCopilotPageTests: XCTestCase {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        c.timeZone = TimeZone(identifier: "Asia/Taipei")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testTitleFromStartDate() {
        XCTAssertEqual(
            MeetingRowDisplay.title(startedAt: date(2026, 7, 12, 14, 30)),
            "7月12日 14:30 會議"
        )
    }

    func testDurationTextForFinishedMeeting() {
        let start = date(2026, 7, 12, 14, 0)
        XCTAssertEqual(
            MeetingRowDisplay.durationText(startedAt: start, endedAt: start.addingTimeInterval(47 * 60)),
            "47 分"
        )
    }

    func testDurationTextUnderOneMinute() {
        let start = date(2026, 7, 12, 14, 0)
        XCTAssertEqual(
            MeetingRowDisplay.durationText(startedAt: start, endedAt: start.addingTimeInterval(30)),
            "<1 分"
        )
    }

    func testDurationTextForOngoingMeeting() {
        XCTAssertEqual(MeetingRowDisplay.durationText(startedAt: Date(), endedAt: nil), "進行中")
    }

    func testCueCountText() {
        XCTAssertEqual(MeetingRowDisplay.cueCountText(0), "—")
        XCTAssertEqual(MeetingRowDisplay.cueCountText(3), "3 則")
    }

    /// 鎖定 ViewType case 存在與 rawValue(= Identifiable id + AppNavigator log 字串)。
    func testMeetingCopilotViewTypeExists() {
        XCTAssertTrue(ViewType.allCases.contains(.meetingCopilot))
        XCTAssertEqual(ViewType.meetingCopilot.rawValue, "Meeting Copilot")
        XCTAssertEqual(ViewType.meetingCopilot.id, "Meeting Copilot")
    }
}
