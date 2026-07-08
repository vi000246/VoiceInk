---
linear_issue: null
---
# SRS: 共用範本庫 + 導覽重構（WP1+WP2）

## Metadata
- **Module**: `templates`
- **Module Spec**: `docs/spec/templates.spec.md`
- **Source PRD**: N/A（需求來自 2026-07-08 使用者詳述，決策已定）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-08
- **Grill level**: 1 (standard)
- **Plans**: （待 /prp-plan）

## Feature Summary

把目前**分開的**語音範本庫（`AIEnhancementService.customPrompts`）與錄音範本庫
（`RecorderConfigStore.recorderPrompts`）合併成**單一共用範本庫**，每個範本可**多選所屬類別**
（語音輸入／錄音輸入），語音模式與錄音模式編輯時以類別多選篩選挑範本；同時重構側欄資訊架構
（更名、分組、Ask AI 獨立群組）。這是**行為保留為主的重構＋一項新能力（範本共用）**。

## Delta from Current Module State

> `templates` 是新模組（本 SRS 建立其 Module Spec，逆向自現有跨模組的範本處理）。以下描述變更。

### New / Changed Data Models

- **CHANGED** `CustomPrompt`（`Models/CustomPrompt.swift`）新增 additive 欄位
  `categories: [TemplateCategory]`（Codable，`decodeIfPresent ?? []`；空＝未分類，遷移時填入）。
  - `enum TemplateCategory: String, Codable, CaseIterable { case voiceInput, recorderInput }`
- **NEW** 單一共用範本庫的持久化：`TemplateStore`（`@MainActor` singleton，JSON in UserDefaults
  key `sharedTemplatesV1`）取代兩個舊陣列的**權威來源**。
- **DEPRECATED（讀取相容）** UserDefaults keys `"customPrompts"`（語音）、`"recorderCategoryPromptsV1"`
  （錄音）——遷移一次性讀入後不再寫入；保留舊 key 值供 rollback，不刪。

### Changed Business Logic

- **一次性遷移**（首次啟動偵測 `sharedTemplatesV1` 不存在時）：讀入舊語音範本→標
  `[.voiceInput]`、舊錄音範本→標 `[.recorderInput]`；**同 id 衝突**（同一 CustomPrompt id 兩邊都有，
  理論上不會）→ 合併 categories。寫入 `sharedTemplatesV1`，設遷移完成旗標。
- **語音模式取範本**：`AIEnhancementService.customPrompts`（現為 stored 陣列）改為
  `TemplateStore.shared.templates(for: .voiceInput)` 的 computed 視圖（回傳含 `.voiceInput` 類別者）。
  `ModeConfig.selectedPrompt`（UUID 字串）語意不變——仍指向某範本 id，只是來源庫變共用庫。
- **錄音分類取範本**：`RecorderConfigStore.recorderPrompt(byId:)` 改查共用庫；`recorderPrompts`
  computed 為 `templates(for: .recorderInput)`。`RecorderCategory.customPromptId` 語意不變。
- **模式編輯器範本選擇**：語音模式編輯 / 錄音分類編輯的範本 picker，資料源改為
  `templates(for: 對應類別)`，並提供**類別多選篩選**（可同時看兩類、或只看一類）。
- **範本編輯器**：新增/編輯範本時多一個**類別多選控制**（勾選語音輸入／錄音輸入）。至少一類必選
  （全空則預設 `.voiceInput`，避免孤兒範本）。

### Sidebar / IA 重構（WP1）

- 更名：`.categories` 標題「錄音範本」→「錄音模式」；`.prompts` 標題「Voice Prompts / 語音範本」
  →「共用範本」。
- 分組：「共用範本」（`.prompts`）從 Voice Input 區移到 **Shared & System**。
- 區塊更名：`sidebarSections` 的「Recorder → Obsidian」→「錄音輸入」。
- **Ask AI 獨立群組**：`.askAI` 從 Shared & System 抽出，自成一個側欄區「Ask AI」（本 SRS 只建立
  空群組並移入現有 `.askAI`；Ask AI 範本頁等其他項屬 SRS-D）。
- **輸入歷史（`.history`）維持現狀不動**——其拆分為語音管理／錄音管理由 **SRS-B** 連同新頁面一起做
  （側欄項與頁面同批上），避免中間態出現指向不存在頁面的側欄項。

### Explicitly Out of Scope

- 錄音管理／語音管理頁本身（SRS-B）；會議錄製改動（SRS-C）；Ask AI 功能增強與 Ask AI 範本頁
  （SRS-D）。本 SRS 只到「Ask AI 空群組 + 移入現有 Ask AI 頁」。
- CloudKit 同步：語音範本原本無同步、錄音範本亦無——合併後維持本機 UserDefaults，不引入同步。

## Functional Requirements

- [ ] **FR-1** `CustomPrompt` 具 `categories: [TemplateCategory]`，Codable 向後相容（舊資料解出 `[]`）。
- [ ] **FR-2** 單一 `TemplateStore` 為範本權威來源；提供 `templates`、`templates(for:)`、
  `template(byId:)`、`upsert`、`delete`。
- [ ] **FR-3** 首次啟動一次性遷移：舊語音範本→`.voiceInput`、舊錄音範本→`.recorderInput`，冪等
  （已遷移旗標存在則跳過）。
- [ ] **FR-4** 語音模式編輯的範本 picker 只列（預設）含 `.voiceInput` 的範本；提供類別多選篩選切換。
- [ ] **FR-5** 錄音分類（錄音模式）編輯的範本 picker 只列（預設）含 `.recorderInput` 的範本；同上篩選。
- [ ] **FR-6** 範本編輯器可多選類別；至少一類（全空防呆→`.voiceInput`）。
- [ ] **FR-7** 同一範本標兩類時，語音模式與錄音模式都能選到它、套用結果一致（共用驗證）。
- [ ] **FR-8** 側欄更名／分組／Ask AI 群組如上；`assertSidebarItemsCoverAllCases` 仍通過。
- [ ] **FR-9** 既有語音模式的 `selectedPrompt`、既有錄音分類的 `customPromptId` 在遷移後仍解析到
  同一範本（id 不變），行為零回歸。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 相容性 | 遷移後既有模式/分類的範本綁定零斷裂 | 範本 id 不變，只換來源庫；computed 視圖對舊呼叫端透明 |
| 安全遷移 | 遷移失敗不致資料遺失 | 舊 UserDefaults key 保留不刪，可 rollback |
| 一致性 | 範本編輯即時反映於兩種模式 picker | 單一 `@Published` 來源，SwiftUI 綁定 |

## Architecture Notes

- **單一庫 + 類別標籤** vs 兩庫互見：選單一庫（使用者決策），因為「共用」語意天然是一份資料多個
  歸屬，兩庫互見會產生同步/重複問題。
- `AIEnhancementService.customPrompts` 與 `RecorderConfigStore.recorderPrompts` 保留為
  **computed 視圖**（不再各自 stored），讓大量既有呼叫端零改動——這是控制重構半徑的關鍵。
- 側欄 `ViewType`/`AppSidebar` 是 app-wide exhaustive switch + DEBUG assert，改動須同步 5 處
  （見既有 `.askAI` 註冊經驗）。

## Acceptance Criteria

### AC-1: 遷移保留既有綁定
- **Given**: 舊版有語音範本 A（被某語音模式選用）與錄音範本 B（被某錄音分類綁定）
- **When**: 升級後首次啟動觸發遷移
- **Then**: A 出現在共用庫且含 `.voiceInput`、B 含 `.recorderInput`；該語音模式仍解析到 A、該錄音
  分類仍解析到 B；套用結果與升級前一致
- **Test**: `TemplateMigrationTests::migratesAndPreservesBindings`

### AC-2: 範本共用於兩種模式
- **Given**: 一個範本標了 `.voiceInput` 與 `.recorderInput`
- **When**: 在語音模式 picker 與錄音分類 picker 分別查看
- **Then**: 兩處都列出該範本，皆可選用
- **Test**: `TemplateStoreTests::sharedTemplateVisibleToBothCategories`

### AC-3: 類別篩選
- **Given**: 庫中有純語音、純錄音、雙類三種範本
- **When**: 語音模式 picker 預設檢視 / 切到「全部類別」
- **Then**: 預設只見含 `.voiceInput`（純語音＋雙類）；全部類別時三種皆見
- **Test**: `TemplateStoreTests::categoryFilter`

### AC-4: 遷移冪等
- **Given**: 已遷移過（`sharedTemplatesV1` 存在）
- **When**: 再次啟動
- **Then**: 不重複遷移、不覆寫使用者後續編輯
- **Test**: `TemplateMigrationTests::idempotent`

### AC-5: 側欄結構
- **Given**: 重構後
- **When**: 開啟主視窗
- **Then**: 「共用範本」在 Shared & System；「錄音模式」為原錄音範本項；「錄音輸入」為原
  Recorder→Obsidian 區；Ask AI 自成一區；DEBUG assert 通過
- **Test**: 手動 + `assertSidebarItemsCoverAllCases`（DEBUG）

## Open Questions

- [ ] 範本編輯器類別控制的預設值：新建範本時預設勾哪一類（依進入點？語音模式頁進入預設語音輸入、
  錄音頁進入預設錄音輸入）——plan 時定。
- [ ] 「共用範本」頁是否顯示每個範本的類別標籤（chips）供一眼辨識——建議做，plan 時定樣式。
