import XCTest
@testable import VoiceInk

final class MeetingShortcutTests: XCTestCase {
    func testToggleMeetingIsGlobalUtility() {
        XCTAssertTrue(ShortcutAction.globalUtilityActions.contains(.toggleMeetingRecording))
        XCTAssertEqual(ShortcutAction.toggleMeetingRecording.storageName, "toggleMeetingRecording")
        XCTAssertTrue(ShortcutAction.toggleMeetingRecording.isStored)
        XCTAssertEqual(ShortcutAction.toggleMeetingRecording.userDefaultsKey, "Shortcut_toggleMeetingRecording")
    }
}
