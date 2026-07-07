import XCTest
@testable import VoiceInk

@MainActor
final class MeetingOriginTests: XCTestCase {
    func testMeetingOriginCarriesFingerprintAndLabel() {
        let o = QueueItemOrigin.meetingCapture(fingerprint: "fp1", sourceLabel: "會議 · Zoom")
        guard case let .meetingCapture(fp, label) = o else { return XCTFail("wrong case") }
        XCTAssertEqual(fp, "fp1"); XCTAssertEqual(label, "會議 · Zoom")
    }
}
