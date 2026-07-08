import XCTest
@testable import VoiceInk

/// Plan #1 Task 2：`editBeforePaste` 是 additive 欄位，舊 JSON（無此鍵）須 decode 成 false。
final class ModeConfigEditBeforePasteTests: XCTestCase {

    private func sampleConfig(editBeforePaste: Bool) -> ModeConfig {
        ModeConfig(name: "Test", isAIEnhancementEnabled: false,
                   outputMode: .paste, editBeforePaste: editBeforePaste)
    }

    func testRoundTripsEditBeforePaste() throws {
        let data = try JSONEncoder().encode(sampleConfig(editBeforePaste: true))
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: data)
        XCTAssertTrue(decoded.editBeforePaste)
    }

    func testMissingKeyDefaultsFalse() throws {
        // 模擬舊版設定：把 editBeforePaste 鍵移除後再 decode。
        let data = try JSONEncoder().encode(sampleConfig(editBeforePaste: true))
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "editBeforePaste")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: stripped)
        XCTAssertFalse(decoded.editBeforePaste)
    }
}
