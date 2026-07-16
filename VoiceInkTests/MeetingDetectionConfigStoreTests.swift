import XCTest
@testable import VoiceInk

/// M11 會議偵測設定的 round-trip 與夾取（AC-77 的 config store 部分）。
/// 用 `InMemoryDefaults` 完全隔離（絕不碰 `UserDefaults.standard`，見 TestDefaults.swift 教訓）。
@MainActor
final class MeetingDetectionConfigStoreTests: XCTestCase {

    func testDefaults() {
        let store = MeetingDetectionConfigStore(defaults: InMemoryDefaults())
        XCTAssertTrue(store.enabled)
        XCTAssertTrue(store.browsersEnabled)
        XCTAssertEqual(store.nativeEnabledBundleIds, MeetingDetectionCatalog.defaultEnabledNativeBundleIds)
        XCTAssertEqual(store.debounceSeconds, 3, accuracy: 0.001)
        XCTAssertEqual(store.rearmSeconds, 30, accuracy: 0.001)
        // 預設集合含 Teams(new/classic)+Zoom，不含預設關的 Webex/FaceTime。
        XCTAssertTrue(store.nativeEnabledBundleIds.contains("com.microsoft.teams2"))
        XCTAssertTrue(store.nativeEnabledBundleIds.contains("us.zoom.xos"))
        XCTAssertFalse(store.nativeEnabledBundleIds.contains("Cisco-Systems.Spark"))
    }

    func testPersistsAndClamps() {
        let defaults = InMemoryDefaults()
        let store = MeetingDetectionConfigStore(defaults: defaults)

        store.setEnabled(false)
        store.setBrowsersEnabled(false)
        store.setNativeEnabled("us.zoom.xos", false)
        store.setNativeEnabled("Cisco-Systems.Spark", true)

        store.setDebounceSeconds(0)      // < 1 → 夾到 1
        XCTAssertEqual(store.debounceSeconds, 1, accuracy: 0.001)
        store.setDebounceSeconds(99)     // > 15 → 夾到 15
        XCTAssertEqual(store.debounceSeconds, 15, accuracy: 0.001)

        store.setRearmSeconds(1)         // < 10 → 夾到 10
        XCTAssertEqual(store.rearmSeconds, 10, accuracy: 0.001)
        store.setRearmSeconds(9999)      // > 300 → 夾到 300
        XCTAssertEqual(store.rearmSeconds, 300, accuracy: 0.001)

        // 同一後端重建 → 全部載回。
        let reloaded = MeetingDetectionConfigStore(defaults: defaults)
        XCTAssertFalse(reloaded.enabled)
        XCTAssertFalse(reloaded.browsersEnabled)
        XCTAssertFalse(reloaded.nativeEnabledBundleIds.contains("us.zoom.xos"))
        XCTAssertTrue(reloaded.nativeEnabledBundleIds.contains("Cisco-Systems.Spark"))
        XCTAssertTrue(reloaded.nativeEnabledBundleIds.contains("com.microsoft.teams2"))
        XCTAssertEqual(reloaded.debounceSeconds, 15, accuracy: 0.001)
        XCTAssertEqual(reloaded.rearmSeconds, 300, accuracy: 0.001)
    }
}
