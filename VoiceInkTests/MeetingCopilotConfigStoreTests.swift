import XCTest
@testable import VoiceInk

@MainActor
final class MeetingCopilotConfigStoreTests: XCTestCase {

    private let keys = [
        "meetingCopilotFastProviderV1",
        "meetingCopilotFastModelV1",
        "meetingCopilotShowInformationalCuesV1",
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

    func testM2FieldDefaultsAndPersistence() {
        let store = MeetingCopilotConfigStore()
        XCTAssertNil(store.fastProviderName, "未設定 → nil = 跟隨預設 provider")
        XCTAssertNil(store.fastModelName)
        XCTAssertFalse(store.showInformationalCues, "FR-11:informational 預設隱藏")

        store.setFastModel(provider: "openai", model: "gpt-4o-mini")
        store.setShowInformationalCues(true)

        // 新實例重新 load() → 值來自 UserDefaults。
        let reloaded = MeetingCopilotConfigStore()
        XCTAssertEqual(reloaded.fastProviderName, "openai")
        XCTAssertEqual(reloaded.fastModelName, "gpt-4o-mini")
        XCTAssertTrue(reloaded.showInformationalCues)

        // 清空 = removeObject(nil 語意,鏡射 RecorderConfigStore.persistString)。
        store.setFastModel(provider: nil, model: nil)
        XCTAssertNil(MeetingCopilotConfigStore().fastProviderName)
        XCTAssertNil(UserDefaults.standard.object(forKey: "meetingCopilotFastProviderV1"))
    }
}
