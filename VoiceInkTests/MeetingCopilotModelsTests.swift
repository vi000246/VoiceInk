import XCTest
@testable import VoiceInk

final class MeetingCopilotModelsTests: XCTestCase {

    // MARK: - resolve（fast/deep 純函式）

    func testFallsBackWhenProviderDisconnected() {
        // Groq 已存但不在 available(key 被移除)→ 回退預設
        let r = MeetingCopilotModels.resolve(storedProvider: "Groq", storedModel: "llama-3.1-8b-instant",
                                             defaultProvider: "Anthropic", available: ["Anthropic", "OpenAI"])
        XCTAssertEqual(r.provider, "Anthropic"); XCTAssertNil(r.model)
    }

    func testHonorsStoredWhenConnected() {
        let r = MeetingCopilotModels.resolve(storedProvider: "Groq", storedModel: "llama-3.1-8b-instant",
                                             defaultProvider: "Anthropic", available: ["Groq", "Anthropic"])
        XCTAssertEqual(r.provider, "Groq"); XCTAssertEqual(r.model, "llama-3.1-8b-instant")
    }

    func testNilStoredFollowsDefault() {
        let r = MeetingCopilotModels.resolve(storedProvider: nil, storedModel: nil,
                                             defaultProvider: "OpenAI", available: ["OpenAI"])
        XCTAssertEqual(r.provider, "OpenAI"); XCTAssertNil(r.model)
    }

    // MARK: - config M3 欄位

    @MainActor
    func testM3ConfigDefaultsAndPersistence() {
        let keys = ["meetingCopilotDeepProviderV1", "meetingCopilotDeepModelV1",
                    "meetingCopilotPrefetchV1", "meetingCopilotPersonaV1",
                    "meetingCopilotUseRAGV1", "meetingCopilotUseScreenV1"]
        var saved: [String: Any?] = [:]
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k); UserDefaults.standard.removeObject(forKey: k) }
        defer { for k in keys { if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } } }

        let s = MeetingCopilotConfigStore()
        XCTAssertNil(s.deepProviderName, "未設定 → nil = 跟隨預設")
        XCTAssertTrue(s.prefetchEnabled, "FR-15 預跑預設 true")
        XCTAssertTrue(s.useHistoryRAG)
        XCTAssertTrue(s.useScreenContext)
        XCTAssertFalse(s.domainPersona.isEmpty)

        s.setDeepModel(provider: "Anthropic", model: "claude-sonnet-4")
        s.setPrefetchEnabled(false)
        s.setUseScreenContext(false)

        let reloaded = MeetingCopilotConfigStore()
        XCTAssertEqual(reloaded.deepProviderName, "Anthropic")
        XCTAssertEqual(reloaded.deepModelName, "claude-sonnet-4")
        XCTAssertFalse(reloaded.prefetchEnabled)
        XCTAssertFalse(reloaded.useScreenContext)
        XCTAssertTrue(reloaded.useHistoryRAG, "未動的開關維持預設 true")
    }
}
