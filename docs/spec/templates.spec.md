# Spec: Templates（共用範本庫）

## Metadata
- **Module**: templates
- **Parent Module**: N/A
- **Sub-modules**: N/A
- **Source PRDs**:
  - N/A — 2026-07-08 使用者需求（WP1+WP2），SRS `docs/srs/templates-shared-library-and-ia.srs.md`
- **Source Linear Issue**: N/A
- **Owner**: TBD（personal fork — vi000246/VoiceInk）
- **Status**: ACTIVE — living document
- **Created**: 2026-07-08
- **Last Updated**: 2026-07-08

## Change History

| Date | Source PRD | Feature SRS | Summary |
|------|------------|-------------|---------|
| 2026-07-08 | N/A | `docs/srs/completed/templates-shared-library-and-ia.srs.md` | **Implemented (build 233).** Tasks 1-5,7: `TemplateCategory` + `CustomPrompt.categories`; single `TemplateStore` + idempotent startup migration (voice→.voiceInput / recorder→.recorderInput, old keys retained); `AIEnhancementService.customPrompts` & `RecorderConfigStore.recorderPrompts` now computed views over the store with Combine forwarding; obsolete library-split migrations neutralized; PromptEditorView 「套用於」category checkboxes; sidebar IA (錄音範本→錄音模式, 語音範本→共用範本 in 共用與系統, Recorder→Obsidian→錄音輸入, Ask AI own group, 語音輸入 group). Task 6 (picker「顯示全部類別」toggle) deferred — pickers already show correct subsets via computed views. 91 tests green. |
| 2026-07-08 | N/A | `docs/srs/completed/templates-shared-library-and-ia.srs.md` | Created from brownfield analysis — 把分開的語音範本庫（`AIEnhancementService.customPrompts` / UserDefaults `customPrompts`）與錄音範本庫（`RecorderConfigStore.recorderPrompts` / `recorderCategoryPromptsV1`）合併為單一 `TemplateStore`，`CustomPrompt` 加 `categories: [TemplateCategory]`，語音/錄音模式以類別多選篩選共用範本；連帶側欄 IA 重構（更名/分組/Ask AI 群組）。尚未實作。 |

## Summary

`templates` 把 VoiceInk 目前散在兩個模組的「AI 改寫範本」統一成一份共用庫。每個範本
（`CustomPrompt`）標註可套用的輸入類別（語音輸入／錄音輸入，可多選），語音模式與錄音模式編輯
時各自以類別篩選挑範本，讓同一份範本能跨兩種輸入共用。核心是**在保留既有綁定（範本 id、模式
`selectedPrompt`、分類 `customPromptId`）不變的前提下換掉底層儲存來源**，把重構半徑壓到最小。

---

## Domain Model

### Bounded Context
- **Context Name**: Templates
- **Domain Layer**: Supporting Domain（被 voice-input 的 Modes 與 recorder-automation 的 Categories 消費）

### Ubiquitous Language
| Term | Definition |
|------|-----------|
| 範本 / Template | 一段 AI 改寫指令，模型 `CustomPrompt`（`{id, title, promptText, useSystemInstructions}`）。 |
| Template Category | 範本可套用的輸入類別:`.voiceInput`（語音輸入）/ `.recorderInput`（錄音輸入）。一個範本可多屬。 |
| 共用範本庫 / Shared Library | 單一權威範本集合，`TemplateStore.templates`。取代舊的語音／錄音兩個分離陣列。 |
| 類別視圖 | `templates(for:)` 依類別過濾的 computed 視圖;舊呼叫端（語音/錄音）透過它取到各自的子集。 |
| 遷移旗標 | `sharedTemplatesV1` UserDefaults key 存在即代表已完成一次性合併遷移。 |

### Domain Events
| Event | Trigger Condition | Consumers |
|---|---|---|
| 範本庫變動（`@Published templates`） | upsert/delete/遷移 | 語音模式 picker、錄音分類 picker、共用範本頁 |

---

## System Context

### Scope & Boundaries
- **In scope**: `CustomPrompt` 資料模型擴充（categories）；`TemplateStore` 單一庫 + 遷移；語音/錄音
  模式 picker 的類別篩選；範本編輯器類別控制；側欄 IA 重構（更名/分組/Ask AI 空群組）。
- **Out of scope**: 錄音/語音管理頁（SRS-B）；會議錄製（SRS-C）；Ask AI 功能與範本頁（SRS-D）；
  雲端同步；輸入歷史頁的實際拆分（SRS-B 連頁面一起）。

### Actors
| Actor | Type | Interaction |
|---|---|---|
| 使用者 | Human | 建立/編輯範本並勾選類別;在模式編輯時用類別篩選挑範本 |
| 語音模式（voice-input Modes） | Internal | 以 `selectedPrompt`(id) 取範本;來源改為 `templates(for: .voiceInput)` |
| 錄音分類（recorder-automation Categories） | Internal | 以 `customPromptId` 取範本;來源改為 `templates(for: .recorderInput)` |

### External Dependencies
| Dependency | Purpose | Failure Mode |
|---|---|---|
| UserDefaults | 範本庫 JSON 持久化（key `sharedTemplatesV1`） | 讀取失敗 → 空庫 + 保留舊 key 供 rollback |

---

## Architecture

### High-Level Diagram
```
        ┌──────────────────────── TemplateStore (@MainActor, 單一權威) ────────────────────────┐
        │  @Published templates: [CustomPrompt]   (UserDefaults "sharedTemplatesV1")            │
        │  templates(for: .voiceInput) / templates(for: .recorderInput) / template(byId:)       │
        └───────────▲───────────────────────────────────────────────▲──────────────────────────┘
   computed 視圖     │                                                 │  computed 視圖
   AIEnhancementService.customPrompts                    RecorderConfigStore.recorderPrompts
        │ (語音模式 picker: selectedPrompt id)                 │ (錄音分類 picker: customPromptId)
        ▼                                                     ▼
   ModeConfig.selectedPrompt (UUID str, 不變)          RecorderCategory.customPromptId (UUID?, 不變)

   一次性遷移: "customPrompts"→.voiceInput  +  "recorderCategoryPromptsV1"→.recorderInput  →  "sharedTemplatesV1"
```

### Components
| Component | Responsibility | Interface |
|---|---|---|
| `TemplateStore` | 共用範本庫單一權威 + 遷移 | `@MainActor` singleton;`templates`、`templates(for:)`、`template(byId:)`、`upsert`、`delete`、`migrateIfNeeded()` |
| `CustomPrompt`（擴充） | 範本值型別 + `categories` | 既有 struct 加 `categories: [TemplateCategory]`（decodeIfPresent） |
| `AIEnhancementService.customPrompts`（改） | 語音模式可見範本 | computed → `TemplateStore.shared.templates(for: .voiceInput)`;`add/update/delete` 轉呼 store |
| `RecorderConfigStore.recorderPrompts`（改） | 錄音分類可見範本 | computed → `templates(for: .recorderInput)`;`recorderPrompt(byId:)` 查共用庫 |
| 範本編輯器（`PromptEditorView`） | 編輯 + 類別多選 | 既有 UI 加類別 chips 控制 |
| 模式/分類範本 picker | 依類別篩選挑範本 | 資料源改 `templates(for:)` + 多選篩選切換 |
| `ViewType` / `AppSidebar` | IA 重構 | 更名/分組/Ask AI 群組（5 處 exhaustive + assert） |

### Data Flow
範本編輯 → `TemplateStore.upsert` → `@Published` 觸發語音/錄音兩個 computed 視圖刷新 → 兩種模式
picker 即時更新。模式套用時仍用既有 id 綁定（`selectedPrompt` / `customPromptId`）查 store。

---

## Data Model

### Schema (new / changed)
```swift
enum TemplateCategory: String, Codable, CaseIterable { case voiceInput, recorderInput }

struct CustomPrompt {   // 既有;新增 categories（additive、decodeIfPresent ?? []）
    let id: UUID
    let title: String
    let promptText: String
    let useSystemInstructions: Bool
    var categories: [TemplateCategory]   // NEW;空＝未分類（遷移填入至少一類）
}
```

### Migration Strategy
- **Forward**: 首次無 `sharedTemplatesV1` 時，讀舊 `customPrompts`（標 `.voiceInput`）+
  `recorderCategoryPromptsV1`（標 `.recorderInput`），合併寫入 `sharedTemplatesV1`。
- **Backward**: 舊兩個 key **保留不刪**;移除本功能即回退到分離庫（rollback 安全）。
- **Coexistence**: 遷移後舊 key 不再寫入;`customPrompts`/`recorderPrompts` 變 computed，呼叫端無感。
- **Backfill**: 遷移即 backfill（一次性）。

---

## Non-Functional Requirements

| Category | Target | Measurement | How Achieved |
|---|---|---|---|
| 相容性 | 既有模式/分類綁定零斷裂 | 遷移單元測試 | 範本 id 不變 + computed 視圖透明 |
| 安全遷移 | 遷移失敗不遺失資料 | code 審查 | 舊 key 保留;遷移冪等旗標 |
| 一致性 | 編輯即時反映兩 picker | 手動 | 單一 `@Published` 來源 |

---

## Technology Choices

| Concern | Choice | Alternatives | Rationale |
|---|---|---|---|
| 範本庫合併 | 單一 `TemplateStore` + 類別標籤 | 兩庫互見/雙寫 | 「共用」語意＝一份資料多歸屬;雙寫會同步衝突（使用者決策） |
| 舊呼叫端相容 | `customPrompts`/`recorderPrompts` 改 computed 視圖 | 全面改呼叫端 | 壓縮重構半徑，零回歸風險 |
| 持久化 | UserDefaults JSON（`sharedTemplatesV1`） | SwiftData | 沿用既有範本儲存慣例（兩者本就 UserDefaults） |
| 類別型別 | `enum TemplateCategory`（`[.]` 陣列） | Set / 位元遮罩 | Codable 直覺、CaseIterable 好做 UI |

---

## Integration Points

| Touchpoint | Type | Contract | Backwards Compat |
|---|---|---|---|
| `AIEnhancementService.customPrompts`（`:11`）| 讀（computed 化） | 回傳 `.voiceInput` 子集 | Yes — 呼叫端無感 |
| `RecorderConfigStore.recorderPrompts`/`recorderPrompt(byId:)`（`:25,265`）| 讀（查共用庫） | 回傳 `.recorderInput` 子集 | Yes |
| `ModeConfig.selectedPrompt`（`Modes/ModeConfig.swift:75`）| id 綁定 | 不變 | Yes |
| `RecorderCategory.customPromptId`（`:9`）| id 綁定 | 不變 | Yes |
| `PromptEditorView` | UI | 加類別多選 | Yes — additive |
| `ViewType`/`AppSidebar`（`ContentView.swift:4-23`、`AppSidebar.swift:74-162`）| UI 註冊 | 更名/分組 | Yes — 5 處同步 + assert |

### Rollout Strategy
無 flag;遷移在首次啟動自動執行且冪等。Rollback = 移除模組並讓舊兩個 key 重新生效（值仍在）。

---

## Codebase Patterns to Follow

| Pattern | Where to Find | Why Follow |
|---|---|---|
| UserDefaults JSON 陣列庫 | `RecorderConfigStore.swift:113-115,261`（recorderPrompts 存取） | `TemplateStore` 持久化樣式 |
| `@Published` 陣列 + save on didSet | `AIEnhancementService.swift:11-21`（customPrompts） | store 的 published 樣式 |
| additive Codable 欄位 | `CustomPrompt.init(from:):26-32`（decodeIfPresent） | `categories` 向後相容 |
| 一次性遷移旗標 | `VoiceInk.swift`（`recorderDefaultsSeededV1` seed 慣例） | 遷移冪等旗標 |
| ViewType 5-處註冊 + assert | 本 session `.askAI` 註冊（`ContentView`/`AppSidebar`） | 側欄改動 |

---

## Risks & Trade-offs

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| 遷移把某範本標錯類別 → 模式 picker 看不到 | M | M | 遷移規則簡單（來源即類別）;AC-1 驗證;舊 key 可 rollback |
| computed 化 `customPrompts` 破壞既有 setter 呼叫端 | M | H | 保留 `add/update/delete` 方法，內部轉呼 store;grep 全部呼叫點 |
| 側欄改動漏一處 → DEBUG assert 掛 | L | L | assert 即時抓;5 處清單化 |
| 範本全空類別成孤兒（picker 都看不到） | M | M | 編輯器至少一類防呆;遷移保證每筆有一類 |

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|---|---|---|---|
| 範本庫 | 單一共用庫 + 類別標籤 | 兩庫互見 | 使用者決策;共用語意 |
| 舊呼叫端 | computed 視圖相容 | 全面改寫 | 最小重構半徑 |
| 輸入歷史拆分 | 延到 SRS-B（連頁面） | 本 SRS 一起改 | 避免側欄指向不存在的頁 |
| Ask AI 群組 | 本 SRS 只建空群組移入現有頁 | 一起做 Ask AI 增強 | 增強屬 SRS-D |

---

## Open Questions

- [ ] 新建範本的預設勾選類別（依進入點推斷）。
- [ ] 共用範本頁是否顯示每筆的類別 chips。
