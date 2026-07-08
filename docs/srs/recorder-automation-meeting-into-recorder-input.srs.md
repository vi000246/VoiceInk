---
linear_issue: null
---
# SRS: 會議錄製併入錄音輸入（手動選範本，不自動標會議）（WP5）

## Metadata
- **Module**: `recorder-automation`
- **Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source PRD**: N/A（2026-07-08 使用者需求）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-08
- **Grill level**: 1 (standard)

## Feature Summary

會議錄製（已實作，build 227-229）目前會**自動固定歸類到「會議」分類**。改成:會議錄音**併入
一般錄音輸入流程**，走與錄音筆匯入相同的分類/手動處理路徑，由使用者在錄音管理**手動選要套哪個
範本**，而不是自動標會議。

## Delta from Current Module State

> 見 `docs/spec/recorder-automation.spec.md`。本 SRS 只反轉會議的「固定分類」行為。

### Changed Business Logic

- **移除會議固定分類自動套用**:`AudioFileTranscriptionManager` 對 `.meetingCapture` 目前呼叫
  `RecorderPostProcessor.process(fixedCategory: RecorderConfigStore.shared.meetingFixedCategory, …)`。
  改為傳 `fixedCategory: nil`，讓會議項走**與 `.recorderImport` 相同**的
  「classify-or-suggest + 尊重自動匯出開關 + 錄音管理手動套範本」路徑。
- **設定簡化**:錄音設定的「會議錄製 → 固定分類」picker 語意調整——保留為**選填的預設建議分類**
  （非強制固定），或移除（plan 定;預設行為改為自動分類/手動）。`meetingMicEnabled` 不動。
- **來源標籤保留**:`recorderSourceLabel`（「會議 · Zoom」）仍寫入，供錄音管理 tag/篩選辨識來源;
  只是不再據此固定分類。
- **側欄歸屬**:會議錄製設定併入「錄音輸入」群（承 SRS-A 的區塊更名，無新頁）。

### Explicitly Out of Scope

- 會議擷取的音訊管線（tap/aggregate/mixer）完全不動。
- 錄音管理頁本身（SRS-B）;此處只確保會議項在該頁能被手動套範本（與其他錄音項一致）。

## Functional Requirements

- [ ] **FR-1** 會議錄音停止後匯入，**不自動套「會議」固定分類**;走一般錄音輸入後處理。
- [ ] **FR-2** 自動匯出關（預設）時，會議項停在錄音管理待手動套範本;開時走一般自動分類（非固定會議）。
- [ ] **FR-3** `recorderSourceLabel`「會議 · <app>」仍保留，錄音管理可據此篩選/顯示。
- [ ] **FR-4** 既有非會議錄音項行為零回歸。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 一致性 | 會議項與錄音筆項同一處理路徑 | 共用 `process(fixedCategory: nil)` |
| 相容性 | 已存在的會議項不受影響 | 僅改新匯入路徑 |

## Acceptance Criteria

### AC-1: 會議不自動標會議
- **Given**: 有多個分類、自動匯出關
- **When**: 錄一段會議並停止
- **Then**: 該項匯入後**未**被固定標「會議」;停在錄音管理待手動套範本;來源標籤仍「會議 · <app>」
- **Test**: `MeetingIntoRecorderTests::noFixedMeetingCategory`

### AC-2: 自動匯出開時走一般分類
- **Given**: 自動匯出開
- **When**: 會議停止
- **Then**: 走一般 AI 分類（可能分到任何合適分類，非強制會議）
- **Test**: 手動

## Open Questions

- [ ] 「會議錄製 → 固定分類」設定要保留為選填建議、還是整個移除（傾向移除或改「預設建議分類」）。
