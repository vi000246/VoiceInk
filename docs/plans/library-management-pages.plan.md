---
linear_issue: null
---
# Plan: 錄音管理 + 語音管理（Notion 式清單頁）（WP3+WP4）

> Mode B。共用表格/詳情彈窗/批次基建 → 兩個具體頁。純函式篩選 + 窗格化渲染（避開巨型 #Predicate）。

## Summary
把錄音管理重構成 Notion 式欄位表格（日期/大小/tag/已輸出、可排序、點擊開詳情彈窗），加帶篩選批次刪除
+ 星號保護 + 警告;新增鏡射的語音管理頁（無匯出/錄音設定、可手動標 tag）取代輸入歷史;修改名→匯出
用新檔名。

## User Story
As a 錄音越來越多的使用者, I want 清單式管理 + 批次整理 + 星號保護, so that 量大時也好瀏覽、不誤刪重要錄音。

## Problem → Solution
無上限 `@Query` + 展開卡片 + 每次變動全表撈 ledger → 純函式篩選 + 窗格化渲染 + page-scoped ledger +
詳情彈窗 + 批次（星號保護）。

## Metadata
- **Module**: library-management
- **Parent Plan**: docs/plans/templates-shared-library-and-ia.plan.md（側欄群名/`.voiceLibrary` 註冊承 SRS-A）
- **Source Feature SRS**: docs/srs/library-management-pages.srs.md
- **Source Module Spec**: docs/spec/library-management.spec.md
- **Source Linear Issue**: N/A
- **Type**: feature ｜ **Size**: L ｜ **Complexity**: Large
- **Rigor**: balanced ｜ **Mode**: B ｜ **TDD**: on ｜ **Commit cadence**: per-task
- **Estimated Files**: ~12（6 created + 6 modified + tests）

---

## UX Design
### Before
```
錄音管理：搜尋列 + 展開式卡片（點擊 inline 展開）；批次僅刪除
輸入歷史：語音+錄音混合的歷史列表
```
### After
```
錄音管理：欄位表格 日期│大小│tag│已輸出（可排序）→ 點列開詳情彈窗
          批次列：filter 刪除，星號預設排除，含星號需二次警告
語音管理：同表格/彈窗/批次，無匯出/錄音設定，可手動標 tag（取代輸入歷史）
```

## Mandatory Reading
| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | docs/srs/library-management-pages.srs.md | all | 需求 + AC |
| P0 | docs/spec/library-management.spec.md | all | 架構 |
| P0 | VoiceInk/Views/History/RecorderHistoryView.swift | all | 重構目標（保留單筆動作於彈窗） |
| P0 | VoiceInk/Models/Transcription.swift | 15, 37-53 | 加 manualTag + #Index recorderFavorite |
| P1 | VoiceInk/Views/History/TranscriptionDetailView.swift | all | 詳情彈窗內容重用 |
| P1 | VoiceInk/Services/TranscriptionStore.swift | all | 集中刪除 |
| P1 | VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift | exportToVault/recordingDate | 改名→匯出檔名來源 |
| P1 | VoiceInk/Services/RecorderAutomation/VaultExportService.swift | suggestedFileName | 檔名用 recorderTitle |
| P1 | VoiceInk/Views/History/InlineHistoryView.swift | all | 語音項現況（被取代） |
| P1 | VoiceInk/Views/ContentView.swift + AppSidebar.swift | ViewType/註冊 | +.voiceLibrary、錄音管理留錄音輸入群 |

## Patterns to Mirror
### EXISTING_SELECTION_BATCH（批次選取/shift 範圍/刪除）
```swift
// SOURCE: RecorderHistoryView.swift:134-172（selectedIds、shift-range toggle、batchDelete via TranscriptionStore）
```
### DETAIL_CONTENT（彈窗內容）
```swift
// SOURCE: TranscriptionDetailView.swift:3-30（transcription: Transcription;原文/enhanced bubble）
```
### ADDITIVE_FIELD（manualTag）
```swift
// SOURCE: Transcription.swift:37-47（optional 欄位區）;#Index :15
```
### EXPORT_FILENAME（改名來源）
```swift
// SOURCE: RecorderPostProcessor.exportToVault → VaultExportService.suggestedFileName(date:categoryName:title:)
// title 目前來自 generateShortTitle;改成優先用 transcription.recorderTitle（若使用者改過）
```

## Files to Change
| File | Action | Justification |
|---|---|---|
| VoiceInk/Models/Transcription.swift | UPDATE | manualTag + displayTag + #Index recorderFavorite |
| VoiceInk/Views/Library/LibraryTableView.swift | CREATE | 泛型欄位表格 + 排序 |
| VoiceInk/Views/Library/LibraryDetailPopup.swift | CREATE | 詳情彈窗（能力可組態） |
| VoiceInk/Views/Library/LibraryFilter.swift | CREATE | 純函式篩選/排序值型別 |
| VoiceInk/Views/Library/LibraryBatchRunner.swift | CREATE | sequential 批次 + 進度 + 取消 |
| VoiceInk/Views/History/RecorderHistoryView.swift | UPDATE | 改用共用元件（錄音範圍、含匯出） |
| VoiceInk/Views/Library/VoiceLibraryView.swift | CREATE | 語音管理頁（語音範圍、無匯出、手動 tag） |
| VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift + VaultExportService.swift | UPDATE | 改名→匯出檔名 |
| VoiceInk/Views/ContentView.swift + AppSidebar.swift | UPDATE | +.voiceLibrary、移除 .history 主頁角色 |
| VoiceInkTests/LibraryFilterTests.swift + LibraryBatchTests.swift + VaultExportTests.swift | CREATE | 篩選/批次/匯出檔名 |

## NOT Building
- Ask AI 單檔按鈕（SRS-D，僅在詳情彈窗預留位置）;真 DB cursor 分頁;會議分類（SRS-C）。

## Step-by-Step Tasks

### Task 1: Transcription manualTag + displayTag + index
- **ACTION**: additive 欄位。
- **TEST FIRST**:
  ```swift
  func testDisplayTagPrefersCategoryThenManual() {
      let rec = Transcription(text: "r", duration: 1); rec.recorderCategoryName = "會議"
      XCTAssertEqual(rec.displayTag, "會議")
      let voice = Transcription(text: "v", duration: 1); voice.manualTag = "想法"
      XCTAssertEqual(voice.displayTag, "想法")
  }
  ```
  Run — FAIL
- **IMPLEMENT**: `var manualTag: String?`;`var displayTag: String? { recorderCategoryName ?? manualTag }`;`#Index` 追加 `[\.recorderFavorite]`。
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(library): manualTag + displayTag + favorite index`

### Task 2: LibraryFilter（純函式篩選/排序）
- **ACTION**: 值型別 + `apply(to:)`。
- **TEST FIRST**（`LibraryFilterTests`）:
  ```swift
  func testFilterByTagStarredSortSize() {
      // seed [Transcription]：不同 tag / 星號 / duration；套 filter(tag=會議, starredOnly, sort=size desc)
      // 斷言結果集與排序符合預期
  }
  func testVoiceScopeExcludesRecorder() {
      // scope=voice → importFingerprint==nil 者;recorder scope 反之
  }
  ```
  Run — FAIL
- **IMPLEMENT**（`LibraryFilter.swift`）:
  ```swift
  struct LibraryFilter {
      enum Scope { case recorder, voice }   // recorder: importFingerprint != nil;voice: == nil
      enum SortField { case date, size, title }
      var scope: Scope
      var searchText = ""; var tag: String?; var starredOnly = false; var dateRange: ClosedRange<Date>?
      var sort: SortField = .date; var ascending = false
      func apply(to items: [Transcription], sizeByFingerprint: [String: Int]) -> [Transcription] { … }
  }
  ```
  純函式，大小取自 page-scoped ledger map（title 排序用 recorderTitle/displayName）。
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(library): pure filter/sort value type`

### Task 3: LibraryTableView + LibraryDetailPopup + BatchRunner
- **ACTION**: 三個共用 UI/邏輯元件。
- **TEST FIRST**（BatchRunner 可測部分）:
  ```swift
  @MainActor func testBatchRunnerProgressAndCancel() async {
      // run 100 個 no-op；斷言進度遞增；中途 cancel → 已完成保留、未跑不執行
  }
  ```
  Run — FAIL
- **IMPLEMENT**:
  - `LibraryTableView<Row>`：`Table` 或 `LazyVStack` 欄位列（plan 內定：先用 `Table` 原生排序;欄位 日期/大小/tag/已輸出）;`onSelect(Transcription)`;窗格化由 `Table`/`LazyVStack` 天然提供。
  - `LibraryDetailPopup`：吃 transcription + 能力旗標 `{canExport, canApplyTemplate, canManualTag}`;內容重用 `TranscriptionDetailView` + 依旗標顯示套範本/匯出/標 tag/改名/star。
  - `LibraryBatchRunner`：`@MainActor`，`run(items:progress:op:)` sequential + `cancel()`;逐筆失敗續跑。
- **VALIDATE**: BatchRunner 測試 PASS;build 綠。
- **COMMIT**: `feat(library): shared table, detail popup, batch runner`

### Task 4: 錄音管理重構
- **ACTION**: `RecorderHistoryView` 改用共用元件（錄音 scope、含匯出/套範本）;批次刪除加星號保護。
- **TEST FIRST**（`LibraryBatchTests`）:
  ```swift
  func testStarredExcludedByDefaultThenWarned() {
      // 選取含星號 → 預設刪除集排除星號;切「包含星號」→ 回傳需警告 flag + 星號筆數
      // （把「選取 → 刪除集計算」抽成純函式 deletionSet(selected:includeStarred:) 測試）
  }
  ```
  Run — FAIL
- **IMPLEMENT**: 移除無上限 @Query 的展開渲染，改 `LibraryTableView` + 點列開 `LibraryDetailPopup(canExport:true,…)`;`loadFileNames` 改 page-scoped;批次列加「包含星號」Toggle + 二次警告 confirmationDialog（顯示星號筆數）。`deletionSet` 純函式（星號保護）。
- **VALIDATE**: 測試 PASS;手動 AC-1/AC-3。
- **COMMIT**: `feat(library): recording management as table + starred-protected batch delete`

### Task 5: 改名→匯出對齊
- **ACTION**: 匯出檔名優先用 `recorderTitle`。
- **TEST FIRST**（`VaultExportTests`）:
  ```swift
  func testUsesRenamedTitle() {
      // transcription.recorderTitle = "面試覆盤"；exportToVault → suggestedFileName 用該名（+日期規則）
      // 抽 filename 決策為可測（suggestedFileName(date:categoryName:title:) 已存在;確認 title 來源改 recorderTitle）
  }
  ```
  Run — FAIL
- **IMPLEMENT**: `RecorderPostProcessor.export`/`exportToVault` 產 title 時，若 `transcription.recorderTitle` 是使用者改過的（非自動 stamp 格式，用 `RecorderRecordingTime.autoTitleSummary` 判斷是否自動），優先用它;否則沿用 generateShortTitle。
- **VALIDATE**: 測試 PASS;手動 AC-2。
- **COMMIT**: `fix(library): export uses renamed title`

### Task 6: 語音管理頁
- **ACTION**: `VoiceLibraryView`（語音 scope、無匯出/錄音設定、手動 tag）+ 側欄 `.voiceLibrary` 註冊 + 移除 `.history` 主頁角色。
- **TEST FIRST**: N/A（UI）——filter 測試已涵蓋 scope。
- **IMPLEMENT**: `VoiceLibraryView` 用共用元件（`LibraryFilter(scope: .voice)`、`LibraryDetailPopup(canExport:false, canManualTag:true)`）;詳情彈窗可設 `manualTag`;套範本時把 tag 設成範本名（「套會議範本→標會議」）。側欄：ViewType 加 `.voiceLibrary`（5 處註冊）;Voice Input 群 `.history` → `.voiceLibrary`;`.history`/`InlineHistoryView` 可保留為 HistoryWindow 獨立視窗（不在主側欄）。
- **VALIDATE**: build 綠（assert）;手動 AC-4。
- **COMMIT**: `feat(library): voice management page replaces input history`

### Task 7: 收尾
- **ACTION**: build+test;spec Change History;bump build;`make deploy`;回報;plan/SRS 移 completed。
- **COMMIT**: `chore(library): bump build, docs, deploy`

## Testing Strategy
| Test | Input | Expected | Edge |
|---|---|---|---|
| DisplayTag | rec/voice | category ?? manual | 皆 nil→nil |
| Filter | tag/star/size | 正確集+序 | 空結果 |
| VoiceScope | 混合 | 只語音 | — |
| BatchRunner | 100+cancel | 進度/取消 | 逐筆失敗續跑 |
| StarredProtection | 含星號 | 預設排除+警告 | 全星號 |
| ExportRenamed | 改過 title | 用新名 | 未改→自動名 |

### Edge Cases Checklist
- [ ] 星號誤刪防護（AC-1）
- [ ] 語音項無音檔的大小欄顯示 —
- [ ] 2000 筆排序 <100ms（窗格化）
- [ ] 詳情彈窗改名後清單即時反映
- [ ] 側欄漏註冊 .voiceLibrary → assert

## Validation Commands
```bash
make local
xcodebuild test … -only-testing:VoiceInkTests
make deploy
```
### Manual Validation
- [ ] AC-1 星號保護 + 警告
- [ ] AC-2 改名→匯出用新名
- [ ] AC-3 點列開彈窗（非展開）
- [ ] AC-4 語音管理範圍/tag/無匯出
- [ ] AC-5 排序 + 窗格流暢

## Acceptance Criteria
- [ ] SRS AC-1〜AC-5;單筆既有動作零回歸（FR-9）

## Risks
| Risk | L | I | Mitigation |
|---|---|---|---|
| RecorderHistoryView 重構回歸單筆動作 | M | H | 動作移到彈窗;FR-9 手動全驗 |
| 星號誤刪 | M | H | deletionSet 純函式測 + 二次警告 |
| Table vs LazyVStack 抉擇影響互動 | M | M | 先 Table;不合再換自繪列 |

## Notes
- 依賴 SRS-A（側欄群名 + Ask AI 群）;詳情彈窗預留 Ask AI 按鈕位置（SRS-D 接）。
