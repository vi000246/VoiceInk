import XCTest
@testable import VoiceInk

/// FR-5:筆記 RAG 管線設定的新家。
/// UserDefaults 樣板鏡射 `MeetingCopilotConfigStoreTests`——setUp 存值＋清鍵,tearDown 還原。
@MainActor
final class ObsidianRAGConfigStoreTests: XCTestCase {

    private let keys = [
        "notesRAGVaultBookmarkV1",
        "meetingCopilotNotesIncludeOnlyV1",
        "meetingCopilotNotesExcludedV1",
    ]
    private var saved: [String: Any?] = [:]

    /// 錄音匯出 vault 是 `effectiveVaultRoot()` 的 fallback 來源。開發機上這個 bookmark
    /// 通常是**真的設定過**的,不清掉「什麼都沒設定 → nil」就永遠測不到。
    private var savedRecorderVault: Data?

    override func setUp() {
        super.setUp()
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
        savedRecorderVault = RecorderConfigStore.shared.vaultRootBookmark
        RecorderConfigStore.shared.setVaultRoot(nil)
    }

    override func tearDown() {
        RecorderConfigStore.shared.setVaultRoot(savedRecorderVault)
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    /// AC-10:資料夾兩鍵沿用 meeting-copilot 的鍵名 —— 所有權搬家、資料零遷移。
    func testFolderKeysReuseMeetingCopilotKeysZeroMigration() {
        UserDefaults.standard.set(["工作"], forKey: "meetingCopilotNotesIncludeOnlyV1")
        UserDefaults.standard.set([".obsidian", "Archive"], forKey: "meetingCopilotNotesExcludedV1")

        let store = ObsidianRAGConfigStore()   // 測試用 internal init,鏡射 MeetingCopilotConfigStore
        XCTAssertEqual(store.includeOnlyFolders, ["工作"], "AC-10:既有值零遷移直接讀到")
        XCTAssertEqual(store.excludedFolders, [".obsidian", "Archive"])
    }

    /// 預設排除清單只在**鍵未設定**時生效(擋掉 obsidian 設定檔/垃圾桶/範本這些純雜訊)。
    func testExcludedDefaultsWhenUnset() {
        XCTAssertEqual(ObsidianRAGConfigStore().excludedFolders, [".obsidian", ".trash", "Templates"])
    }

    /// override 沒設、錄音 vault 也沒設 → nil(呼叫端據此直接跳過索引)。
    func testEffectiveVaultRootNilWhenNothingConfigured() {
        XCTAssertNil(ObsidianRAGConfigStore().effectiveVaultRoot())
    }
}
