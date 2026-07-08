---
linear_issue: null
---
# SRS: Ask AI 增強（答案模型 / 來源 / 單檔提問 / Ask AI 範本）（WP6）

## Metadata
- **Module**: `ask-ai`
- **Module Spec**: `docs/spec/ask-ai.spec.md`
- **Source PRD**: N/A（2026-07-08 使用者需求）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-08
- **Grill level**: 1 (standard)

## Feature Summary

在已實作的 Ask AI（build 231）上增強:(1) **可選更強的答案模型**（如 Gemini Pro）;(2) 來源篩選
只剩**語音輸入／錄音輸入**（會議歸錄音輸入）;(3) **單檔提問**——在錄音管理／語音管理對單一錄音檔
按「Ask AI」直接問;(4) **Ask AI 範本頁**——預載 system prompt（例如「你是面試專家」）再分析錄音;
(5) Ask AI 成為**獨立側欄群組**（承 SRS-A 空群組，這裡補範本頁）。

## Delta from Current Module State

> 見 `docs/spec/ask-ai.spec.md`。以下為增量。

### New / Changed Data Models

- **NEW** `AskAITemplate`（`@Model` 於既有 `index.store`）:`{id, title, systemPrompt, createdAt}`——
  一段預載的 system prompt，問答時可取代/前置預設 system prompt。
- **CHANGED** `AskAIScope` 增 `transcriptionId: UUID?`（單檔提問時限定該筆的塊）。
- **設定（UserDefaults）**:`askAIAnswerProvider` / `askAIAnswerModel`——Ask AI 專用答案模型（獨立於
  AI Models 的 enhancement 預設）。

### Changed Business Logic

- **答案模型**:`AskAIView` 的 `LiveChatCompleter` 改用 `askAIAnswerProvider/Model`（設定選;預設
  沿用 `aiService.selectedProvider`）。設定頁提供 provider+model picker（可選 Gemini Pro 等推理強的）。
- **來源映射**:UI scope 來源選項改「語音輸入／錄音輸入」兩項。映射到既有 chunk `sourceKind`:
  語音輸入 → `{dictation}`;錄音輸入 → `{recorder, meeting}`。`RetrievalService` 的 sources 過濾
  接受多值集合（已支援）。
- **單檔提問**:`RetrievalService.retrieve` / `AskAIScope` 支援 `transcriptionId` 前置過濾（只比對該
  筆的塊）。錄音管理／語音管理的詳情彈窗/列動作加「Ask AI」按鈕 → 開 Ask AI 頁並帶入該筆 scope
  （`AppNavigator` 傳遞 transcriptionId + 進入 Ask AI）。
- **Ask AI 範本**:問答時可選一個 `AskAITemplate`;選了則其 `systemPrompt` 取代（或前置）預設
  system prompt，再接檢索片段與問題。範本頁在 Ask AI 群組（CRUD 列表，鏡射共用範本頁樣式）。
- **側欄**:Ask AI 群組（承 SRS-A）新增 `.askAITemplates` 項;`.askAI` 續在該群。

### Explicitly Out of Scope

- 索引/嵌入/檢索核心演算法不動（沿用既有）。
- Ask AI 範本與「共用範本」是**兩套**（共用範本用於改寫輸出;Ask AI 範本用於問答 persona）。

## Functional Requirements

- [ ] **FR-1** Ask AI 設定可選專用答案模型（provider+model），預設沿用 enhancement 預設。
- [ ] **FR-2** 來源篩選只有語音輸入／錄音輸入;錄音輸入涵蓋 recorder+meeting。
- [ ] **FR-3** `AskAIScope.transcriptionId` 限定單筆;`RetrievalService` 據此前置過濾。
- [ ] **FR-4** 錄音管理／語音管理對單筆可按「Ask AI」→ 開 Ask AI 並限定該筆提問。
- [ ] **FR-5** `AskAITemplate` CRUD;問答可選範本，其 systemPrompt 生效於該次問答。
- [ ] **FR-6** Ask AI 範本頁在 Ask AI 側欄群組;`.askAI` + `.askAITemplates` 兩項。
- [ ] **FR-7** 引用/短路/持久化等既有行為零回歸。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 品質 | 可用推理更強模型提升回答 | 專用答案模型 picker |
| 精準 | 單檔提問只引用該筆 | scope transcriptionId 前置過濾 |
| 一致 | 範本頁樣式比照共用範本 | 重用 CRUD 列表樣式 |

## Acceptance Criteria

### AC-1: 專用答案模型
- **Given**: Ask AI 設定選 Gemini Pro
- **When**: 提問
- **Then**: 答案由該模型生成（非 enhancement 預設）
- **Test**: 手動 + `AskAISettingsTests::answerModelResolves`

### AC-2: 來源映射
- **Given**: 語音、錄音、會議各有已索引內容
- **When**: scope 選「錄音輸入」
- **Then**: 檢索候選含 recorder+meeting、不含 dictation
- **Test**: `RetrievalService` scope 測試擴充（sources={recorder,meeting}）

### AC-3: 單檔提問
- **Given**: 在錄音管理某筆按 Ask AI
- **When**: 提問
- **Then**: 只引用該筆的塊;跳到 Ask AI 頁且 scope 已限定該筆
- **Test**: `AskAIScopeTests::singleTranscriptionRestricts`

### AC-4: Ask AI 範本
- **Given**: 建一個「你是面試專家」範本
- **When**: 選它並問某面試錄音
- **Then**: system prompt 生效（回答帶面試專家視角）;引用仍只來自檢索集
- **Test**: `AskAIAnswerTests::templateSystemPromptApplied`

## Open Questions

- [ ] Ask AI 範本的 systemPrompt 是**取代**還是**前置**於預設 system prompt（傾向:取代 persona 段、
  保留引用規則段）——plan 定。
- [ ] 單檔提問是否在 Ask AI 頁用一個「限定:<標題>」的 chip 顯示可清除。
