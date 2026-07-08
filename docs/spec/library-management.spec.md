# Spec: Library Management（錄音管理 / 語音管理）

## Metadata
- **Module**: library-management
- **Parent Module**: N/A
- **Sub-modules**: N/A
- **Source PRDs**: N/A — 2026-07-08 使用者需求（WP3+WP4）
- **Owner**: TBD（vi000246/VoiceInk）
- **Status**: ACTIVE — living document
- **Created**: 2026-07-08
- **Last Updated**: 2026-07-08

## Change History

| Date | Source PRD | Feature SRS | Summary |
|------|------------|-------------|---------|
| 2026-07-08 | N/A | `docs/srs/library-management-pages.srs.md` | Created — Notion 式清單頁（欄位/排序/詳情彈窗）+ 帶篩選批次刪除 + 星號保護，共用基建供「錄音管理」與新「語音管理」兩頁;修改名→匯出對齊 bug。Supersedes 未實作的 recorder-automation-recording-library SRS。尚未實作。 |

## Summary

`library-management` 提供一套共用的清單管理基建（欄位表格 + 排序 + 詳情彈窗 + 批次執行 + 純函式
篩選），供「錄音管理」（錄音輸入項）與「語音管理」（語音輸入項）兩頁使用。取代舊的展開式卡片
清單與無上限 `@Query`;錄音管理保留匯出/套範本，語音管理去掉匯出、專注瀏覽/標 tag/批次整理。

---

## Domain Model

### Bounded Context
- **Context Name**: LibraryManagement
- **Domain Layer**: Supporting Domain（在 `Transcription` 之上做管理視圖，消費 recorder-automation 的匯出/範本能力）

### Ubiquitous Language
| Term | Definition |
|------|-----------|
| 清單頁 | Notion 式欄位表格頁:日期/大小/tag/已輸出 + 可排序 + 列點擊開詳情彈窗。 |
| 詳情彈窗 | 取代 inline 展開的 popup;顯示原文/enhanced/播放/改名/star + 依頁面能力（錄音頁有套範本/匯出）。 |
| displayTag | 對外統一的 tag:錄音項 = `recorderCategoryName`，語音項 = `manualTag`。 |
| 星號保護 | 批次刪除預設排除 `recorderFavorite` 項;要刪需明確切換 + 二次警告。 |
| 窗格化渲染 | 只渲染目前可見範圍的列，避免一次渲染上千張卡片。 |

---

## System Context

### Scope & Boundaries
- **In scope**: 共用表格/彈窗/批次/篩選元件;錄音管理重構;語音管理新頁;改名→匯出對齊;`manualTag` 欄位。
- **Out of scope**: Ask AI 單檔按鈕（SRS-D，僅預留位置）;會議分類（SRS-C）;真 DB cursor 分頁。

### Actors
| Actor | Type | Interaction |
|---|---|---|
| 使用者 | Human | 瀏覽/排序/篩選/批次刪除/改名/標 tag;錄音頁另可套範本/匯出 |
| recorder-automation | Internal | 提供套範本 + Obsidian 匯出（錄音頁詳情彈窗呼叫） |
| TranscriptionStore | Internal | 集中刪除 + `.transcriptionDeleted` 廣播 |

### External Dependencies
| Dependency | Purpose | Failure Mode |
|---|---|---|
| SwiftData `Transcription` | 清單資料源 | fetch 失敗 → 空清單 |
| ImportLedgerEntry | 錄音項檔名/大小 | page-scoped 查詢;缺 → 顯示 — |

---

## Architecture

### Components
| Component | Responsibility | Interface |
|---|---|---|
| `LibraryTableView`（泛型） | 欄位表格 + 排序 header + 列點擊 | 吃 `[Transcription]` + `LibraryFilter` + 欄位設定 + onSelect |
| `LibraryDetailPopup` | 詳情彈窗（能力可組態） | 吃一筆 Transcription + 能力旗標（可匯出/可套範本/可標 tag） |
| `LibraryBatchRunner` | sequential 批次 + 進度 + 取消 | `run(items:op:)`;逐筆失敗不中斷 |
| `LibraryFilter` | 純函式篩選/排序值型別 | `apply(to: [Transcription]) -> [Transcription]`;tag/來源/星號/日期/狀態 + sort |
| `RecorderHistoryView`（改） | 錄音管理具體頁 | 用上述元件;錄音範圍（`importFingerprint != nil`） |
| `VoiceLibraryView`（新） | 語音管理具體頁 | 用上述元件;語音範圍（`importFingerprint == nil`）;無匯出 |

### Data Flow
`@Query`/fetch → `LibraryFilter.apply`（純函式篩選排序）→ `LibraryTableView` 窗格化渲染;列點擊
→ `LibraryDetailPopup`;批次 → `LibraryBatchRunner` → `TranscriptionStore.delete`（星號保護在選取層過濾）。

---

## Data Model

### Schema (new / changed)
```swift
// CHANGED Transcription — additive:
//   var manualTag: String?     // 語音項手動 tag;錄音項用 recorderCategoryName
// computed displayTag = recorderCategoryName ?? manualTag
// #Index 追加 [\.recorderFavorite]
```

### Migration Strategy
- **Forward**: `manualTag` optional → lightweight migration。索引追加安全。
- **Backward**: 移除欄位/索引無破壞。
- **Coexistence**: 舊資料 `manualTag == nil`，`displayTag` 退回 recorderCategoryName。

---

## Non-Functional Requirements

| Category | Target | Measurement | How Achieved |
|---|---|---|---|
| 響應 | 篩選/排序 <100ms@2000 | 手動計時 | 純函式 + 窗格化 + page-scoped ledger |
| 安全 | 星號零誤刪 | 單元 + 手動 | 預設排除 + 二次警告 |
| 重用 | 兩頁一套元件 | code 審查 | 泛型元件 |

---

## Technology Choices

| Concern | Choice | Alternatives | Rationale |
|---|---|---|---|
| 分頁/規模 | 純函式篩選 + 窗格化渲染 | DB cursor 分頁（巨型 #Predicate） | 本 session 兩次 #Predicate 型別檢查爆炸;瓶頸實為渲染+ledger |
| 表格 | `Table` 或自繪列（plan 定） | — | 原生排序 vs 客製互動的取捨 |
| tag | 統一 `displayTag`（錄音=category、語音=manualTag） | 兩套欄位 | UI 一致 |

---

## Integration Points

| Touchpoint | Type | Contract | Backwards Compat |
|---|---|---|---|
| `RecorderHistoryView`（`Views/History/RecorderHistoryView.swift`） | 重構 | 換表格/彈窗;保留單筆動作 | 卡片能力保留 |
| `InlineHistoryView`（`.history`） | 取代 | 語音項移到 `VoiceLibraryView` | 歷史窗獨立視窗可留 |
| `VaultExportService.suggestedFileName` / `RecorderPostProcessor.exportToVault` | 改檔名來源 | 用 `recorderTitle` | Yes |
| `TranscriptionStore.delete` | 批次刪除 | 星號保護在選取層 | Yes |
| `ViewType`/`AppSidebar`（承 SRS-A） | UI 註冊 | +`.voiceLibrary`、移除 `.history` 主頁角色 | 5 處 + assert |

### Rollout Strategy
無 flag。`manualTag` 遷移自動。Rollback = 還原 `RecorderHistoryView` 舊版 + 移欄位。

---

## Codebase Patterns to Follow

| Pattern | Where to Find | Why Follow |
|---|---|---|
| 現有選取/批次刪除/shift 範圍 | `RecorderHistoryView.swift:134-172` | 批次基礎 |
| 集中刪除 + 廣播 | `Services/TranscriptionStore.swift` | 刪除路徑 |
| page-scoped ledger 概念 | `RecorderHistoryView.swift:174-180`（改造目標） | 檔名查詢 |
| 詳情內容 | `Views/History/TranscriptionDetailView.swift` | 彈窗內容重用 |
| additive Transcription 欄位 | `Models/Transcription.swift:37-47` | `manualTag` |
| 批次 runner + 進度/取消 | 本 session `MeetingCaptureController` 保檔思路 | `LibraryBatchRunner` |

---

## Risks & Trade-offs

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| 星號誤刪 | M | H | 預設排除 + 明確切換 + 二次警告（AC-1） |
| 窗格化在極大量仍卡 | L | M | 個人規模足夠;必要時再上 cursor |
| `RecorderHistoryView` 重構回歸單筆動作 | M | M | 保留卡片能力於彈窗;FR-9 零回歸 AC |
| 改名→匯出改動影響既有匯出檔名慣例 | L | M | 只換檔名來源，日期規則不變（AC-2） |

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|---|---|---|---|
| 規模策略 | 窗格化渲染 | DB cursor 分頁 | #Predicate 型別檢查風險;瓶頸實為渲染 |
| 兩頁關係 | 共用元件 + 兩具體頁 | 各自實作 | 重用、一致 |
| tag 模型 | `displayTag` 統一 | 兩套欄位 | UI 一致 |

---

## Open Questions

- [ ] `Table` vs 自繪列。
- [ ] 語音項檔案大小來源。
- [ ] 詳情彈窗尺寸/多開。
