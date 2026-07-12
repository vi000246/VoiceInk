# Implementation Report: Meeting Copilot M2 — cue 偵測引擎

- **Plan**: `docs/plans/meeting-copilot-m2-cue-detection.plan.md`
- **Feature SRS**: `docs/srs/meeting-copilot-m2-cue-detection.srs.md`
- **Branch**: `feat/meeting-copilot-m1`（M1+M2 同分支）
- **Build**: 248 → **249**
- **Date**: 2026-07-13

## Summary

在 M1 的雙軌逐字稿之上建立 cue 偵測引擎：對方的 committed 逐字稿 → fast model 抽出「需要我回應的東西」
並四分類（directQuestion / impliedChallenge / assignedToMe / informational）→ 去重 → persist 到
新的 SwiftData `meeting.store` → `@Published cues`。**不含 LLM 串流回答（M3）、overlay（M4）、頁面（M5）。**

交付：**離線 replay（不開會議軟體、不碰 CoreAudio、不打真 LLM）跑出三種分類正確、去重、已持久化的 cue。**

## Tasks Completed

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | MeetingLiveModels（2 @Model） | ✅ | cascade 照 AskAIThread/Message；tier 陣列欄位 JSON-in-raw + @Transient |
| 2 | meeting.store 三處註冊 | ✅ | 第 5 個 store；master Schema + persistent + in-memory |
| 3 | ResponseCueExtractor | ✅ | 單次非串流 completeChat；四分類；prompt 純函式；JSON golden；容錯回 [] |
| 4 | MeetingCueDeduplicator | ✅ | 字元 bigram Jaccard 0.6 + 30s 窗 |
| 5 | ConfigStore 擴充 | ✅ | fastProvider/fastModel + showInformationalCues |
| 6 | MeetingCopilotController | ✅ | onRemoteCommitted → 抽取 → 去重 → persist → @Published；kill switch |
| 7 | E2E replay 驗收 | ✅ | **M2 acceptance**，不開會議軟體 |
| 8 | DEBUG replay 接真 fast model | ⏳ 延後 | 人工驗證輔助，不阻斷交付 |
| 9 | build 249 + 全套迴歸 | ✅ | VoiceInkTests 全綠，M1 零回歸 |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| 編譯 | ✅ Pass | 零錯誤 |
| 單元測試（新增） | ✅ Pass | 6 個新測試檔（models / extractor / dedup / config / controller / replay），~20 測試 |
| 全套 VoiceInkTests | ✅ Pass | M1（audio backbone）+ M2 全綠，零回歸 |
| 手動（真 fast model 品質） | ⏳ 待 Task 8 | cue 抽取的真實模型品質未驗（fake LLM 只驗接線） |

## AC Verification Map

| AC（M2 SRS） | Description | Test | Status |
|----|-------------|------|--------|
| AC-1（=umbrella AC-4） | 陳述句質疑（無問號）必須被偵測 | `ResponseCueExtractorTests::testDetectsStatementFormChallenge` + replay | ✅ |
| AC-2 | 抽取+分類 = 單次非串流呼叫 | `ResponseCueExtractorTests::testExtractionIsSingleNonStreamingCall` | ✅ |
| AC-3 | prompt 純函式 | `ResponseCueExtractorTests::testPromptIsPureAndDeterministic` | ✅ |
| AC-4 | 30s 窗內相似 cue 去重 | `MeetingCopilotControllerTests::testDedupesSimilarCuesWithinWindow` | ✅ |
| AC-5 | informational persist 但預設隱藏 | `MeetingCopilotControllerTests::testInformationalPersistedButHiddenByDefault` | ✅ |
| AC-6 | cascade 刪除無孤兒 | `MeetingLiveModelsTests::testDeletingSessionCascadesCues` | ✅ |
| AC-7 | 三處 schema 註冊（launch 不崩） | app 啟動 + in-memory container 測試 | ✅ |
| AC-8 | E2E replay | `MeetingCueDetectionReplayTests::testEndToEndFromWavPersistsClassifiedCues` | ✅ |
| AC-9 | kill switch | `MeetingCopilotControllerTests::testDisabledCopilotExtractsNothing` | ✅ |

## Deviations from Plan

- **Task 8 延後**：DEBUG 選單接真 fast model 屬人工驗證輔助，不阻斷 M2 交付，留待與 M3 一起做（M3 也需要真模型驗證）。
- 其餘一律照 plan（plan 的 task 程式碼即實作，逐字採用）。

## Outstanding

- [ ] Task 8：DEBUG 選單接真 fast model，人工驗證 cue 抽取品質（含真實 ASR 錯字容忍）。
- [ ] `meeting.store` 首次啟動的實機驗證（三處註冊已在測試 container 驗過，但 app 實際落檔未跑）——與 M1 的 tapFirst probe 一起在 `make deploy` 後驗。

## Next Steps

- M3 — 三層回應 + SSE + 接地（消費 M2 的 `MeetingLiveCue` + `MeetingCopilotController.cues`）。
- M3 plan：`docs/plans/meeting-copilot-m3-tiered-response.plan.md`（Task 1–7 不依賴 M2 可先行，Task 8–10 需 M2）。
