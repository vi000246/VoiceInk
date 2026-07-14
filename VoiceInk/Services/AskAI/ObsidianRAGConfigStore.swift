import Foundation
import Combine

/// 筆記 RAG 管線設定的單一權威來源（Ask AI 與 meeting-copilot 兩個消費者）。
///
/// 資料夾兩鍵**沿用** meeting-copilot 時期的鍵名 —— 所有權搬家、資料零遷移。
/// 樣式鏡射 `MeetingCopilotConfigStore` / `RecorderConfigStore`:
/// `@Published private(set)` + `…V1` UserDefaults key + `set…()` mutator。
@MainActor
final class ObsidianRAGConfigStore: ObservableObject {

    static let shared = ObsidianRAGConfigStore()

    // MARK: - Keys

    /// 筆記專用 vault override（新鍵）。
    private let vaultKey = "notesRAGVaultBookmarkV1"
    /// 沿用 meeting-copilot 的兩個資料夾鍵 —— 使用者既有設定不用搬。
    private let includeOnlyKey = "meetingCopilotNotesIncludeOnlyV1"
    private let excludedKey = "meetingCopilotNotesExcludedV1"

    // MARK: - State

    /// 筆記專用 vault（security-scoped bookmark）。nil = 跟隨錄音匯出 vault。
    @Published private(set) var notesVaultBookmark: Data?
    /// 空 = 不限資料夾。
    @Published private(set) var includeOnlyFolders: [String] = []
    /// 預設擋掉 obsidian 設定檔/垃圾桶/範本（純雜訊,嵌了只會稀釋檢索品質）。
    @Published private(set) var excludedFolders: [String] = [".obsidian", ".trash", "Templates"]

    init() {
        let d = UserDefaults.standard
        notesVaultBookmark = d.data(forKey: vaultKey)
        // 只在「鍵有設定」時覆寫預設 —— `stringArray` 回 nil 才叫沒設定過。
        // 使用者清空成 `[]` 是合法狀態,不可被預設值蓋回去（否則永遠清不掉）。
        if let v = d.stringArray(forKey: includeOnlyKey) { includeOnlyFolders = v }
        if let v = d.stringArray(forKey: excludedKey) { excludedFolders = v }
    }

    // MARK: - Vault 解析

    /// 唯一的 vault 解析點:override 優先,nil 跟隨錄音 vault。四個消費者都走這裡。
    func effectiveVaultRoot() -> URL? {
        if let override = notesVaultBookmark {
            return VaultExportService.shared.resolveVaultRoot(override)
        }
        guard let bookmark = RecorderConfigStore.shared.vaultRootBookmark else { return nil }
        return VaultExportService.shared.resolveVaultRoot(bookmark)
    }

    // MARK: - Mutators

    /// 設定（或清除）筆記專用 vault。nil = 跟隨錄音匯出 vault。
    func setNotesVaultBookmark(_ value: Data?) {
        notesVaultBookmark = value
        if let value { UserDefaults.standard.set(value, forKey: vaultKey) }
        else { UserDefaults.standard.removeObject(forKey: vaultKey) }
    }

    func setIncludeOnlyFolders(_ value: [String]) {
        includeOnlyFolders = value
        UserDefaults.standard.set(value, forKey: includeOnlyKey)
    }

    func setExcludedFolders(_ value: [String]) {
        excludedFolders = value
        UserDefaults.standard.set(value, forKey: excludedKey)
    }
}
