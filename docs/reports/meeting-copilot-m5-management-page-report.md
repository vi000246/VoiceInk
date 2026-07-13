# Implementation Report: Meeting Copilot M5 — 管理頁 + 設定 UI

- **Plan**: `docs/plans/meeting-copilot-m5-management-page.plan.md`
- **Branch**: `feat/meeting-copilot-m1` ｜ **Build**: 251 → **252** ｜ **Date**: 2026-07-13

## Summary

新側欄頁「會議錄音管理」（會議列表 + 詳情 modal）+ 完整設定 UI（雙 model picker、接地開關、overlay、三熱鍵、本機 ASR 無術語偏置明示）。

## Tasks

| # | Task | Status |
|---|---|---|
| 1 | 三熱鍵衝突偵測 | ✅ 已於 M4 Task 1 完成（冪等，本輪驗證） |
| 2 | SettingsView 熱鍵 row | ✅ 併入 MeetingCopilotSettingsView 的熱鍵區 |
| 3 | MeetingCopilotModels.resolve | ✅ 已於 M3 Task 4 完成（冪等） |
| 4 | MeetingRowDisplay 純 helper | ✅ `MeetingCopilotPageTests`（5 測試） |
| 5 | MeetingCopilotSettingsView | ✅ compile |
| 6 | MeetingCopilotPageView | ✅ compile |
| 7 | ViewType.meetingCopilot 五處接線 | ✅ compile + ViewType 鎖定測試 |
| 8 | build 252 + 全套迴歸 | ✅ 綠 |

## Validation

- 編譯零錯誤；`MeetingCopilotPageTests`（含 ViewType 鎖定）全綠；全套 `VoiceInkTests` 綠。
- ⚠️ 全套一次跑偶發 fail（某 async replay 測試固定 `Task.sleep(800ms)` 在整批高負載下 timing 沒趕上），**重跑即綠**，非真回歸。未來可調長 sleep 或改用 expectation。

## 手動驗證（`make deploy` 後）

- [ ] 側欄「錄音輸入」組末出現**繁中**「會議錄音管理」，無 DEBUG assert crash
- [ ] 點擊 → 頁面開啟；齒輪 → 設定 modal，各控制項可操作
- [ ] fast/deep model picker 列出已連線 provider 的模型

## 🔴 最後整合缺口（feature 尚未 live）

**所有 M1-M5 元件都已建置且測試通過,但尚未在 app 執行期接線成一條 live pipeline。** 目前 `make deploy`
後你會看到側欄新頁(空)與設定,但**不會**有即時 overlay/cue——因為沒有任何程式在會議開始時
實例化 controller/transcriber/coordinator。需要一個**整合 task**(建議獨立小 milestone,因為
需 `make deploy` + 真會議才能驗):

1. **在會議擷取啟動時建 live pipeline**:`MeetingCaptureController.start()`(或 copilotEnabled 分支)
   建立 `LiveMeetingAudioSource(ring: service.copilotRingBuffer, tapChannelCount: service.copilotTapChannelCount)`
   → `MeetingLiveTranscriber`(remote/local 各一個 `LiveMeetingTranscriptStream`,model 取自 `config.asrModelName`)。
2. **建 controller + coordinator**:`MeetingCopilotController(extractor: ResponseCueExtractor(chat: MeetingCopilotController.makeFastCompleter(...)), config:, modelContext: container.mainContext)`;
   `AnswerCoordinator(fast: LiveStreamingChatCompleter(...), deep:, grounding: MeetingGroundingProvider(...), config:)`;
   `controller.answerCoordinator = coordinator`;`controller.attach(to: transcriber, appName:)`。
3. **接 overlay**:`CopilotOverlayWindowManager.shared.configure(controller:, transcriber:, onCueTapped: { cue in Task { await coordinator.requestDeep(cue) } })`
   ——**務必在 `transcriber.start()` 之前**(onLocalLevel 於 pump 啟動時定格)。
4. **停會議時**:`controller.endSession()` + `transcriber.stop()`。

這一步 + M1 的 `tapFirst` 實機 probe + M4 的 AC-15 螢幕分享三情境,一起在 `make deploy` 後做人工驗證。

## Next Steps

- **整合 task**（上述 4 步）——把元件接成 live pipeline。
- 人工驗證：M1 tapFirst probe、真實模型的 cue/tier 品質、AC-15 螢幕分享排除三情境、overlay 行為。
