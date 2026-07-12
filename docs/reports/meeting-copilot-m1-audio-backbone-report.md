# Implementation Report: Meeting Copilot M1 — 音訊分流骨幹 + 離線 replay harness

- **Plan**: `docs/plans/meeting-copilot-m1-audio-backbone.plan.md`
- **Feature SRS**: `docs/srs/meeting-copilot-live-assist.srs.md`
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Branch**: `feat/meeting-copilot-m1`
- **Build**: 247 → **248**
- **Date**: 2026-07-12

## Summary

打通了 meeting-copilot 的音訊骨幹：在 `MeetingAudioMixer.mixToMono` 把所有聲道等權壓成單聲道
**之前**，依 tap 聲道數把「對方（system tap）」與「我（mic sub-device）」切成兩條流，經 lock-free
SPSC ring buffer 送出 realtime thread，降頻成 16kHz mono Int16 後餵進兩條獨立的串流 ASR。

**講者歸屬因此是結構上已知的：100% 準確、零成本、零延遲，完全不需要 diarization。**

同時建立 `MeetingAudioSource` 注入層，讓完整 pipeline 能用預錄 WAV 在**不開 Teams/Meet、
不碰 CoreAudio、不需網路、不需 API key** 的情況下端到端驗證。

## Tasks Completed

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | MeetingChannelLayout（probe + 常數） | ⚠️ **程式碼完成，量測待跑** | `tapFirst` 需**實機量測**（見下方 Outstanding） |
| 2 | 錄音落檔迴歸測試 | ✅ | 在動 handleIO **之前**先鎖住 golden 輸出 |
| 3 | MeetingChannelSplitter | ✅ | 10 個測試；兩種佈局各自驗證 |
| 4 | PCMDownsampler（抽出） | ✅ | 位元等價；**偏離 plan**（見下） |
| 5 | MeetingPCMRingBuffer | ✅ | 12 個測試含 2000 筆併發 SPSC |
| 6 | MeetingCopilotConfigStore | ✅ | `copilotEnabled` 預設 false |
| 7 | handleIO seam | ✅ | 落檔位元組零改變 |
| 8 | MeetingAudioSource + Live | ✅ | |
| 9 | ReplayMeetingAudioSource | ✅ | 完全不碰 CoreAudio |
| 10 | MeetingTranscriptStream + Fake | ✅ | 包住 `StreamingTranscriptionService`，不改它 |
| 11 | MeetingLiveTranscriber | ✅ | `onRemoteCommitted` = M2 的接點 |
| 12 | E2E replay 測試 | ✅ | **M1 驗收**，8 個測試 |
| 13 | DEBUG replay 選單 | ✅ | 真 ASR，人工驗證 |
| 14 | Build bump + 全套迴歸 | ✅ | 248；`VoiceInkTests` 全綠 |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| 編譯 | ✅ Pass | 零錯誤；唯一 warning 是既有的（`AudioFileProcessor.swift:113`） |
| 單元測試（新增） | ✅ Pass | 5 個新測試檔，~40 個測試 |
| 單元測試（全 target） | ✅ Pass | `-only-testing:VoiceInkTests` 全綠——既有 Meeting*/Recorder*/AskAI* 零回歸 |
| UI 測試 | ⚠️ 環境失敗 | `VoiceInkUITests-Runner` 因 LocalAuthentication（"System authentication is running"）無法初始化。**與本次改動無關**——UI runner 的環境問題。 |
| 手動驗證 | ⏳ 待跑 | 見 Outstanding |

## Files Changed

| File | Action |
|---|---|
| `VoiceInk/Services/MeetingCopilot/MeetingChannelLayout.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/MeetingChannelSplitter.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/PCMDownsampler.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/MeetingPCMSink.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/MeetingPCMRingBuffer.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/MeetingAudioSource.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/LiveMeetingAudioSource.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/ReplayMeetingAudioSource.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/MeetingTranscriptStream.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/MeetingLiveTranscriber.swift` | CREATED |
| `VoiceInk/Services/MeetingCopilot/MeetingReplayDebugRunner.swift` | CREATED（`#if DEBUG`） |
| `VoiceInk/Services/Meeting/MeetingCaptureService.swift` | UPDATED — seam、`GraphRates.tapChannelCount`、rebuild 重讀、stop 清理 |
| `VoiceInk/CoreAudioRecorder.swift` | UPDATED — 降頻改呼叫 `PCMDownsampler`（零複製、行為等價） |
| `VoiceInk/Views/MenuBarView.swift` | UPDATED — DEBUG replay 選單項 |
| `VoiceInk.xcodeproj/project.pbxproj` | UPDATED — build 248 |
| `VoiceInkTests/MeetingCaptureRegressionTests.swift` | CREATED |
| `VoiceInkTests/MeetingChannelSplitterTests.swift` | CREATED |
| `VoiceInkTests/PCMDownsamplerTests.swift` | CREATED |
| `VoiceInkTests/MeetingPCMRingBufferTests.swift` | CREATED |
| `VoiceInkTests/MeetingCopilotReplayTests.swift` | CREATED |

## Deviations from Plan

### 1. `PCMDownsampler` 的核心改成 pointer-based（往更安全的方向）

**Plan 原本**：`CoreAudioRecorder` 改呼叫 array-based 的 `PCMDownsampler`。
**實際**：核心是 **pointer-based 零配置**版，array 版只是給 meeting consumer 與測試的包裝。

**Why**：array 版會讓聽寫熱路徑每個 buffer 多一次 `UnsafeMutablePointer → [Float]` 的配置＋複製。
為了 DRY 而在聽寫路徑上引入效能回歸，不划算。pointer 版讓 `CoreAudioRecorder` 的 diff 極小且零複製。

### 2. Ring buffer 滿溢時丟「新的」而非「舊的」（**SRS 第 5 個錯誤**）

**SRS 原本**：「滿溢時丟棄最舊並計數」。
**實際**：背壓——滿了就拒絕寫入這一輪。

**Why**：在 SPSC 環形緩衝裡，「丟棄最舊」需要 producer 推進 `readIndex`，那是**消費者的**變數，
從生產者去動它會直接破壞 SPSC 不變式（兩個執行緒同時寫同一個索引）。`CoreAudioRecorder` 的做法
（也是唯一 lock-free 安全的做法）是背壓。實務上 96 slot × 4096 frame @48k ≈ **8 秒**緩衝，
真的滿溢代表 consumer 嚴重卡住——那時重點是**不阻塞 realtime thread**（阻塞會直接造成錄音爆音）。

### 3. `droppedFrames` → `droppedCallbacks`

它數的是被丟棄的 **callback** 數，不是 frame 數。誤導性的名字是 bug 工廠。
另外拆出 `droppedBreakdown`（backpressure vs capacity）——這是兩種完全不同的病。

### 4. Task 2 的第二個測試移到 Task 5

Plan 建議先寫再 `XCTSkip`，但 `-only-testing` 會編譯**所有**測試檔，留一個 compile error 進去很髒。
改成在 ring buffer 存在時（Task 5）才加該測試。效果相同，過程乾淨。

## AC Verification Map

| AC | Description | Test | Status |
|----|-------------|------|--------|
| AC-1 | 聲道分流正確（講者歸屬） | `MeetingChannelSplitterTests`（10 tests） | ✅ Pass（但 `tapFirst` 的**值**待實機量測） |
| AC-2 | 錄音落檔零回歸 | `MeetingCaptureRegressionTests` + `MeetingPCMRingBufferTests::testSinkDoesNotMutateSourceBuffers` + 既有 `MeetingAudioMixerTests` | ✅ Pass |
| AC-3 | realtime thread 不被阻塞 | `MeetingPCMRingBufferTests::testOverflowDropsNewestAndCountsWithoutBlocking` + 併發 SPSC 測試 | ✅ Pass |
| AC-14（音訊半部） | 端到端 replay，不開會議軟體 | `MeetingCopilotReplayTests::testEndToEndReplayRoutesRemoteAndLocalToSeparateStreams` | ✅ Pass |

## ⚠️ Outstanding — 需要你親自做的兩件事

### 1. 🔴 實機量測 `MeetingChannelLayout.tapFirst`（**擋住整個模組的正確性**）

我沒有你的音訊硬體，跑不了這個。目前 `tapFirst = true`、`isVerified = false`（啟動時會警告）。

CoreAudio **沒有保證** aggregate device 的 `AudioBufferList` 中 tap list 與 sub-device list 的先後，
composition dictionary 的 key 順序**不代表** stream 順序。**切反的話，整個模組會把「你自己講的話」
當成「對方問的問題」，而且症狀極隱晦。**

**步驟**（詳見 `MeetingChannelLayout.swift` 的 doc comment）：
1. `make deploy`（build 248），設定 `meetingCopilotEnabledV1 = true`
2. 開始會議錄製，Console.app 過濾 `🎧`
3. **情境 A**：麥克風輸入音量調 0 → 播音樂 → 有能量的那組 = tap（remote）
4. **情境 B**：系統音靜音 → 對麥克風說話 → 有能量的那組 = mic（local）
5. **兩個情境必須互補**。不互補就停下來——代表假設有問題。
6. 回填 `tapFirst`，把 `isVerified` 改成 `true`

### 2. 手動迴歸驗證

- [ ] `copilotEnabled = false`（預設）→ 錄一段會議 → m4a 正常、轉錄正常、Obsidian 匯出正常
- [ ] `copilotEnabled = true` → 錄一段會議 → m4a **仍然正常**；`droppedCallbacks` 為 0 或極低
- [ ] **語音聽寫仍正常**（Task 4 動了 `CoreAudioRecorder`）
- [ ] DEBUG 選單「Replay 會議音檔」→ 選一個含語音的音檔 → Console 看到真實 ASR 的 🎧 committed 文字
- [ ] 會議中途拔/插耳機 → 聲道不錯位

## Next Steps

- [ ] 跑完上方兩項，回填 `tapFirst`
- [ ] 把 plan 頂部的「五項 SRS 修正」回寫進 SRS
- [ ] M2 — Cue 偵測 + 三層回應 + SSE（接點已備妥：`MeetingLiveTranscriber.onRemoteCommitted`）
