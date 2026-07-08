---
linear_issue: null
---
# SRS: 錄音管理 + 語音管理（Notion 式清單頁）（WP3+WP4）

## Metadata
- **Module**: `library-management`
- **Module Spec**: `docs/spec/library-management.spec.md`
- **Source PRD**: N/A（2026-07-08 使用者需求）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-08
- **Grill level**: 1 (standard)
- **Supersedes**: `docs/srs/recorder-automation-recording-library.srs.md`（未實作;其表格/分頁/批次意圖併入本 SRS 並擴充為 Notion 式 + 詳情彈窗 + 星號保護 + 語音管理鏡射）

## Feature Summary

把「錄音管理」重構成 **Notion 式清單頁**（欄位化：日期／檔案大小／tag／已輸出，可排序，點擊開
**詳情彈窗**而非展開），加上**帶篩選的批次刪除 + 星號保護 + 警告**;新增鏡射的**語音管理頁**
（同表格/批次/詳情基建，但無匯出、無錄音設定，取代輸入歷史管理語音錄音檔、可手動標 tag）;並修
**改檔名後匯出 Obsidian 要用新檔名**的 bug。

## Delta from Current Module State

> `library-management` 為新模組（共用表格/批次/詳情元件 + 兩個具體頁）。錄音管理現況見
> `docs/spec/recorder-automation.spec.md`（`RecorderHistoryView` 無上限 `@Query` + 展開卡片）。

### New / Changed Data Models

- **CHANGED** `Transcription` 新增 additive 欄位 `manualTag: String?`（語音項的手動 tag;錄音項沿用
  `recorderCategoryName` 為 tag，兩者統一由 computed `displayTag` 對外）。lightweight migration。
- **無新 @Model**。`#Index` 追加 `[\.recorderFavorite]`（星號篩選）。

### New Components（共用基建）

| Component | 責任 |
|---|---|
| `LibraryTableView`（泛型） | Notion 式欄位表格:日期/大小/tag/已輸出 + 排序 header;列點擊 → 詳情彈窗 |
| `LibraryDetailPopup` | 詳情彈窗（取代展開）:原文/enhanced/播放/改名/star/套範本等,依頁面能力顯示 |
| `LibraryBatchRunner` | sequential 批次執行 + 進度 + 取消 + 逐筆失敗不中斷（鏡射 meeting 已有的保檔思路） |
| `LibraryFilter` | 篩選狀態值型別:tag/來源/星號/日期/狀態 + 排序欄位 + 方向;純函式套用於 `[Transcription]`（可測） |

### Changed Business Logic

- **錄音管理**（`RecorderHistoryView` 重構）:
  - 顯示改 `LibraryTableView`;列點擊開 `LibraryDetailPopup`（不再 inline 展開）。
  - **批次刪除**:選取 + 「filter 刪除」;**星號（`recorderFavorite`）項預設排除**，要刪星號需
    明確切「包含星號」並跳**二次警告**確認。沿用 `TranscriptionStore.delete`。
  - **改名→匯出對齊**:匯出檔名改用使用者在管理頁改的名稱（`recorderTitle`），不是 ledger 原始
    檔名。（修 `VaultExportService.suggestedFileName` / `RecorderPostProcessor.exportToVault` 的檔名來源。）
  - page-scoped ledger 檔名查詢（取代每次變動全表 fetch）。
- **語音管理**（新頁,取代 `.history` 的 `InlineHistoryView` 之於「語音項」的角色）:
  - 同 `LibraryTableView`/`LibraryDetailPopup`/批次刪除;**無匯出、無套範本到 vault、無錄音設定**。
  - **手動 tag**:詳情彈窗可設 `manualTag`;套用某範本（如會議範本）時自動把 tag 設成該範本名/類別
    （「套會議範本→標會議 tag」）。
  - 資料範圍 = 非錄音項（`importFingerprint == nil`，即語音輸入/聽寫）。
- **側欄接線**（承 SRS-A）:新增 `.voiceLibrary`（語音輸入群）與把 `.recorderLog`（錄音管理）留在
  錄音輸入群;移除舊 `.history`（`InlineHistoryView`）作為主頁的角色（歷史窗仍可保留為獨立視窗）。

### Explicitly Out of Scope

- Ask AI 單檔提問按鈕（屬 SRS-D，但本 SRS 的詳情彈窗/列動作要**預留擺放位置**）。
- 會議錄製分類行為（SRS-C）。
- 真・DB-side cursor 分頁:採**窗格化渲染**（見 Architecture Notes 的取捨）。

## Functional Requirements

- [ ] **FR-1** 錄音管理為欄位表格:日期、檔案大小、tag、已輸出;每欄可點擊排序（升/降）。
- [ ] **FR-2** 列點擊開詳情彈窗（Notion 式），非 inline 展開;彈窗含既有卡片能力（播放/原文/enhanced/改名/star/套範本/匯出）。
- [ ] **FR-3** 批次刪除可先 filter（tag/日期/來源/狀態）;**星號項預設不刪**。
- [ ] **FR-4** 要刪含星號項須明確切換 + 二次警告確認,顯示將刪幾筆星號。
- [ ] **FR-5** 改過 `recorderTitle` 的錄音，匯出 Obsidian 檔名用新名稱。
- [ ] **FR-6** 語音管理頁:同表格/詳情/批次刪除，範圍為語音項;無匯出/範本 vault/錄音設定。
- [ ] **FR-7** 語音管理可手動設 tag;套範本自動標對應 tag。
- [ ] **FR-8** 大量資料時只渲染目前窗格（不一次渲染全部卡片）;篩選/排序響應 <100ms@2000。
- [ ] **FR-9** 兩頁的單筆既有操作零回歸（改名、star、刪音檔、刪整筆、套範本、匯出）。
- [ ] **FR-10**（2026-07-08 追加）**側欄可展開分類直選**：錄音管理／語音管理在左側欄可展開成該頁的分類子項，直接點側欄分類即套用篩選（免點進頁面再開下拉）。分類**依檔案數量由多到少排序**，每個分類**旁標示該分類的檔案數**。點分類頂層項＝全部（不篩選）。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 響應 | 篩選/排序 <100ms@2000 筆 | 純函式篩選 + 窗格化渲染 + page-scoped ledger |
| 安全 | 星號錄音零誤刪 | 預設排除 + 明確切換 + 二次警告 |
| 一致性 | 改名即反映於匯出 | 匯出檔名取 `recorderTitle` |
| 重用 | 兩頁共用一套元件 | 泛型 `LibraryTableView`/彈窗/批次 |

## Architecture Notes

- **窗格化渲染 vs DB cursor 分頁**:本 session 已兩次踩到 SwiftData `#Predicate` 對 optional/nested
  條件的型別檢查爆炸（RetrievalService、預期的 optional-UUID）。故 v1 採「純函式篩選 `[Transcription]`
  + `LazyVStack`/`Table` 只渲染可見窗格 + page-scoped ledger」，避開把 tag/來源/日期多條件塞進單一
  巨型 predicate。實測瓶頸本來就是「渲染全部卡片 + 每次變動全表撈 ledger」，本方案正對症。
- macOS `Table` vs 自繪 `LazyVStack` 欄位列:plan 時定（`Table` 原生排序/欄位、但客製彈窗互動較綁手）。
- tag 統一:對外 `displayTag`（錄音=`recorderCategoryName`、語音=`manualTag`），避免兩套欄位在 UI 分歧。

## Acceptance Criteria

### AC-1: 星號保護
- **Given**: 選取範圍含 3 筆星號 + 10 筆非星號
- **When**: 批次刪除（預設）
- **Then**: 只刪 10 筆非星號;星號保留;若切「包含星號」則跳警告「將刪除 3 筆星號錄音」需再確認
- **Test**: `LibraryBatchTests::starredExcludedByDefaultThenWarned`

### AC-2: 改名→匯出對齊
- **Given**: 一筆已匯出錄音,使用者在管理頁改名為「面試覆盤」
- **When**: 重新匯出到 Obsidian
- **Then**: vault 檔名用「面試覆盤」(＋日期規則)，非原始裝置檔名
- **Test**: `VaultExportTests::usesRenamedTitle`

### AC-3: 詳情彈窗取代展開
- **Given**: 錄音管理清單
- **When**: 點一列
- **Then**: 開彈窗顯示詳情;不再 inline 展開占用清單空間
- **Test**: 手動

### AC-4: 語音管理範圍與 tag
- **Given**: 語音輸入與錄音各若干
- **When**: 開語音管理
- **Then**: 只見語音項;可手動標 tag;套會議範本 → tag 顯示「會議」;無匯出按鈕
- **Test**: `LibraryFilterTests::voiceScopeExcludesRecorder` + 手動

### AC-5: 排序與窗格
- **Given**: 2000 筆種子
- **When**: 點「檔案大小」欄排序
- **Then**: 依大小排序、響應 <100ms;只渲染可見窗格
- **Test**: `LibraryFilterTests::sortBySize` + 手動計時

## Open Questions

- [ ] `Table`（原生欄位/排序）vs 自繪列 — plan 定。
- [ ] 語音項的「檔案大小」來源（語音錄音檔 vs 無音檔者顯示 —）。
- [ ] 詳情彈窗尺寸/是否可多開 — plan 定。
