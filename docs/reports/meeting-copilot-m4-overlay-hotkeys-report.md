# Implementation Report: Meeting Copilot M4 — 隱蔽 overlay + 熱鍵

- **Plan**: `docs/plans/meeting-copilot-m4-overlay-hotkeys.plan.md`
- **Feature SRS**: `docs/srs/meeting-copilot-m4-overlay-hotkeys.srs.md`
- **Branch**: `feat/meeting-copilot-m1` ｜ **Build**: 250 → **251** ｜ **Date**: 2026-07-13

## Summary

把 M2/M3 的狀態顯示在一個浮動 overlay：opener 最大字級、三層漸進渲染、我說話時淡出；toggle + peek 雙熱鍵召喚；並修復既有 `.toggleMeetingRecording` 的衝突偵測缺陷。

## Tasks Completed（9/9）

| # | Task | Test | Status |
|---|---|---|---|
| 1 | 熱鍵資料層 + FR-32 修復 | `MeetingShortcutTests` | ✅ |
| 2 | overlay config（clickThrough/opacity/maxCues）| `CopilotOverlayConfigTests` | ✅ |
| 3 | OverlayDimmingModel（說話淡出狀態機）| `OverlayDimmingTests`（AC-17）| ✅ |
| 4 | onLocalLevel RMS 接點 | `MeetingLocalLevelTests` | ✅ |
| 5 | CopilotOverlayPanel（sharingType/穿透/level）| compile | ✅ |
| 6 | Arranger + View | `CopilotOverlayArrangerTests`（FR-26）| ✅ |
| 7 | WindowManager（近鏡頭 + peek 守衛）| `CopilotOverlayWindowManagerTests` | ✅ |
| 8 | 熱鍵 dispatch 接線 | compile + 迴歸 | ✅ |
| 9 | build 251 + 全套迴歸 | 全綠 | ✅ |

## Validation

- 編譯零錯誤；6 個新測試檔全綠；全套 `VoiceInkTests`（M1-M4）零回歸。
- 純邏輯（淡出狀態機、cue 排列、peek 守衛、近鏡頭錨定幾何、熱鍵衝突偵測）已測死。

## 🔴 必須人工驗證（AC-15，UI 行為只能實機測）

- [ ] **AC-15 螢幕分享排除，三情境**（`make deploy` 後）：
  1. Teams 原生 app 分享整個螢幕 → overlay **會被錄到**（macOS 15.4+ SCK 忽略 sharingType）；
  2. Chrome/Meet `getDisplayMedia` 分享整螢幕 → 同上會被錄到；
  3. 分享**單一視窗/分頁** → overlay **不被錄到**（安全）。
  → 這正是為何 UI 有常駐警告條、docs 不宣稱無條件隱形（見 memory `voiceink-sharingtype-sck-limitation`）。
- [ ] overlay 不搶焦點（會議 app 保持前景、鍵盤焦點不轉移）
- [ ] toggle 熱鍵：按一下出現、再按消失；peek 熱鍵：按住顯示、放開隱藏
- [ ] 我說話時 overlay 淡出、停止 1.5s 後恢復
- [ ] **熱鍵目前需 M5 的設定 UI 才能指派**（或手動 `defaults` 寫入）——M4 只做資料層 + dispatch。

## Deviations

- overlay 的 `configure()` 接線點（把 `onLocalLevel` 接上 + `onCueTapped` 接 M3 的 `AnswerCoordinator.requestDeep`）留待整體 app 組裝時補一行——與 M2/M3 的 controller/coordinator 建構點一起接（目前 controller 尚未在 app 啟動流程建立，屬 M5/整合）。

## Next Steps

- M5 — 管理頁 + 設定 UI（含三個熱鍵的 ShortcutRecorder row、雙 model picker、brief、術語取捨明示）。
- 整體接線：在 app 啟動流程建立 `MeetingCopilotController` + `AnswerCoordinator`，呼叫 `CopilotOverlayWindowManager.shared.configure(...)`。
