---
linear_issue: null
---
# Plan: Recording Library（Recording Management 量級化）

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type`. Mode B（任務先測）：查詢層/批次層先寫鎖行為測試（seeded in-memory container），UI 佈局手動驗證。
> **前置依賴**：`feat/meeting-capture` 分支的 `Transcription.recorderSourceLabel`（來源 chip/篩選用）。合併後再實作，或先跳過 source 篩選子項。

## Summary
把 Recording Management 從「無上限 `@Query`＋全記憶體過濾」升級為千筆量級可用的庫：cursor 分頁（鏡射 `InlineHistoryView` 既有模式）、篩選全部下推 predicate（分類/來源/狀態/星標/日期/全文）、排序控制、批次 star/reclassify/re-export、page-scoped 檔名查詢、`#Index` 補齊，以及 Ask AI 引用要用的 row-focus 鉤子。

## User Story
As a 錄音量持續成長的使用者, I want 在千筆庫中秒級篩選定位並批次整理, so that 庫再大也管得動、找得到。

## Problem → Solution
`RecorderHistoryView` 全量抓取＋線性 filter＋每次變動全表撈 ledger 檔名 → predicate＋fetchLimit＋索引＋page-scoped 查詢；批次操作沿用既有選取列擴充。

## Metadata
- **Module**: recorder-automation
- **Parent Plan**: N/A
- **Source PRD**: docs/prd/ask-ai-and-recording-library.prd.md（Milestone 1）
- **Source Feature SRS**: docs/srs/recorder-automation-recording-library.srs.md
- **Source Module Spec**: docs/spec/recorder-automation.spec.md
- **Source Linear Issue**: N/A
- **Type**: feature ｜ **Size**: M ｜ **Complexity**: Medium
- **Rigor**: balanced ｜ **Mode**: B — 任務先測 ｜ **TDD**: on ｜ **Commit cadence**: per-task
- **Estimated Files**: ~6（4 modified + tests）

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/recorder-automation-recording-library.srs.md` | all | 需求＋AC＋已驗證現況（含 O(n) 熱點清單） |
| P0 | `VoiceInk/Views/History/RecorderHistoryView.swift` | all（重構主體）；重點 :10-12 無上限 @Query、:16-52 記憶體過濾、:134-172 選取列/批次、:174-180 loadFileNames、:194+ RecordingCard | 現況與保留邊界（RecordingCard 盡量不動） |
| P0 | `VoiceInk/Views/History/InlineHistoryView.swift` | :22-59（cursor descriptor）、:345-377（分頁載入） | **要鏡射的分頁模式本體** |
| P1 | `VoiceInk/Views/History/TranscriptionHistoryView.swift` | :33-59（predicate 組裝）、:395-434（load/reset）、:460-487（id-only select-all） | 搜尋 predicate 與全選技巧 |
| P1 | `VoiceInk/Models/Transcription.swift` | :15（#Index）、:36-53（recorder/speaker 欄位） | 索引補點與可 predicate 欄位清單 |
| P1 | `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | reclassify :297-305、applyTemplate、export | 批次 reclassify/re-export 的呼叫面 |
| P1 | `VoiceInk/Services/TranscriptionStore.swift` | all | 刪除/通知集中點（批次刪除沿用） |
| P2 | `VoiceInk/Services/AppNavigator.swift` | :13-25 | focus 鉤子掛載點 |
| P2 | `VoiceInkTests/RecorderPipelineTests.swift` | all | in-memory 多模型 container 測試樣式 |

## External Documentation
No external research needed — feature uses established internal patterns.（SwiftData `#Predicate` 限制為唯一風險點，Task 2 首步實證。）

---

## Patterns to Mirror

### CURSOR_PAGINATION（鏡射本體）
```swift
// SOURCE: InlineHistoryView.swift:22-59（同 TranscriptionHistoryView:33-59）— pageSize、cursor predicate、fetchLimit
private let pageSize = 20
private func cursorQueryDescriptor(after cursor: Date?) -> FetchDescriptor<Transcription> {
    var descriptor = FetchDescriptor<Transcription>(
        predicate: buildPredicate(cursor: cursor),
        sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
    descriptor.fetchLimit = pageSize
    return descriptor
}
// 載入：loadInitialContent / loadMoreContent / resetPagination（InlineHistoryView:345-377）
```

### SEARCH_PREDICATE
```swift
// SOURCE: TranscriptionHistoryView.swift:39-54 — localizedStandardContains 進 #Predicate
#Predicate<Transcription> { t in
    t.text.localizedStandardContains(searchText) ||
    (t.enhancedText?.localizedStandardContains(searchText) ?? false)
}
```

### SELECT_ALL_IDS（不 materialize 全列）
```swift
// SOURCE: TranscriptionHistoryView.swift:460-487
var descriptor = FetchDescriptor<Transcription>(predicate: currentPredicate)
descriptor.propertiesToFetch = [\.id]
let ids = try modelContext.fetch(descriptor).map(\.id)
```

### EXISTING_BATCH_BAR（擴充目標，不重造）
```swift
// SOURCE: RecorderHistoryView.swift:134-172 — selectedIds Set、shift-range toggle、batchDelete via TranscriptionStore
```

### LEDGER_PAGE_LOOKUP（取代全表 loadFileNames）
```swift
// SOURCE: Models/ImportLedgerEntry.swift:8 — #Index [\.fingerprint] 已存在；page 查詢：
let fps = pageItems.compactMap(\.importFingerprint)
let d = FetchDescriptor<ImportLedgerEntry>(predicate: #Predicate { fps.contains($0.fingerprint) })
```

### TEST_SEEDED_CONTAINER
```swift
// SOURCE: VoiceInkTests 慣例 — in-memory container 塞 N 筆 Transcription 後驗證 query 層
let container = try ModelContainer(for: Transcription.self, ImportLedgerEntry.self,
    configurations: ModelConfiguration(isStoredInMemoryOnly: true))
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Models/Transcription.swift` | UPDATE | `#Index` 追加 `[\.recorderCategoryId]`、`[\.recorderFavorite]`、`[\.recorderSourceDeviceId]` |
| `VoiceInk/Views/History/RecorderHistoryView.swift` | UPDATE | 查詢層重構＋FilterBar＋排序＋批次擴充＋focus 消費（RecordingCard 本體保留） |
| `VoiceInk/Services/RecorderAutomation/RecordingLibraryQuery.swift` | CREATE | predicate/descriptor 組裝抽成純結構（可測；view 只消費） |
| `VoiceInk/Services/AppNavigator.swift` | UPDATE | `@Published pendingFocusTranscriptionId: UUID?`＋navigate 擴充 |
| `VoiceInkTests/RecordingLibraryQueryTests.swift` | CREATE | 分頁/組合篩選/計數/id 全選 |
| `VoiceInkTests/RecordingLibraryBatchTests.swift` | CREATE | 批次 star/reclassify seam |

## NOT Building
新組織維度（資料夾/自訂標籤）；逐字稿編輯；自訂虛擬表格；聽寫歷史頁改動；批次操作的併發執行（sequential＋progress 即可）。

---

## Step-by-Step Tasks

### Task 1: `RecordingLibraryQuery`（可測的查詢組裝核心）＋索引
- **ACTION**: 抽出 filter 狀態→`FetchDescriptor` 的純組裝層；Transcription 補三個 `#Index`。
- **TEST FIRST**（`RecordingLibraryQueryTests`，seeded in-memory 2,000 筆——寫個 `seed(container:count:)` helper 混分類/星標/來源/日期）:
  ```swift
  func testInitialLoadFetchesOnePage() throws {
      // descriptor(fetchLimit=50) fetch → count == 50；fetchCount(matching) == 2000
  }
  func testCombinedPredicateMatches() throws {
      // 分類=A AND 星標 AND 最近7天 → 與 seed 期望集完全一致
  }
  func testSearchPredicateHitsTitleAndText() throws { ... }
  func testSelectAllIdsMatchesFilter() throws {
      // propertiesToFetch [\.id] 路徑 → ids.count == 期望
  }
  ```
  Run: `xcodebuild test ... -only-testing:VoiceInkTests/RecordingLibraryQueryTests` — FAIL
- **IMPLEMENT**:
  ```swift
  /// Recording Library 的查詢組裝。純值型別——view 與測試共用，view 內不再手寫 predicate。
  struct RecordingLibraryQuery {
      enum SourceFilter: Equatable { case any, meeting, device(UUID), manualImport }
      enum SortField: String, CaseIterable { case timestamp, duration, title }
      var searchText = ""            // 250ms debounce 由 view 端沿用現有機制
      var categoryId: UUID?          // nil = 全部（用 id 不用 name；#Predicate 對 optional UUID == 需實證，見 GOTCHA）
      var source: SourceFilter = .any
      var status: String?            // transcriptionStatus
      var starredOnly = false
      var dateRange: ClosedRange<Date>?
      var sort: SortField = .timestamp
      var ascending = false
      var pageSize = 50

      func descriptor(cursor: (Date, UUID)? = nil) -> FetchDescriptor<Transcription>
      func countDescriptor() -> FetchDescriptor<Transcription>   // 同 predicate、無 limit
      func idsDescriptor() -> FetchDescriptor<Transcription>     // propertiesToFetch [\.id]
  }
  ```
  - 基底 predicate 恆含 `importFingerprint != nil`（沿用 :10-12 的頁面範圍定義）。
  - **GOTCHA（首步實證）**：`#Predicate` 對 optional UUID 等式（`t.recorderCategoryId == categoryId`）與 optional String 若編不過 → fallback 用 `recorderCategoryName == name`（String，SRS 已核可此退路）。把實證結果寫進本檔 Notes。
  - source 篩選：`.meeting` → `recorderSourceLabel != nil`（meeting 才有 label）；`.device(id)` → `recorderSourceDeviceId == id`；`.manualImport` → 兩者皆 nil。
  - cursor 用 `(timestamp, id)` 複合（同秒多筆穩定）：predicate 加 `t.timestamp < c.0 || (t.timestamp == c.0 && t.id < c.1)`；若 #Predicate 編不過複合式 → 退回單 timestamp cursor（重複容忍，Notes 記錄）。
  - `Transcription.swift:15` 索引改為：`#Index<Transcription>([\.timestamp], [\.importFingerprint], [\.recorderCategoryId], [\.recorderFavorite], [\.recorderSourceDeviceId])`（輕遷移）。
- **VALIDATE**: 四測試 PASS。
- **COMMIT**: `feat(library): testable query builder + new indexes`

### Task 2: RecorderHistoryView 換分頁查詢層
- **ACTION**: 移除無上限 `@Query`＋記憶體 `filteredItems`；改 `RecordingLibraryQuery`＋cursor 分頁（鏡射 CURSOR_PAGINATION 的 loadInitial/loadMore/reset 三件套）；新增結果計數列（fetchCount）；新項偵測沿用 `latestTranscriptionIndicator` 模式（fetchLimit=1 @Query）。
- **TEST FIRST**: Task 1 已鎖查詢層；本 task 為 view 接線——以 build＋手動驗證（Mode B 對純 view 接線的豁免），另補一個回歸測試：
  ```swift
  func testPageAppendKeepsOrderNoDuplicates() throws { /* 兩頁 fetch 串接無重複、遞減有序 */ }
  ```
  — FAIL
- **IMPLEMENT**: view 內 `@State var query = RecordingLibraryQuery()`、`@State var items: [Transcription] = []`、`@State var totalCount = 0`、`@State var cursor: (Date, UUID)?`；`onChange(of: query)` → reset＋loadInitial；捲到底/「載入更多」→ loadMore；`filteredItems` 與 `:33-35 availableCategories`（改從 `RecorderConfigStore.shared.categories` 取）與 `:37-52` 全刪。debounce 沿用既有 `debouncedQuery` 機制餵進 `query.searchText`。
- **GOTCHA**: 既有 `.transcriptionDeleted`/`recorderImportCompleted` 通知 → reset 重載（先 grep 該 view 現有 onReceive）。
- **VALIDATE**: 測試 PASS；手動：2,000 筆種子庫初載 <1s、捲動流暢。
- **COMMIT**: `feat(library): cursor-paginated recording list`

### Task 3: FilterBar＋排序 UI
- **ACTION**: 頁首新 `LibraryFilterBar`（分類 menu、來源 menu、狀態 menu、星標 toggle、日期 presets 今天/7天/30天/自訂、排序 menu＋方向）；綁 `query` 欄位；「符合 N 筆」計數。
- **TEST FIRST**: N/A（SwiftUI 宣告）。
- **IMPLEMENT**: 放在既有搜尋列同一水平區（讀 :54-133 佈局後嵌入）；樣式沿用頁內既有 Picker/Toggle 慣例；`dateRange` presets 用 `Calendar.current` 計算。
- **VALIDATE**: build 綠＋手動組合篩選正確。
- **COMMIT**: `feat(library): filter bar + sort control`

### Task 4: 批次操作擴充＋page-scoped 檔名
- **ACTION**: 選取列（:134-150）加批次 星標/取消星標、重新分類（分類選單→逐筆 `RecorderPostProcessor.reclassify`）、重新匯出（逐筆 `export`）；「全選符合條件」用 idsDescriptor；`loadFileNames()` 全表撈（:174-180）改 page-scoped（LEDGER_PAGE_LOOKUP）。
- **TEST FIRST**（`RecordingLibraryBatchTests`）:
  ```swift
  func testBatchStarPersists() throws { /* seed 100、star ids → 全部 recorderFavorite==true 且 save */ }
  func testBatchRunnerReportsProgressAndCancel() async throws {
      // BatchRunner(items) { ... } — 進度回呼遞增；中途 cancel → 已完成保留、未跑不執行
  }
  ```
  — FAIL
- **IMPLEMENT**: 小 `BatchRunner`（@MainActor，sequential for-loop＋`@Published progress`＋`cancel()` flag；失敗逐筆記錄不中斷）；星標直改欄位＋save；reclassify/re-export 沿用 PostProcessor 現有 API（簽名見 Mandatory Reading）。進度 UI：選取列上方細 ProgressView＋取消鈕。
- **GOTCHA**: reclassify 內含 AI 呼叫（applyTemplate）——批次大時提示使用者「N 筆將呼叫 AI」確認後執行。
- **VALIDATE**: 兩測試 PASS＋手動批次 100 筆。
- **COMMIT**: `feat(library): batch star/reclassify/re-export + page-scoped ledger lookup`

### Task 5: 引用聚焦鉤子（Ask AI 落點）
- **ACTION**: `AppNavigator` 加 `@Published pendingFocusTranscriptionId: UUID?`＋`func navigate(to:focusTranscription:)`；RecorderHistoryView onReceive 消費：無篩選態下用該筆 `timestamp` 建 cursor page-in → scrollTo(id)＋高亮 2s＋開 detail sheet。
- **TEST FIRST**:
  ```swift
  func testCursorFromTimestampPagesInTarget() throws {
      // 目標在第 7 頁 → descriptor(cursor: 目標 timestamp+ε) 首頁即含目標 id
  }
  ```
  — FAIL
- **IMPLEMENT**: 鏡射 `pendingDestination` 的 replay-latest 寫法（AppNavigator.swift:13-25）；view 端 `ScrollViewReader` 已有（若無則包一層）。
- **VALIDATE**: 測試 PASS＋手動（暫以 debug 按鈕觸發 focus，Ask AI 接上後走真路徑）。
- **COMMIT**: `feat(library): row-focus navigation hook for citations`

### Task 6: 收尾
- **ACTION**: 全套 Validation → spec Change History → bump（兩處）→ `make deploy` → 回報 build 號 → Linear 驗證 issue → plan/SRS 移 completed/。
- **COMMIT**: `chore(library): bump build, docs, deploy`

---

## Testing Strategy

| Test | Input | Expected | Edge |
|---|---|---|---|
| InitialOnePage | 2,000 seed | 50 筆＋count 2000 | — |
| CombinedPredicate | 交集條件 | 與 seed 期望一致 | 空結果 |
| PageAppend | 兩頁 | 無重複、有序 | 同秒多筆 |
| SelectAllIds | 篩選 700 | ids==700 | — |
| BatchStar | 100 | 全 star＋persist | 失敗單筆不中斷 |
| BatchRunner | cancel 中途 | 已完成保留 | — |
| CursorFromTimestamp | 深頁目標 | page-in 含目標 | 目標已刪 |

### Edge Cases Checklist
- [ ] 空庫（零筆）空狀態
- [ ] 篩選變更時選取集清空提示
- [ ] 目標 focus id 已被刪（`.transcriptionDeleted`）→ toast 提示
- [ ] 排序=duration 但多筆 duration==0
- [ ] 搜尋含 emoji/全形字元

## Validation Commands
```bash
make local
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO -only-testing:VoiceInkTests
make deploy
```

### Manual Validation（→ Linear 驗證 issue）
- [ ] AC-1 千筆初載只抓一頁、<1s
- [ ] AC-2 組合篩選＋計數正確
- [ ] AC-3 批次 star→reclassify 100 筆含進度/取消
- [ ] AC-4 全選符合條件 700 筆 star
- [ ] AC-5 focus 深頁目標：page-in＋高亮＋detail
- [ ] 既有單筆操作/TranscriptSheet 全部無回歸（FR-9）

## Acceptance Criteria
- [ ] SRS AC-1〜AC-5 全過；篩選響應 <100ms@2,000（實測記錄於 report）

## Risks
| Risk | L | I | Mitigation |
|---|---|---|---|
| #Predicate optional-UUID 等式不支援 | M | M | Task 1 首步實證；fallback 用 name 欄位（SRS 核可） |
| 複合 cursor 編譯限制 | M | L | 退單 timestamp cursor＋Notes 記錄 |
| 批次 reclassify AI 費用意外 | L | M | 執行前確認 dialog 顯示筆數 |

## Notes
- RecordingCard 與 TranscriptSheet 不重構——查詢層換血、卡片沿用，是本 plan 控 scope 的關鍵。
- `recorderSourceLabel` 來自 meeting 分支；未合併前 `.meeting` 來源篩選項先隱藏（一行 if）。
