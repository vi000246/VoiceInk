# Feature Implementation Report: Meeting Capture（免 bot 會議錄製 → Recorder 管線）

## Summary
一鍵（選單列/全域快捷鍵）錄下線上會議：系統音訊（CoreAudio process tap）＋麥克風混成單聲道 AAC m4a，經 `.meetingCapture` origin 走既有 Recorder 管線（scribe_v2 整檔轉錄＋diarization → 繁中 → 固定「會議」分類跳過分類器 → 模板 → Obsidian）。Build 227。

## Strategy Used
- Size: L ｜ Mode: B（任務先測） ｜ Rigor: balanced
- Subagents: 5（T1/T2+T4/T5/T8 各一＋T3 部分完成後由主 session 收尾）；T6/T7/T9 由主 session 直接實作
- 執行分兩階段：Fable 前段（waves 1-2，模型切換中斷點有交接註記）→ 同 session 續完 T3-T7＋驗證＋收尾
- Waves: 1（T1,T5,T9）→ 2（T2+T4, T8）→ 3（T3）→ 4（T6）→ 5（T7）

## Tasks Completed
| # | Task | Status | Notes |
|---|------|--------|-------|
| 1 | 會議設定欄位（三態固定分類＋mic 開關） | ✅ | 測試含「會議」分類非必然存在的處理 |
| 2+4 | `.meetingCapture` origin＋`process(fixedCategory:)`＋`recorderSourceLabel` 全鏈 | ✅ | agent 額外擴了兩個 gate：失敗通知 switch、ElevenLabs 單次 diarize 路徑（`runsRecorderPipeline`） |
| 3 | `stageMeetingFile`/`importMeetingFile` | ✅ | 實作在中斷前已落地；本階段補測試鎖契約 |
| 5 | `MeetingCaptureService`＋`MeetingAudioMixer` | ✅ | 照 AudioCap 驗證呼叫序列；兩處預告 API 於 build 修正 |
| 6 | Controller＋浮動指示器＋選單列 | ✅ | 指示器 never-key panel；willTerminate 盡力保檔（runloop spin ≤2s） |
| 7 | `.toggleMeetingRecording` 快捷鍵 | ✅ | 連帶修 `ShortcutMigration` exhaustive switch |
| 8 | 設定 Section「會議錄製」 | ✅ | 文案位置修正（自動匯出在下方「自動化」區） |
| 9 | `NSAudioCaptureUsageDescription` | ✅ | |
| 10 | 會議 app 偵測提醒（OPTIONAL/Should） | ⏭ deferred | 見 Follow-ups |
| 11 | 收尾（bump/docs/deploy/Linear） | ✅ | Linear 待授權，見 Follow-ups |

## Integration Checks
| Check | Status | Notes |
|---|---|---|
| Build | ✅ pass | 兩個預告過的 CoreAudio API 錯誤即時修正（`[AudioObjectID]` init、qualified `CATapMuteBehavior`）＋`ShortcutMigration` switch |
| Unit tests | ✅ pass | 12 個新 Meeting 測試（Config×2/Mixer×3/Origin×1/Export×2/Import×2/Shortcut×1＋既有全套零回歸） |
| 手動 smoke | ⏳ 待使用者 | TCC 授權流程、實錄會議、裝置切換——Linear 驗證清單 |

## Files Changed
新增：`Services/Meeting/{MeetingCaptureService,MeetingAudioMixer,MeetingCaptureController}.swift`、`Views/Meeting/MeetingIndicatorView.swift`、`VoiceInkTests/Meeting{CaptureConfig,AudioMixer,Origin,Export,Import,Shortcut}Tests.swift`
修改：`RecorderConfigStore`（會議欄位＋diarization 預設啟用）、`AudioFileQueueItem`（origin case）、`AudioFileTranscriptionManager`（meeting 分支×4 處）、`RecorderPostProcessor`（fixedCategory＋assignCategory＋sourceLabel 匯出）、`RecorderImportService`（stage/import）、`Transcription`（recorderSourceLabel）、`VaultExportService`（來源: frontmatter）、`RecorderHistoryView`（chip）、`RecorderModeSettingsView`（Section）、`MenuBarView`、`ShortcutAction`/`RecordingShortcutManager`/`ShortcutMigration`、`Info.plist`、`project.pbxproj`（build 227）

## Deviations from Plan
1. 測試按任務分檔（六個 `Meeting*Tests.swift`）而非單一檔——避免多 agent 同檔衝突。
2. `assignCategory` 增加零 provider 時跳過 AI 標題的 fallback（`makeRecorderTitle` 必打 AI，空 provider 會卡 30s）。
3. `來源:` frontmatter 不走 `esc()` 引號（測試契約要求裸值；「會議 · App」形值為合法 YAML plain scalar）。
4. ATM 的 ElevenLabs 單次 diarize gate 以 `runsRecorderPipeline` bool 同時涵蓋 recorder/meeting——plan 未列此點，agent 主動補（避免會議音檔被轉錄兩次）。
5. 指示器 panel `canBecomeKey=false`（比 plan 的 MiniRecorderPanel 鏡射更嚴——會議中不可搶鍵盤）。

## AC Verification Map
| AC | Description | Test / 驗證方式 | Status |
|----|-------------|------|--------|
| AC-1 | 一鍵錄會議出筆記＋零分類呼叫 | 手動（Linear）＋`RecorderPostProcessor` fixedCategory 路徑單元測 | ⏳ 手動待驗 |
| AC-2 | TCC 拒絕引導 | 手動（`tccutil reset SystemAudioCaptureRequests com.prakashjoshipax.VoiceInk`） | ⏳ |
| AC-3 | 裝置切換韌性 | 手動（AirPods 接上/拔除） | ⏳ |
| AC-4 | 停止即入管線 | `MeetingImportTests` ×2 | ✅ |
| AC-5 | 快捷鍵/選單列一致、聽寫中可用 | `MeetingShortcutTests`＋手動 | ✅/⏳ |
| AC-6 | 純系統音訊模式 | 手動（關 mic toggle） | ⏳ |

## Follow-ups
- [ ] **Linear 驗證 issue 未建**：Linear MCP 尚未授權（`/mcp` → claude.ai Linear）。授權後在 voiceink 專案開 issue：標題「會議模式 build 227 手動驗證」，內容＝上表 ⏳ 項展開為步驟清單（含 TCC 重置指令、耳機/喇叭迴音檢查、開錄時間戳核對、來源 chip/frontmatter 檢查）。
- [ ] T10 會議 app 偵測提醒（PRD M2 範疇）。
- [ ] 混音等權平均在人聲/系統音量差大時偏小聲——之後可加 per-source gain。
- [ ] T5 遺留：`kAudioSubDeviceDriftCompensationKey` 對 mic sub-device 的實效、AAC ASBD 若 runtime -50 補 `mFramesPerPacket=1024`（首次真錄時留意）。
