---
linear_issue: null
---
# Plan: Ask AI 增強（WP6）

> Mode B。在已實作 Ask AI（build 231）上加增量:答案模型 picker、來源映射、單檔提問、Ask AI 範本頁。

## Summary
Ask AI 增強:(1) 專用答案模型 picker（可選 Gemini Pro）;(2) 來源篩選改語音輸入/錄音輸入（會議歸錄音）;
(3) `AskAIScope.transcriptionId` 單檔提問（錄音/語音管理列上 Ask AI 按鈕）;(4) `AskAITemplate` 預載
persona system prompt + 範本頁;(5) Ask AI 獨立側欄群 +`.askAITemplates`。

## User Story
As a 想深入分析特定錄音的使用者, I want 用更強的模型、預載分析角色、針對單一錄音提問, so that 得到更貼切的分析。

## Problem → Solution
答案模型固定跟隨 enhancement 預設、來源三分、只能全庫問、無 persona → 專用模型 picker + 來源二分映射 +
transcriptionId scope + AskAITemplate。

## Metadata
- **Module**: ask-ai
- **Parent Plan**: docs/plans/library-management-pages.plan.md（單檔 Ask AI 按鈕在管理頁詳情彈窗）
- **Source Feature SRS**: docs/srs/ask-ai-enhancements.srs.md
- **Source Module Spec**: docs/spec/ask-ai.spec.md
- **Source Linear Issue**: N/A
- **Type**: feature ｜ **Size**: M ｜ **Complexity**: Medium
- **Rigor**: balanced ｜ **Mode**: B ｜ **TDD**: on ｜ **Commit cadence**: per-task
- **Estimated Files**: ~10（4 modified + 3 created + tests）

---

## Mandatory Reading
| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | docs/srs/ask-ai-enhancements.srs.md | all | 需求 + AC |
| P0 | docs/spec/ask-ai.spec.md | all | 架構 |
| P0 | VoiceInk/Services/AskAI/RetrievalService.swift | all | AskAIScope + retrieve（加 transcriptionId） |
| P0 | VoiceInk/Services/AskAI/AskAIService.swift | all | ask()、systemPrompt（範本注入） |
| P0 | VoiceInk/Views/AskAI/AskAIView.swift | all | 答案模型 picker、來源 chips、範本選擇 |
| P1 | VoiceInk/Models/AskAIModels.swift | all | 加 AskAITemplate @Model |
| P1 | VoiceInk/Services/AskAI/TranscriptIndexService.swift | sourceKind | 來源映射（recorder+meeting） |
| P1 | VoiceInk/Services/AppNavigator.swift | navigate | 單檔跳轉帶 transcriptionId scope |
| P1 | VoiceInk/Views/Settings/PromptsManagementView.swift | CRUD 樣式 | Ask AI 範本頁鏡射 |
| P1 | VoiceInk/Views/ContentView.swift + AppSidebar.swift | 註冊 | +.askAITemplates 於 Ask AI 群 |

## Patterns to Mirror
### ANSWER_COMPLETER（現況，改用專用模型）
```swift
// SOURCE: AskAIView.swift LiveChatCompleter — 目前 provider = aiService.selectedProvider
// 改讀 askAIAnswerProvider/Model（UserDefaults），predelt 沿用 selectedProvider
```
### SCOPE_PREFILTER（RetrievalService，加 transcriptionId）
```swift
// SOURCE: RetrievalService.swift — 目前 predicate = embeddingModel + date;sources/category in-memory
// 加 transcriptionId：若 scope.transcriptionId 非 nil，candidates.filter { $0.transcriptionId == id }（in-memory，避 optional predicate）
```
### INDEX_MODEL @Model
```swift
// SOURCE: AskAIModels.swift（EmbeddingChunk/AskAIThread @Model 樣式）— AskAITemplate 鏡射
```
### CITATION_TEMPLATE_STORE（Ask AI 範本頁）
```swift
// SOURCE: PromptsManagementView.swift（共用範本 CRUD 列表樣式）
```

## Files to Change
| File | Action | Justification |
|---|---|---|
| VoiceInk/Models/AskAIModels.swift | UPDATE | +AskAITemplate @Model |
| VoiceInk/Services/AskAI/RetrievalService.swift | UPDATE | AskAIScope.transcriptionId 前置過濾 |
| VoiceInk/Services/AskAI/AskAIService.swift | UPDATE | 答案模型解析、範本 systemPrompt 注入 |
| VoiceInk/Views/AskAI/AskAIView.swift | UPDATE | 答案模型 picker、來源二分 chips、範本選擇、單檔限定 chip |
| VoiceInk/Views/AskAI/AskAITemplatesView.swift | CREATE | Ask AI 範本 CRUD 頁 |
| VoiceInk/Views/Library/LibraryDetailPopup.swift | UPDATE | Ask AI 按鈕（單檔提問） |
| VoiceInk/Services/AppNavigator.swift | UPDATE | 帶 transcriptionId 進 Ask AI |
| VoiceInk/Views/ContentView.swift + AppSidebar.swift | UPDATE | +.askAITemplates |
| VoiceInkTests/AskAIScopeTests.swift + AskAIEnhancementTests.swift | CREATE | scope/映射/範本/模型 |

## NOT Building
- 索引/嵌入核心不動;共用範本（那是改寫範本，非 Ask AI persona）。

## Step-by-Step Tasks

### Task 1: 答案模型 picker
- **ACTION**: Ask AI 專用 provider+model（UserDefaults `askAIAnswerProvider`/`askAIAnswerModel`），預設沿用 enhancement。
- **TEST FIRST**:
  ```swift
  func testAnswerModelResolvesToConfiguredOrDefault() {
      // 未設 → 回 aiService.selectedProvider;設了 Gemini → 回 Gemini（把解析抽成純函式 resolveAnswerModel()）
  }
  ```
  Run — FAIL
- **IMPLEMENT**: `AskAIView` 設定選單加 provider+model picker（鏡射 recorder 的 model picker）;`LiveChatCompleter` 用解析後的 provider/model。
- **VALIDATE**: 測試 PASS;手動 AC-1。
- **COMMIT**: `feat(ask-ai): dedicated answer model picker`

### Task 2: 來源二分映射
- **ACTION**: UI 來源 = 語音輸入/錄音輸入;映射 sourceKind（語音→{dictation}、錄音→{recorder,meeting}）。
- **TEST FIRST**（擴充 `AskAIRetrievalTests`）:
  ```swift
  func testRecorderSourceIncludesMeeting() {
      // seed dictation/recorder/meeting chunk;scope sources={recorder,meeting} → 不含 dictation
  }
  ```
  Run — FAIL（若既有已支援多值集合則直接綠，改測 UI 映射函式）
- **IMPLEMENT**: `AskAIView` scope chips 改兩項;`currentScope` 映射 sources 集合。
- **VALIDATE**: 測試 PASS;手動 AC-2。
- **COMMIT**: `feat(ask-ai): source filter voice/recorder (meeting under recorder)`

### Task 3: 單檔提問 scope
- **ACTION**: `AskAIScope.transcriptionId` + retrieve 前置過濾 + 管理頁按鈕 + 跳轉。
- **TEST FIRST**（`AskAIScopeTests`）:
  ```swift
  @MainActor func testSingleTranscriptionRestricts() throws {
      // 兩筆 transcription 各有塊;scope.transcriptionId = A → 檢索只回 A 的塊
  }
  ```
  Run — FAIL
- **IMPLEMENT**:
  - `AskAIScope` 加 `var transcriptionId: UUID?`;`RetrievalService.retrieve` fetch 後 `if let tid = scope.transcriptionId { candidates = candidates.filter { $0.transcriptionId == tid } }`（in-memory，避 optional predicate）。
  - `AppNavigator`：`navigate(to: .askAI, focusRecording: UUID)`（新 companion `@Published pendingAskTranscriptionId`）。
  - `LibraryDetailPopup` 加「Ask AI」按鈕 → 呼叫上述跳轉。
  - `AskAIView` 消費 `pendingAskTranscriptionId` → 設 scope.transcriptionId + 顯示「限定:<標題>」chip 可清除。
- **VALIDATE**: 測試 PASS;手動 AC-3。
- **COMMIT**: `feat(ask-ai): single-recording query from management pages`

### Task 4: AskAITemplate + 範本頁 + 注入
- **ACTION**: `AskAITemplate` @Model;範本頁 CRUD;問答選範本 → systemPrompt 注入。
- **TEST FIRST**（`AskAIEnhancementTests`）:
  ```swift
  func testTemplateSystemPromptApplied() {
      // buildSystemPrompt(template: 面試專家) → 含 persona 段 + 保留引用規則段
      // （把 systemPrompt 組裝抽成 static 純函式 systemPrompt(persona:) 測試）
  }
  ```
  Run — FAIL
- **IMPLEMENT**:
  - `AskAIModels.swift` 加 `@Model AskAITemplate { id/title/systemPrompt/createdAt }`（進 index.store schema——兩 factory 都加）。
  - `AskAIService.systemPrompt` 改成 `systemPrompt(persona: String?)`：persona 非 nil → 取代 persona 段、**保留**引用規則段（「只根據片段…標 [n]…找不到就說找不到」）。
  - `AskAIView`：問答列加範本選擇（下拉）;選了則 ask 帶 persona。
  - `AskAITemplatesView`（新頁，鏡射 PromptsManagementView CRUD）;側欄 `.askAITemplates` 於 Ask AI 群（5 處註冊）。
- **VALIDATE**: 測試 PASS + build（sidebar assert）;手動 AC-4。
- **COMMIT**: `feat(ask-ai): Ask AI templates (persona system prompts) + page`

### Task 5: 收尾
- **ACTION**: build+test;ask-ai.spec Change History 加 implemented;bump build;`make deploy`;回報;plan/SRS 移 completed。
- **COMMIT**: `chore(ask-ai): bump build, docs, deploy`

## Testing Strategy
| Test | Input | Expected | Edge |
|---|---|---|---|
| AnswerModel | 設/未設 | 專用/預設 | — |
| SourceMapping | 三類 | 錄音含 meeting | — |
| SingleScope | transcriptionId | 只該筆 | 已刪 |
| TemplatePersona | persona | 注入+保留引用規則 | nil→原 prompt |

### Edge Cases Checklist
- [ ] 單檔目標已刪 → 提示
- [ ] 範本 persona 不覆蓋引用規則（否則幻覺防護失效）
- [ ] 答案模型未設金鑰 → 沿用既有錯誤處理
- [ ] 側欄漏 .askAITemplates → assert

## Validation Commands
```bash
make local
xcodebuild test … -only-testing:VoiceInkTests
make deploy
```
### Manual Validation
- [ ] AC-1 選 Gemini Pro 生效
- [ ] AC-2 來源錄音含會議
- [ ] AC-3 管理頁單檔 Ask AI → 只引用該筆
- [ ] AC-4 面試專家範本 → 回答帶視角、引用仍受控

## Acceptance Criteria
- [ ] SRS AC-1〜AC-4;既有 Ask AI 零回歸

## Risks
| Risk | L | I | Mitigation |
|---|---|---|---|
| 範本 persona 覆蓋掉引用規則 → 幻覺 | M | H | systemPrompt 分段:persona 可換、引用規則段固定保留;AC-4 對照題 |
| index.store 加 AskAITemplate 遷移 | L | M | additive @Model;兩 factory 同步 |

## Notes
- 依賴 SRS-B（單檔 Ask AI 按鈕在 LibraryDetailPopup）與 SRS-A（Ask AI 群）。
