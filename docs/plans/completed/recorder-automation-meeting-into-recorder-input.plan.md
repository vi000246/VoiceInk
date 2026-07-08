---
linear_issue: null
---
# Plan: 會議錄製併入錄音輸入（WP5）

> Mode B。小範圍行為反轉：會議項不再自動固定「會議」分類，改走一般錄音輸入路徑。

## Summary
把會議擷取（`.meetingCapture`）的後處理從「固定會議分類」改成「與 `.recorderImport` 相同」的一般路徑
（`process(fixedCategory: nil)`），由使用者在錄音管理手動套範本。`recorderSourceLabel` 保留供 tag/篩選。

## User Story
As a 錄會議的使用者, I want 會議錄音進來後由我手動選範本, so that 不被自動標成會議、能套更貼切的範本。

## Problem → Solution
`AudioFileTranscriptionManager` 對 `.meetingCapture` 傳 `fixedCategory: meetingFixedCategory` → 改傳 `nil`，
會議項走一般 classify-or-manual 流程。

## Metadata
- **Module**: recorder-automation
- **Parent Plan**: docs/plans/templates-shared-library-and-ia.plan.md（側欄「錄音輸入」群名依賴 SRS-A）
- **Source Feature SRS**: docs/srs/recorder-automation-meeting-into-recorder-input.srs.md
- **Source Module Spec**: docs/spec/recorder-automation.spec.md
- **Source Linear Issue**: N/A
- **Type**: refactor ｜ **Size**: S ｜ **Complexity**: Small
- **Rigor**: balanced ｜ **Mode**: B ｜ **TDD**: on ｜ **Commit cadence**: per-task
- **Estimated Files**: ~4（3 modified + tests）

---

## Mandatory Reading
| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | docs/srs/recorder-automation-meeting-into-recorder-input.srs.md | all | 需求 + AC |
| P0 | VoiceInk/Services/AudioFileTranscriptionManager.swift | 298-307 | `.meetingCapture` 後處理呼叫（改 fixedCategory→nil） |
| P1 | VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift | 83-147 | process(fixedCategory:) 分支 |
| P1 | VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift | meetingFixedCategory 相關 | 設定調整 |
| P1 | VoiceInk/Views/Settings/RecorderModeSettingsView.swift | 會議錄製 Section | 固定分類 picker 調整 |

## Patterns to Mirror
### MEETING_POSTPROCESS（現況，改 fixedCategory）
```swift
// SOURCE: AudioFileTranscriptionManager.swift:300-306（現況）
if case .meetingCapture = item.origin, let enhancementService = engine.enhancementService,
   let aiService = enhancementService.getAIService() {
    await RecorderPostProcessor.shared.process(
        transcription: transcription, rawText: cleanedText, device: nil,
        fixedCategory: RecorderConfigStore.shared.meetingFixedCategory,   // ← 改 nil
        modelContext: modelContext, enhancementService: enhancementService, aiService: aiService)
}
```

## Files to Change
| File | Action | Justification |
|---|---|---|
| VoiceInk/Services/AudioFileTranscriptionManager.swift | UPDATE | meeting 後處理 fixedCategory → nil |
| VoiceInk/Views/Settings/RecorderModeSettingsView.swift | UPDATE | 「固定分類」picker → 移除或改「預設建議分類」 |
| VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift | UPDATE | 若移除固定分類語意，清理相關 setter（保留 meetingMicEnabled） |
| VoiceInkTests/MeetingIntoRecorderTests.swift | CREATE | 驗證不固定分類 |

## NOT Building
- 會議擷取音訊管線（不動）;錄音管理頁（SRS-B）。

## Step-by-Step Tasks

### Task 1: 會議後處理走一般路徑
- **ACTION**: `.meetingCapture` 傳 `fixedCategory: nil`。
- **TEST FIRST**（`MeetingIntoRecorderTests`，鏡射現有 recorder pipeline 測試的 in-memory container）:
  ```swift
  @MainActor func testMeetingUsesGeneralPathNotFixedCategory() async {
      // 構造一個 .meetingCapture 的 transcription 走 process(fixedCategory: nil)：
      // 斷言 recorderCategoryName 由 classify 決定（或自動匯出關時停留待手動），而非強制 == "會議"
      // 至少驗證 process 的 fixedCategory 分支未被觸發（用一個可注入的 spy 或檢查 classificationConfidence 非 nil）
  }
  ```
  （若難以直接測 ATM 私有流程，改測 `RecorderPostProcessor.process(fixedCategory: nil)` 會呼叫 suggestCategory 而非 assignCategory——已有 `RecorderPostProcessorTests` 樣式可鏡射。）
  Run — FAIL
- **IMPLEMENT**: `AudioFileTranscriptionManager.swift:305` 的 `fixedCategory:` 改 `nil`。
- **GOTCHA**: `process` 的 device 仍 nil（會議非 RecorderDevice）→ finalizeImport 天然跳過，正確。
- **VALIDATE**: 測試 PASS + 既有 pipeline 測試綠。
- **COMMIT**: `refactor(meeting): fold into recorder-input pipeline (no fixed category)`

### Task 2: 設定 UI 調整
- **ACTION**: 「會議錄製」Section 的「固定分類」picker 移除（或改標為「預設建議分類（可留自動）」，語意變非強制）。保留「同時收錄麥克風」。
- **TEST FIRST**: N/A（UI）。
- **IMPLEMENT**: 移除固定分類 picker 與說明;若保留為建議分類則改文案。相應清理/保留 `RecorderConfigStore.meetingFixedCategory*`（若整個移除，刪 setter/欄位並確保無殘留呼叫——grep）。
- **VALIDATE**: build 綠;設定頁不再顯示固定分類（或顯示為建議）。
- **COMMIT**: `refactor(meeting): settings — drop fixed-category picker`

### Task 3: 收尾
- **ACTION**: build+test;spec Change History 加 implemented;bump build;`make deploy`;回報;plan/SRS 移 completed。
- **COMMIT**: `chore(meeting): bump build, docs, deploy`

## Validation Commands
```bash
make local
xcodebuild test … -only-testing:VoiceInkTests
make deploy
```
### Manual Validation
- [ ] AC-1：自動匯出關時錄會議 → 未固定標會議、停在錄音管理待手動;來源標籤仍「會議 · <app>」
- [ ] AC-2：自動匯出開 → 走一般分類

## Acceptance Criteria
- [ ] SRS AC-1、AC-2 通過;零回歸

## Risks
| Risk | L | I | Mitigation |
|---|---|---|---|
| 移除 meetingFixedCategory 欄位漏清呼叫點 | M | M | grep 全部引用;或保留欄位僅改 UI 語意 |

## Notes
- 依賴 SRS-A 的側欄「錄音輸入」群名，但功能上獨立;可在 A 之後任何時間做。
