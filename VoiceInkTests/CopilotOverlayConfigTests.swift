import XCTest
@testable import VoiceInk

@MainActor
final class CopilotOverlayConfigTests: XCTestCase {

    private let keys = [
        "meetingCopilotOverlayClickThroughV1",
        "meetingCopilotSpeakingOpacityV1",
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
        XCTAssertEqual(store.speakingOpacity, 0.35, accuracy: 1e-9)
        XCTAssertEqual(store.maxCuesShown, 5)
    }

    func testOverlaySettingsPersistAndReload() {
        let store = MeetingCopilotConfigStore()
        store.setOverlayClickThrough(true)
        store.setSpeakingOpacity(0.5)
        store.setMaxCuesShown(3)

        let reloaded = MeetingCopilotConfigStore()
        XCTAssertTrue(reloaded.overlayClickThrough)
        XCTAssertEqual(reloaded.speakingOpacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(reloaded.maxCuesShown, 3)
    }

    func testSpeakingOpacityIsClamped() {
        let store = MeetingCopilotConfigStore()
        store.setSpeakingOpacity(0.0)
        XCTAssertEqual(store.speakingOpacity, 0.05, accuracy: 1e-9)
        store.setSpeakingOpacity(2.0)
        XCTAssertEqual(store.speakingOpacity, 1.0, accuracy: 1e-9)
    }

    func testMaxCuesShownIsClamped() {
        let store = MeetingCopilotConfigStore()
        store.setMaxCuesShown(0)
        XCTAssertEqual(store.maxCuesShown, 1)
        store.setMaxCuesShown(999)
        XCTAssertEqual(store.maxCuesShown, 20)
    }
}
