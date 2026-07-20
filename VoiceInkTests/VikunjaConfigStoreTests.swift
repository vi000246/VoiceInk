import XCTest
@testable import VoiceInk

/// Vikunja 設定的存取往返。用 `InMemoryDefaults` 完全隔離
/// (絕不碰 `UserDefaults.standard`,見 TestDefaults.swift 教訓);token 走 Keychain,此處不測。
@MainActor
final class VikunjaConfigStoreTests: XCTestCase {

    func testDefaults() {
        let store = VikunjaConfigStore(defaults: InMemoryDefaults())
        XCTAssertEqual(store.baseURL, "")
        XCTAssertEqual(store.defaultProjectID, 0)
        XCTAssertEqual(store.defaultProjectName, "")
        XCTAssertFalse(store.enabled)
    }

    func testRoundTripThroughSameBackend() {
        let defaults = InMemoryDefaults()
        let store = VikunjaConfigStore(defaults: defaults)

        store.setBaseURL("  https://vikunja.example.com/  ")
        store.setDefaultProject(id: 3, name: "收件匣")
        store.setEnabled(true)

        // 寫入即 trim(URL 的 /api/v1 正規化留給 VikunjaService,store 存使用者輸入)。
        XCTAssertEqual(store.baseURL, "https://vikunja.example.com/")

        // 同一後端重建 → 讀回一致。
        let reloaded = VikunjaConfigStore(defaults: defaults)
        XCTAssertEqual(reloaded.baseURL, "https://vikunja.example.com/")
        XCTAssertEqual(reloaded.defaultProjectID, 3)
        XCTAssertEqual(reloaded.defaultProjectName, "收件匣")
        XCTAssertTrue(reloaded.enabled)
    }

    func testIsConfiguredPureFunction() {
        XCTAssertFalse(VikunjaConfigStore.isConfigured(baseURL: "", defaultProjectID: 1))
        XCTAssertFalse(VikunjaConfigStore.isConfigured(baseURL: "   ", defaultProjectID: 1))
        XCTAssertFalse(VikunjaConfigStore.isConfigured(baseURL: "https://x.example.com", defaultProjectID: 0))
        XCTAssertTrue(VikunjaConfigStore.isConfigured(baseURL: "https://x.example.com", defaultProjectID: 2))
    }
}
