import XCTest
@testable import VoiceInk

@MainActor
final class CopilotOverlayConfigTests: XCTestCase {

    /// 每個測試一份 in-memory 設定後端（見 TestDefaults.swift）——測試不得碰 `.standard`。
    private let defaultsSuite = InMemoryDefaults()

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
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertFalse(store.overlayClickThrough, "預設不穿透——第一次用得先能點得到")
        XCTAssertEqual(store.maxCuesShown, 5)
    }

    func testOverlaySettingsPersistAndReload() {
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        store.setOverlayClickThrough(true)
        store.setMaxCuesShown(3)

        let reloaded = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertTrue(reloaded.overlayClickThrough)
        XCTAssertEqual(reloaded.maxCuesShown, 3)
    }

    func testMaxCuesShownIsClamped() {
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        store.setMaxCuesShown(0)
        XCTAssertEqual(store.maxCuesShown, 1)
        store.setMaxCuesShown(999)
        XCTAssertEqual(store.maxCuesShown, 20)
    }
}
