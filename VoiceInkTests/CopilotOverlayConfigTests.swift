import XCTest
@testable import VoiceInk

@MainActor
final class CopilotOverlayConfigTests: XCTestCase {

    private let keys = [
        "meetingCopilotOverlayClickThroughV1",
        "meetingCopilotMaxCuesShownV1"
    ]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    func testOverlayDefaults() {
        let store = MeetingCopilotConfigStore()
        XCTAssertFalse(store.overlayClickThrough, "預設不穿透——第一次用得先能點得到")
        XCTAssertEqual(store.maxCuesShown, 5)
    }

    func testOverlaySettingsPersistAndReload() {
        let store = MeetingCopilotConfigStore()
        store.setOverlayClickThrough(true)
        store.setMaxCuesShown(3)

        let reloaded = MeetingCopilotConfigStore()
        XCTAssertTrue(reloaded.overlayClickThrough)
        XCTAssertEqual(reloaded.maxCuesShown, 3)
    }

    func testMaxCuesShownIsClamped() {
        let store = MeetingCopilotConfigStore()
        store.setMaxCuesShown(0)
        XCTAssertEqual(store.maxCuesShown, 1)
        store.setMaxCuesShown(999)
        XCTAssertEqual(store.maxCuesShown, 20)
    }
}
