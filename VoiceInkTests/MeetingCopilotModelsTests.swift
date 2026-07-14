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
        // 接地開關預設 **false**(2026-07-13 依使用者要求翻轉,見 MeetingCopilotConfigStore
        // 的 `useHistoryRAG` 註解:「接地讓 Tier 1/2 各多等數秒~十餘秒,先求快;要接地的人
        // 自行到設定頁開」)。螢幕 OCR 同理 —— 截圖+OCR 最耗時。
        XCTAssertFalse(s.useHistoryRAG, "FR-19 歷史逐字稿接地預設 false(求首字延遲)")
        XCTAssertFalse(s.useScreenContext, "FR-20 螢幕 OCR 接地預設 false(同上)")
        XCTAssertFalse(s.domainPersona.isEmpty)

        s.setDeepModel(provider: "Anthropic", model: "claude-sonnet-4")
        s.setPrefetchEnabled(false)
        // 一律寫**與預設相反**的值:預設已是 false,再寫一次 false 然後斷言 false,
        // 連「根本沒 persist」都會通過 —— 那樣的斷言什麼也沒鎖住。
        s.setUseScreenContext(true)

        let reloaded = MeetingCopilotConfigStore()
        XCTAssertEqual(reloaded.deepProviderName, "Anthropic")
        XCTAssertEqual(reloaded.deepModelName, "claude-sonnet-4")
        XCTAssertFalse(reloaded.prefetchEnabled)
        XCTAssertTrue(reloaded.useScreenContext, "改過的開關要讀得回來")
        XCTAssertFalse(reloaded.useHistoryRAG, "未動的開關維持預設 false")
    }
}
