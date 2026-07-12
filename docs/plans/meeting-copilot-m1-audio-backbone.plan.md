---
linear_issue: null
---
# Plan: Meeting Copilot M1 — 音訊分流骨幹 + 離線 replay harness

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type`。**Mode B（任務先測）**：每個 task 先寫一個鎖行為的測試 → 實作 → 通過 → commit。**Rigor: strict** — 測試 gate 全強制（有 realtime 音訊 + 錄音資料完整性風險）。
>
> **⚠️ Task 1 擋在一切之前。** 它是一次性實機量測，決定 `MeetingChannelLayout.tapFirst` 的值。這個值若錯，整個模組會把「你自己講的話」當成「對方問的問題」，而且症狀隱晦到極難察覺。**沒跑完 Task 1 不要開始 Task 3。**
>
> **Checkbox states:** `- [ ]` todo · `- [~]` in-progress · `- [x]` done。`[~]` 不是完成。

## Summary

打通 meeting-copilot 的音訊骨幹：在 `MeetingAudioMixer.mixToMono` 把所有聲道壓成單聲道**之前**，依 tap 聲道數把「對方（system tap）」與「我（mic sub-device）」切成兩條流，經 lock-free ring buffer 送出 realtime thread，降頻成 16kHz mono Int16 後餵進兩個獨立的串流 ASR。同時建立 `MeetingAudioSource` 注入層，讓完整 pipeline 能用預錄 WAV 在**不開 Teams/Meet、不碰 CoreAudio** 的情況下端到端驗證。

M1 不含 cue 偵測、LLM、overlay、頁面——那是 M2–M4。M1 的交付是：**從 WAV 跑出「對方 / 我」兩條逐字稿，且會議錄音落檔位元組零改變。**

## User Story

As a 開會時需要即時輔助的使用者, I want 系統能可靠地分辨「對方在說話」與「我在說話」並即時轉錄兩者, so that 後續的問題偵測與回答建議有 100% 正確的講者歸屬可依賴。

## Problem → Solution

會議擷取（build 227）把 tap 聲道與 mic 聲道**等權平均**壓成單聲道寫進 AAC，講者資訊在 `mixToMono` 當下不可逆地消失；而串流轉錄路徑完全沒有 speaker 欄位，diarization 只存在於批次路徑且與串流互斥。
→ 在 `mixToMono` **之前**按聲道區間切開（切點 = tap 聲道數，`kAudioTapPropertyFormat` 已讀到），講者歸屬變成**結構上已知、零成本、100% 準確**，完全不需要 diarization。

## Metadata
- **Module**: meeting-copilot
- **Parent Plan**: N/A
- **Source PRD**: N/A（承接 `docs/prd/meeting-capture-to-obsidian.prd.md` 中列為 NOT Building 的「串流即時化另案」）
- **Source Feature SRS**: `docs/srs/meeting-copilot-live-assist.srs.md`
- **Source Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source Linear Issue**: N/A（`docs/prp.config.yml` → `skip: true`）
- **Type**: feature ｜ **Size**: L ｜ **Complexity**: Large
- **Rigor**: strict ｜ **Mode**: B — 任務先測 ｜ **TDD**: on（task-level）｜ **Commit cadence**: per-task
- **Estimated Files**: ~19（11 created + 4 modified + 4 test files）
- **Build**: 247 → **248**
- **FR 覆蓋**: FR-1 ~ FR-7、FR-33、FR-34
- **AC 覆蓋**: AC-1、AC-2、AC-3（AC-14 的音訊半部；cue/LLM 半部屬 M2）

---

## ⚠️ 規劃期發現：對 SRS 的四項修正

實作前必讀。以下是寫 plan 時交叉驗證 codebase 才發現的，SRS 當時的假設有誤：

### 修正 1 — E2E 測試**不能**用真實 FluidAudio ASR（SRS 說「CI 可跑」是錯的）

SRS 寫「ASR：本機 FluidAudio Parakeet（真實 ASR、免 API key → CI 可跑）」。**站不住**，三個理由：

1. `VoiceInkTests` 是 **host-app 測試 bundle**——runner 會啟動 `VoiceInk.app` 來 host 測試。專案記憶 `voiceink-running-unit-tests` 明載：普通 `xcodebuild test` 會讓 host **開機即 crash**，且同一則記憶直接寫著 **「CoreAudio `AudioDeviceManager` init 在 headless 下也很脆弱」**。
2. FluidAudio 需要先下載 CoreML 模型到磁碟，不是純程式碼依賴。
3. 全 repo **沒有任何測試使用 Bundle fixture**（`grep -rln "Bundle(for:\|url(forResource" VoiceInkTests/` → 零命中），所以「把 WAV 放進測試 bundle」這條路沒有先例，且 `PBXFileSystemSynchronizedRootGroup` 對非 `.swift` 檔的分類行為未驗證。

**改為**：
- **XCTest E2E（Task 12）用 `FakeMeetingTranscriptStream`**（腳本化 `.committed` 事件）→ hermetic、快、可進 CI。它驗證的是**接線正確性**（分流 → 降頻 → 雙路 → 講者歸屬），這正是 M1 的風險所在。
- **真實 ASR 的 replay 放進 `#if DEBUG` 選單（Task 13）**，由人工跑、肉眼驗證。WAV 從磁碟路徑讀，不進 test bundle。

### 修正 2 — Ring buffer 不要自己發明，codebase 裡已經有一個

SRS 說「預配置 SPSC ring buffer」，但沒說**已經有現成的**。
`CoreAudioRecorder.swift:68-77, 815-888` 是一個完整的 production-grade SPSC slot ring：預配置 slot、`ManagedAtomic<UInt64>` 讀寫索引、`.relaxed`/`.acquiring`/`.releasing` 記憶體序、backpressure 丟棄 + 兩個丟棄計數器、consumer 用 `DispatchQueue` + `audioProcessingScheduled` latch。
**`swift-atomics` 已經是專案依賴**（`import Atomics`，`CoreAudioRecorder.swift:5`）。

→ Task 5 **照抄這個形狀**（同樣的記憶體序、同樣的 drop-counter 結構），不要引入新依賴、不要自創記憶體序。**也不要重構 `CoreAudioRecorder` 去共用**——那條路徑服務聽寫，動它風險不成比例。

### 修正 3 — `handleIO` **已經**在 realtime thread 上配置記憶體

SRS 的 NFR 寫「realtime thread 零配置」。**這條線在既有程式碼裡本來就已經破了**：
`MeetingAudioMixer.mixToMono`（`MeetingAudioMixer.swift:17, 29`）每次 callback 都做 `var acc = [Float](repeating: 0, count: frameCount)` 和 `var out = [Float](...)`——**每個 IOProc callback 配置兩個陣列**。

→ 誠實的標準改成：**我們的 seam 必須嚴格比現有的 mixToMono 做得更少**。實作上就是：只把 `channelScratch` memcpy 進**預配置**的 slot（一次 ARC retain + memcpy），不做切分、不做降頻、不做混音。**切分與降頻全部移到 consumer 側**（Task 7 GOTCHA）。這比 mixToMono 現在做的少，所以不會讓既有情況變糟。

### 修正 4 — `GraphRates` 把 tap 聲道數丟掉了

`MeetingCaptureService.swift:392-393` 已經讀到 `tapFormat.mChannelsPerFrame` 並 log 出來，但 `GraphRates`（:432）**只帶 sample rate**，聲道數在函式返回時就沒了。
→ Task 7 必須把 `tapChannelCount` 加進 `GraphRates` 並一路傳到 `MeetingCaptureContext`。裝置切換（`rebuildGraphKeepingFile`）時**必須重讀**，否則切換耳機後聲道會錯位。

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/meeting-copilot-live-assist.srs.md` | all | 需求＋AC。⚠️ 連同上方「四項修正」一起讀 |
| P0 | `docs/spec/meeting-copilot.spec.md` | Ubiquitous Language、Decisions Log | 命名與已鎖定的決策 |
| P0 | `VoiceInk/Services/Meeting/MeetingCaptureService.swift` | 39-164（`MeetingCaptureContext` + `handleIO`）、225-275（`start`）、361-453（tap/aggregate/IOProc）、594+（`rebuildGraphKeepingFile`） | **唯一的擷取端侵入點**。seam 插在 :140 `mixToMono` 之前 |
| P0 | `VoiceInk/CoreAudioRecorder.swift` | **68-77（ring 欄位）、815-888（SPSC 讀寫）** | **Task 5 照抄的對象**。記憶體序一字不改 |
| P0 | `VoiceInk/CoreAudioRecorder.swift` | 930-1000 | **Task 4 抽出的對象**（Float32 多聲道 → mono 16k Int16，含線性插值 resample） |
| P0 | 專案記憶 `voiceink-running-unit-tests` | all | **測試指令必須照它寫**，否則 host crash（CloudKit `_os_crash`） |
| P1 | `VoiceInk/Services/Meeting/MeetingAudioMixer.swift` | all（39 行） | 純函式 + 測試的房子風格；也是「已在 realtime thread 配置」的證據 |
| P1 | `VoiceInk/Transcription/Streaming/StreamingTranscriptionProvider.swift` | 4-9（`StreamingTranscriptionEvent`）、38-54（協定） | 事件型別；Task 10 的 `MeetingTranscriptStream` 直接複用 `StreamingTranscriptionEvent` |
| P1 | `VoiceInk/Transcription/Streaming/StreamingTranscriptionService.swift` | 106-128（init）、142-173（`startStreaming`）、176-181（**`nonisolated sendAudioChunk`**）、184-193（`stopAndGetFinalText`）、252-272（`createProvider` — **private 且對非串流 provider `fatalError`**） | Task 10 要包住它。**不要改它**——它服務聽寫路徑 |
| P1 | `VoiceInk/Transcription/Engine/TranscriptionService.swift` | 3-15（`TranscriptionRequestContext`） | `startStreaming(model:context:)` 的第二參數 |
| P1 | `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` | 20-100（`@Published private(set)` + `…V1` key + `set…()`） | Task 6 的 config store 樣式 |
| P2 | `VoiceInkTests/MeetingAudioMixerTests.swift` | all（16 行） | 純 seam 測試的房子風格 |
| P2 | `VoiceInk/Models/TranscriptionModelRegistry.swift` | 21-75 | 串流模型清單（`supportsStreaming: true`）：`parakeet-tdt-0.6b-v2/v3`、`parakeet-unified-0.6b`、`nemotron-*` |
| P2 | 專案記憶 `voiceink-report-build-number`、`voiceink-build-no-ghost-apps` | all | bump build 並回報；**不要 build 進 /tmp**；**不要自動 deploy** |

## External Documentation

無需外部研究——全部使用既有內部 pattern（CoreAudio process tap、swift-atomics、既有串流轉錄協定）。

---

## Patterns to Mirror

### RING_BUFFER — SPSC lock-free（Task 5 照抄）
```swift
// SOURCE: VoiceInk/CoreAudioRecorder.swift:5, 68-77
import Atomics

private let inputRingSlotCount = 96
private var inputBufferSlots: [InputBufferSlot] = []
private let inputWriteIndex = ManagedAtomic<UInt64>(0)
private let inputReadIndex = ManagedAtomic<UInt64>(0)
private let droppedInputBuffersBackpressure = ManagedAtomic<UInt64>(0)
private let droppedInputBuffersCapacity = ManagedAtomic<UInt64>(0)

// SOURCE: VoiceInk/CoreAudioRecorder.swift:822-843 — producer（realtime thread）
guard sampleCount <= inputBufferCapacitySamples else {
    droppedInputBuffersCapacity.wrappingIncrement(ordering: .relaxed)
    return
}
let writeIndex = inputWriteIndex.load(ordering: .relaxed)
let readIndex = inputReadIndex.load(ordering: .acquiring)
guard writeIndex - readIndex < UInt64(inputBufferSlots.count) else {
    droppedInputBuffersBackpressure.wrappingIncrement(ordering: .relaxed)
    return
}
let slot = inputBufferSlots[Int(writeIndex % UInt64(inputBufferSlots.count))]
slot.frameCount = frameCount
slot.samples.update(from: inputSamples, count: Int(sampleCount))   // memcpy，無配置
inputWriteIndex.store(writeIndex + 1, ordering: .releasing)
scheduleAudioProcessing()

// SOURCE: VoiceInk/CoreAudioRecorder.swift:846-888 — consumer（DispatchQueue + latch）
private func scheduleAudioProcessing() {
    let wasScheduled = audioProcessingScheduled.exchange(true, ordering: .acquiringAndReleasing)
    guard !wasScheduled else { return }
    audioProcessingQueue.async { [weak self] in self?.processQueuedInputBuffers() }
}
```

### PURE_FUNCTION_NAMESPACE（Task 3/4 照抄）
```swift
// SOURCE: VoiceInk/Services/Meeting/MeetingAudioMixer.swift:9-15
/// 等權平均把多聲道 Float32 樣本混成 mono。純函式,供 IOProc 與單元測試共用。
enum MeetingAudioMixer {
    static func mixToMono(channelBuffers: [[Float]], frameCount: Int) -> [Float] {
        guard frameCount > 0, !channelBuffers.isEmpty else { return [] }
        guard channelBuffers.allSatisfy({ $0.count >= frameCount }) else { return [] }
        ...
    }
}
```

### DOWNSAMPLE — Float32 多聲道 → mono 16k Int16（Task 4 抽出的對象）
```swift
// SOURCE: VoiceInk/CoreAudioRecorder.swift:955-977（需要 resample 的分支）
let ratio = outputSampleRate / inputSampleRate
let outputFrameCount = UInt32(Double(frameCount) * ratio)
for i in 0..<Int(outputFrameCount) {
    let inputIndex = Double(i) / ratio
    let inputIndexInt = Int(inputIndex)
    let frac = Float32(inputIndex - Double(inputIndexInt))
    var sample: Float32 = 0
    let idx1 = min(inputIndexInt, Int(frameCount) - 1)
    let idx2 = min(inputIndexInt + 1, Int(frameCount) - 1)
    for ch in 0..<Int(inputChannels) {
        let s1 = inputSamples[idx1 * Int(inputChannels) + ch]
        let s2 = inputSamples[idx2 * Int(inputChannels) + ch]
        sample += s1 + frac * (s2 - s1)
    }
    sample /= Float32(inputChannels)
    let scaled = sample * 32767.0
    let clipped = max(-32768.0, min(32767.0, scaled))
    outputBuffer[i] = Int16(clipped)
}
```
> ⚠️ 注意上面這段的**已知怪異**：插值分支寫的是 `sample += s1 + frac * (s2 - s1)`，**沒有除以聲道數之前先累加 s1**——它其實是對的（後面 `sample /= inputChannels`），但 `s1 + frac*(s2-s1)` 每聲道各自線性插值後累加。抽出時**逐字保留這個行為**，不要「順手修正」——Task 4 的測試就是要鎖住**位元等價**。

### CONFIG_STORE（Task 6 照抄）
```swift
// SOURCE: VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift:20+
@MainActor
final class RecorderConfigStore: ObservableObject {
    static let shared = RecorderConfigStore()
    @Published private(set) var meetingMicEnabled: Bool = true
    private let meetingMicEnabledKey = "recorderMeetingMicEnabledV1"
    func setMeetingMicEnabled(_ v: Bool) {
        meetingMicEnabled = v
        UserDefaults.standard.set(v, forKey: meetingMicEnabledKey)
    }
}
```

### STREAMING_EVENT（Task 10 直接複用，不重新定義）
```swift
// SOURCE: VoiceInk/Transcription/Streaming/StreamingTranscriptionProvider.swift:4-9
enum StreamingTranscriptionEvent {
    case sessionStarted
    case partial(text: String)
    case committed(text: String)
    case error(Error)
}
```

### TEST_STRUCTURE（全部測試照抄）
```swift
// SOURCE: VoiceInkTests/MeetingAudioMixerTests.swift:1-16
import XCTest
@testable import VoiceInk

final class MeetingAudioMixerTests: XCTestCase {
    func testMixAveragesAllChannelsToMono() {
        let tap: [[Float]] = [[1, 1], [0, 0]]
        let mic: [[Float]] = [[0.5, 0.5]]
        XCTAssertEqual(MeetingAudioMixer.mixToMono(channelBuffers: tap + mic, frameCount: 2), [0.5, 0.5])
    }
}
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/MeetingCopilot/MeetingChannelLayout.swift` | CREATE | probe + 量測結果常數 `tapFirst` |
| `VoiceInk/Services/MeetingCopilot/MeetingChannelSplitter.swift` | CREATE | 純函式：依 tap 聲道數切 remote/local |
| `VoiceInk/Services/MeetingCopilot/PCMDownsampler.swift` | CREATE | 從 `CoreAudioRecorder` 抽出的共用純函式 |
| `VoiceInk/Services/MeetingCopilot/MeetingPCMRingBuffer.swift` | CREATE | SPSC slot ring（照抄 `CoreAudioRecorder`） |
| `VoiceInk/Services/MeetingCopilot/MeetingPCMSink.swift` | CREATE | realtime-safe sink 協定（`MeetingCaptureContext` 持有） |
| `VoiceInk/Services/MeetingCopilot/MeetingAudioSource.swift` | CREATE | 注入層協定 + `MeetingAudioFrame` |
| `VoiceInk/Services/MeetingCopilot/LiveMeetingAudioSource.swift` | CREATE | 正式音源（包 ring buffer） |
| `VoiceInk/Services/MeetingCopilot/ReplayMeetingAudioSource.swift` | CREATE | 測試音源（讀 WAV，可加速） |
| `VoiceInk/Services/MeetingCopilot/MeetingTranscriptStream.swift` | CREATE | 轉錄串流協定 + Live（包 `StreamingTranscriptionService`）+ Fake |
| `VoiceInk/Services/MeetingCopilot/MeetingLiveTranscriber.swift` | CREATE | 雙路接線：source → split → downsample → 兩條 ASR |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | CREATE | 最小設定（`copilotEnabled` / `asrModelName` / `transcribeLocalMic`） |
| `VoiceInk/Services/Meeting/MeetingCaptureService.swift` | UPDATE | `GraphRates.tapChannelCount`；`MeetingCaptureContext` 加 sink；`handleIO` seam；rebuild 重讀聲道數 |
| `VoiceInk/CoreAudioRecorder.swift` | UPDATE | 降頻邏輯改呼叫 `PCMDownsampler`（行為等價） |
| `VoiceInk/Views/MenuBarView.swift` | UPDATE | `#if DEBUG` 選單項「Replay 會議音檔」 |
| `VoiceInk.xcodeproj/project.pbxproj` | UPDATE | `CURRENT_PROJECT_VERSION` 247 → 248（Debug + Release **兩處**） |
| `VoiceInkTests/MeetingChannelSplitterTests.swift` | CREATE | AC-1 |
| `VoiceInkTests/PCMDownsamplerTests.swift` | CREATE | 抽出後的位元等價 |
| `VoiceInkTests/MeetingPCMRingBufferTests.swift` | CREATE | AC-3 |
| `VoiceInkTests/MeetingCopilotReplayTests.swift` | CREATE | AC-14 的音訊半部（fake ASR） |
| `VoiceInkTests/MeetingCaptureRegressionTests.swift` | CREATE | **AC-2（錄音落檔零回歸）** |

> **pbxproj**：專案用 `PBXFileSystemSynchronizedRootGroup`（`project.pbxproj:78-97`），新 `.swift` 檔**自動入 target**，不需手動註冊。唯一要改 pbxproj 的是 build number。

## NOT Building（M1 明確不做）

- Cue 偵測、四分類、去重 → **M2**
- Tier 0 / Tier 1 / Tier 2、SSE client、`AIService.streamChat` → **M2**
- 接地（brief / RAG / 螢幕 OCR）→ **M2**
- SwiftData `meeting.store`（`MeetingLiveSession` / `MeetingLiveCue`）→ **M2**
- Overlay、`sharingType = .none`、點擊穿透、peek 熱鍵、說話淡出 → **M3**
- 「會議錄音管理」側欄頁、設定 UI、修 `.toggleMeetingRecording` 缺失的 `ShortcutRecorder` → **M4**
- 術語表偏置（雲端 ASR only）→ M2 順帶
- **不重構 `CoreAudioRecorder` 的 ring buffer 去共用**（只抽降頻）——聽寫路徑風險不成比例

---

## Step-by-Step Tasks

### Task 1: 實機聲道佈局 probe 🔴 擋在一切之前

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/MeetingChannelLayout.swift`

> **這不是猜的，是量出來的。** aggregate device 的 `AudioBufferList` 是 tap 在前還是 sub-device（mic）在前，CoreAudio 沒有文件保證，`createTapAndAggregate` 裡 dictionary 的 key 順序**不代表** stream 順序。離線 harness 回答不了這題（它從 `MeetingAudioSource` 以下才接手，刻意繞開 CoreAudio）。

- **ACTION**: 寫一個 `#if DEBUG` probe，用**真實**的 tap + aggregate 跑一次，量各聲道 RMS，判定順序。

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingChannelLayout.swift
import Foundation
import os

/// aggregate device 的 AudioBufferList 聲道順序。
///
/// ⚠️ **這個值是實機量測出來的，不是推導的**（Task 1 / `MeetingChannelLayoutProbe`）。
/// CoreAudio 不保證 tap list 與 sub-device list 在 IOProc 的 AudioBufferList 中的先後，
/// 且 `createTapAndAggregate` 裡 composition dictionary 的 key 順序**不代表** stream 順序。
///
/// 切反的後果：把「我自己講的話」當成「對方問的問題」，症狀隱晦、極難察覺。
/// 動這個值之前，重跑 probe。
enum MeetingChannelLayout {
    /// true = tap（系統音／對方）的聲道排在 mic（我）之前。
    /// 量測日期：<填入>　量測機器：<填入>　macOS：<填入>
    static let tapFirst: Bool = true   // ← ⚠️ Task 1 量測後填入真值

    #if DEBUG
    /// 一次性 probe：回報每個聲道的 RMS，供人工判定順序。
    /// 用法（見 Task 1 VALIDATE）：
    ///   1. 麥克風靜音 → 用系統音播一段音樂 → 有能量的那組 = tap
    ///   2. 系統音靜音 → 對麥克風說話 → 有能量的那組 = mic
    static func report(channelBuffers: [[Float]], frameCount: Int) -> [Float] {
        channelBuffers.map { ch in
            guard frameCount > 0, ch.count >= frameCount else { return 0 }
            var sum: Float = 0
            for i in 0..<frameCount { sum += ch[i] * ch[i] }
            return (sum / Float(frameCount)).squareRoot()
        }
    }
    #endif
}
```

- **MIRROR**: `PURE_FUNCTION_NAMESPACE`（`MeetingAudioMixer`）

- **VALIDATE**（**人工，實機**）：
  1. 在 `MeetingCaptureContext.handleIO` 的 deinterleave 迴圈後，暫時加一行 DEBUG log：
     ```swift
     #if DEBUG
     if ioCallbackCount % 100 == 0 {
         let rms = MeetingChannelLayout.report(channelBuffers: channelScratch, frameCount: frameCount)
         os_log("🎚️ ch RMS: %{public}@ (total=%d)", "\(rms.map { String(format: "%.4f", $0) })", totalChannels)
     }
     #endif
     ```
  2. `make deploy`（記憶：**不要 build 進 /tmp**）
  3. **情境 A**：系統設定把麥克風輸入音量調到 0（或拔掉麥克風）→ 開始會議錄製 → 播放音樂 → 看 log：**哪些聲道有能量 = tap**
  4. **情境 B**：把喇叭靜音（系統音無輸出）→ 開始會議錄製（mic 開）→ 對著麥克風說話 → 看 log：**哪些聲道有能量 = mic**
  5. 兩個情境必須互補（A 有能量的聲道，B 應該沒有）。若不互補 → **停下來**，代表假設有問題，回報後再決定。
  6. 把結論寫進 `tapFirst` 的值 + 註解裡的量測日期／機器／macOS 版本。
  7. **移除**步驟 1 的暫時 log。

- **GOTCHA**: `tapFormat.mChannelsPerFrame` 目前是 stereo（`stereoGlobalTapButExcludeProcesses`）→ tap 預期 2 聲道；mic 通常 1 聲道。所以典型情況是 `totalChannels == 3`。但**不要假設**——probe 會告訴你真相。

- **COMMIT**: `feat(meeting-copilot): channel layout probe + measured tapFirst constant`

---

### Task 2: 錄音落檔位元組零回歸 — 迴歸測試先行 🔴 在碰 handleIO 之前

**Files:**
- Create: `VoiceInkTests/MeetingCaptureRegressionTests.swift`

> Task 7 要動 `handleIO`——那是**寫使用者會議錄音檔**的 realtime 路徑。改壞了你會先失去一場真實會議的錄音才發現。**先鎖住行為，再動它。**

- **ACTION**: 鎖住「`mixToMono` 的輸出不因 copilot seam 而改變」。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingCaptureRegressionTests.swift
import XCTest
@testable import VoiceInk

/// AC-2：copilot seam 不得改變寫進 AAC 的樣本。
/// handleIO 的落檔路徑 = deinterleave → mixToMono → ExtAudioFileWriteAsync。
/// seam 插在 mixToMono **之前** 且只做讀取，所以 mixToMono 的輸入與輸出都必須逐位元不變。
final class MeetingCaptureRegressionTests: XCTestCase {

    /// 固定輸入 → 固定 mono 輸出。這組 golden 值在 seam 加入前後必須完全一致。
    func testMixToMonoGoldenOutputUnchanged() {
        let tapL: [Float] = [0.10, -0.20, 0.30, -0.40]
        let tapR: [Float] = [0.50, -0.60, 0.70, -0.80]
        let mic:  [Float] = [0.90, -1.00, 0.05, -0.15]

        let mono = MeetingAudioMixer.mixToMono(
            channelBuffers: [tapL, tapR, mic],
            frameCount: 4
        )

        // (0.10+0.50+0.90)/3, (-0.20-0.60-1.00)/3, (0.30+0.70+0.05)/3, (-0.40-0.80-0.15)/3
        let expected: [Float] = [0.5, -0.6, 0.35, -0.45]
        XCTAssertEqual(mono.count, 4)
        for (i, e) in expected.enumerated() {
            XCTAssertEqual(mono[i], e, accuracy: 1e-5, "frame \(i)")
        }
    }

    /// seam 只讀不寫：把同一份 channelScratch 先餵給 sink 再餵給 mixToMono，
    /// mixToMono 的結果必須與「沒有 sink」時完全相同。
    func testSinkDoesNotMutateChannelBuffers() {
        let channels: [[Float]] = [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]
        let before = MeetingAudioMixer.mixToMono(channelBuffers: channels, frameCount: 2)

        let ring = MeetingPCMRingBuffer(slotCount: 8, maxChannels: 4, maxFrames: 512)
        ring.write(channelBuffers: channels, channelCount: 3, frameCount: 2, sampleRate: 48_000)

        let after = MeetingAudioMixer.mixToMono(channelBuffers: channels, frameCount: 2)
        XCTAssertEqual(before, after, "sink 不得改動 channelScratch")
    }
}
```
  Run（**必須用這個完整指令，見專案記憶**）:
  ```bash
  xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
    -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    -only-testing:VoiceInkTests/MeetingCaptureRegressionTests
  ```
  Expected: **FAIL** — `MeetingPCMRingBuffer` 尚不存在（compile error）。第一個 golden 測試本身應該會過。

- **IMPLEMENT**: 本 task 不寫產品碼。**先讓 golden 測試（`testMixToMonoGoldenOutputUnchanged`）單獨綠**，把 `testSinkDoesNotMutateChannelBuffers` 暫時 `XCTSkip`，待 Task 5 完成後解封。

- **VALIDATE**: golden 測試 PASS。

- **GOTCHA**: **`-only-testing` 仍然會編譯測試 target 的所有檔案**（專案記憶）——任何一個測試檔編譯失敗，整輪就失敗。所以暫時 skip 而不是留著 compile error。

- **COMMIT**: `test(meeting-copilot): lock mixToMono golden output before touching handleIO`

---

### Task 3: MeetingChannelSplitter（純函式）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/MeetingChannelSplitter.swift`
- Test:   `VoiceInkTests/MeetingChannelSplitterTests.swift`

- **ACTION**: 依 tap 聲道數，把 deinterleave 後的 `[[Float]]` 切成 `(remote, local)`。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingChannelSplitterTests.swift
import XCTest
@testable import VoiceInk

final class MeetingChannelSplitterTests: XCTestCase {

    /// AC-1：tapChannelCount=2、mic 1 聲道 → remote 取前 2、local 取後 1。
    /// （假設 tapFirst == true；Task 1 量測若為 false，本測試的期望值要對調——
    ///   刻意直接使用 MeetingChannelLayout.tapFirst，讓測試跟著量測結果走。）
    func testSplitsRemoteAndLocalByTapChannelCount() {
        let tapL: [Float] = [1, 1]
        let tapR: [Float] = [2, 2]
        let mic:  [Float] = [9, 9]

        let buffers: [[Float]] = MeetingChannelLayout.tapFirst
            ? [tapL, tapR, mic]
            : [mic, tapL, tapR]

        let out = MeetingChannelSplitter.split(
            channelBuffers: buffers,
            tapChannelCount: 2,
            tapFirst: MeetingChannelLayout.tapFirst
        )

        XCTAssertEqual(out.remote, [tapL, tapR])
        XCTAssertEqual(out.local, [mic])
    }

    /// 麥克風關閉 → 只有 tap，local 為空。
    func testMicDisabledYieldsEmptyLocal() {
        let out = MeetingChannelSplitter.split(
            channelBuffers: [[1, 1], [2, 2]],
            tapChannelCount: 2,
            tapFirst: true
        )
        XCTAssertEqual(out.remote.count, 2)
        XCTAssertTrue(out.local.isEmpty)
    }

    /// 防守：聲道數比 tapChannelCount 少（不該發生，但不能崩）→ 全部當 remote。
    func testFewerChannelsThanTapCountFallsBackToAllRemote() {
        let out = MeetingChannelSplitter.split(
            channelBuffers: [[1, 1]],
            tapChannelCount: 2,
            tapFirst: true
        )
        XCTAssertEqual(out.remote.count, 1)
        XCTAssertTrue(out.local.isEmpty)
    }

    /// 空輸入 / 非法 tapChannelCount → 空，不崩。
    func testEmptyAndInvalidInput() {
        XCTAssertTrue(MeetingChannelSplitter.split(channelBuffers: [], tapChannelCount: 2, tapFirst: true).remote.isEmpty)
        XCTAssertTrue(MeetingChannelSplitter.split(channelBuffers: [[1]], tapChannelCount: 0, tapFirst: true).remote.isEmpty)
    }

    /// subdevice-first 佈局也要正確（若 Task 1 量到的是 false）。
    func testSubdeviceFirstLayout() {
        let mic:  [Float] = [9, 9]
        let tapL: [Float] = [1, 1]
        let tapR: [Float] = [2, 2]
        let out = MeetingChannelSplitter.split(
            channelBuffers: [mic, tapL, tapR],
            tapChannelCount: 2,
            tapFirst: false
        )
        XCTAssertEqual(out.remote, [tapL, tapR])
        XCTAssertEqual(out.local, [mic])
    }
}
```
  Run: 上方完整指令 + `-only-testing:VoiceInkTests/MeetingChannelSplitterTests` — expect **FAIL**（型別不存在）

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingChannelSplitter.swift
import Foundation

/// 把 deinterleave 後的逐聲道緩衝依「tap 聲道數」切成 remote（對方）與 local（我）。
/// 純函式,供 consumer thread 與單元測試共用。
///
/// 這是 meeting-copilot 講者歸屬的**唯一**來源——不使用 diarization。
/// tap（system audio）= 會議中其他人;mic sub-device = 我自己。兩者在同一個
/// IOProc callback 的 AudioBufferList 中天生 sample-aligned（見
/// MeetingCaptureService.swift 檔頭註解 :19-23）。
enum MeetingChannelSplitter {

    /// - Parameters:
    ///   - channelBuffers: deinterleave 後的逐聲道樣本（`MeetingCaptureContext.channelScratch`）
    ///   - tapChannelCount: tap 的聲道數（`kAudioTapPropertyFormat` 讀得）
    ///   - tapFirst: aggregate 的 buffer 順序是否 tap 在前（`MeetingChannelLayout.tapFirst`,實機量測）
    /// - Returns: `(remote, local)`。mic 未啟用時 `local` 為空。
    static func split(
        channelBuffers: [[Float]],
        tapChannelCount: Int,
        tapFirst: Bool
    ) -> (remote: [[Float]], local: [[Float]]) {
        guard !channelBuffers.isEmpty, tapChannelCount > 0 else { return ([], []) }

        let total = channelBuffers.count
        // 聲道數 <= tap 聲道數 → 沒有 mic sub-device,全部是 tap。
        guard total > tapChannelCount else { return (channelBuffers, []) }

        if tapFirst {
            return (
                Array(channelBuffers[0..<tapChannelCount]),
                Array(channelBuffers[tapChannelCount...])
            )
        } else {
            let localCount = total - tapChannelCount
            return (
                Array(channelBuffers[localCount...]),
                Array(channelBuffers[0..<localCount])
            )
        }
    }
}
```

- **MIRROR**: `PURE_FUNCTION_NAMESPACE`

- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingChannelSplitterTests` — expect **PASS**（5 個測試全綠）

- **COMMIT**: `feat(meeting-copilot): MeetingChannelSplitter — speaker attribution by channel group`

---

### Task 4: PCMDownsampler（從 CoreAudioRecorder 抽出，位元等價）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/PCMDownsampler.swift`
- Modify: `VoiceInk/CoreAudioRecorder.swift:938-978`（改呼叫抽出的函式）
- Test:   `VoiceInkTests/PCMDownsamplerTests.swift`

- **ACTION**: 把「Float32 多聲道 interleaved → mono 16k Int16 LE」抽成純函式，兩處共用。**行為逐位元不變。**

- **TEST FIRST**:
```swift
// VoiceInkTests/PCMDownsamplerTests.swift
import XCTest
@testable import VoiceInk

final class PCMDownsamplerTests: XCTestCase {

    /// 同取樣率 → 只做聲道混音 + Int16 轉換,不 resample。
    func testSameRateMixesChannelsAndConvertsToInt16() {
        // 立體聲 2 frame:[L0,R0, L1,R1]
        let input: [Float] = [1.0, 0.0, -1.0, 0.0]
        let out = PCMDownsampler.toMono16kInt16(
            interleaved: input, frameCount: 2, channels: 2,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )
        // frame0 = (1.0+0.0)/2 = 0.5 → 0.5*32767 = 16383
        // frame1 = (-1.0+0.0)/2 = -0.5 → -16383
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], 16383)
        XCTAssertEqual(out[1], -16383)
    }

    /// 降頻 48k → 16k:輸出 frame 數 = ceil(frameCount * 1/3)。
    func testDownsamples48kTo16k() {
        let frames = 300
        let input = [Float](repeating: 0.5, count: frames)  // mono
        let out = PCMDownsampler.toMono16kInt16(
            interleaved: input, frameCount: frames, channels: 1,
            inputSampleRate: 48_000, outputSampleRate: 16_000
        )
        XCTAssertEqual(out.count, 100)
        // 定值訊號 → 插值後仍是定值
        XCTAssertEqual(out[50], 16383)
    }

    /// 削波:超出 ±1.0 的樣本必須夾到 Int16 範圍,不得溢位。
    func testClipsOutOfRangeSamples() {
        let input: [Float] = [2.0, -2.0]
        let out = PCMDownsampler.toMono16kInt16(
            interleaved: input, frameCount: 2, channels: 1,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )
        XCTAssertEqual(out[0], 32767)
        XCTAssertEqual(out[1], -32768)
    }

    /// Data 封裝:little-endian Int16。
    func testPCM16DataIsLittleEndian() {
        let data = PCMDownsampler.pcm16Data(
            interleaved: [1.0], frameCount: 1, channels: 1,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )
        XCTAssertEqual(data.count, 2)
        // 32767 = 0x7FFF → LE bytes = FF 7F
        XCTAssertEqual([UInt8](data), [0xFF, 0x7F])
    }

    /// 邊界:0 frame / 0 聲道 → 空,不崩。
    func testEmptyInput() {
        XCTAssertTrue(PCMDownsampler.toMono16kInt16(
            interleaved: [], frameCount: 0, channels: 1,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        ).isEmpty)
    }
}
```
  Run: `-only-testing:VoiceInkTests/PCMDownsamplerTests` — expect **FAIL**

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/PCMDownsampler.swift
import Foundation

/// Float32 多聲道 interleaved → mono 16kHz Int16 LE。純函式,供錄音路徑與 meeting-copilot 共用。
///
/// ⚠️ **行為逐字抽自 `CoreAudioRecorder.convertAndWriteToFile`（:938-978）**——包含它的線性插值
/// 寫法。**不要「順手修正」任何一行**:PCMDownsamplerTests 鎖的就是位元等價,而聽寫路徑
/// 依賴這個確切行為。
enum PCMDownsampler {

    /// 串流轉錄要求的格式（見 StreamingTranscriptionProvider.sendAudioChunk 註解）。
    static let streamingSampleRate: Double = 16_000

    static func toMono16kInt16(
        interleaved: [Float],
        frameCount: Int,
        channels: Int,
        inputSampleRate: Double,
        outputSampleRate: Double = streamingSampleRate
    ) -> [Int16] {
        guard frameCount > 0, channels > 0, inputSampleRate > 0, outputSampleRate > 0 else { return [] }
        guard interleaved.count >= frameCount * channels else { return [] }

        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCount = Int(Double(frameCount) * ratio)
        guard outputFrameCount > 0 else { return [] }

        var out = [Int16](repeating: 0, count: outputFrameCount)

        if inputSampleRate == outputSampleRate {
            // SOURCE: CoreAudioRecorder.swift:940-952
            for i in 0..<frameCount {
                var sample: Float32 = 0
                for ch in 0..<channels {
                    sample += interleaved[i * channels + ch]
                }
                sample /= Float32(channels)
                let scaled = sample * 32767.0
                let clipped = max(-32768.0, min(32767.0, scaled))
                out[i] = Int16(clipped)
            }
        } else {
            // SOURCE: CoreAudioRecorder.swift:955-977（線性插值,逐字保留）
            for i in 0..<outputFrameCount {
                let inputIndex = Double(i) / ratio
                let inputIndexInt = Int(inputIndex)
                let frac = Float32(inputIndex - Double(inputIndexInt))

                var sample: Float32 = 0
                let idx1 = min(inputIndexInt, frameCount - 1)
                let idx2 = min(inputIndexInt + 1, frameCount - 1)

                for ch in 0..<channels {
                    let s1 = interleaved[idx1 * channels + ch]
                    let s2 = interleaved[idx2 * channels + ch]
                    sample += s1 + frac * (s2 - s1)
                }
                sample /= Float32(channels)

                let scaled = sample * 32767.0
                let clipped = max(-32768.0, min(32767.0, scaled))
                out[i] = Int16(clipped)
            }
        }
        return out
    }

    /// 便利版:直接產出串流 provider 要的 `Data`（16-bit LE）。
    static func pcm16Data(
        interleaved: [Float],
        frameCount: Int,
        channels: Int,
        inputSampleRate: Double,
        outputSampleRate: Double = streamingSampleRate
    ) -> Data {
        let samples = toMono16kInt16(
            interleaved: interleaved, frameCount: frameCount, channels: channels,
            inputSampleRate: inputSampleRate, outputSampleRate: outputSampleRate
        )
        var le = samples.map { $0.littleEndian }
        return le.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    }

    /// 從逐聲道（deinterleave 後）的緩衝直接產出 —— meeting-copilot 的 consumer 用這個,
    /// 因為 splitter 給的是 `[[Float]]` 而非 interleaved。
    static func pcm16Data(
        channelBuffers: [[Float]],
        frameCount: Int,
        inputSampleRate: Double,
        outputSampleRate: Double = streamingSampleRate
    ) -> Data {
        guard !channelBuffers.isEmpty, frameCount > 0 else { return Data() }
        let channels = channelBuffers.count
        var interleaved = [Float](repeating: 0, count: frameCount * channels)
        for c in 0..<channels {
            let ch = channelBuffers[c]
            guard ch.count >= frameCount else { return Data() }
            for i in 0..<frameCount {
                interleaved[i * channels + c] = ch[i]
            }
        }
        return pcm16Data(
            interleaved: interleaved, frameCount: frameCount, channels: channels,
            inputSampleRate: inputSampleRate, outputSampleRate: outputSampleRate
        )
    }
}
```

- **然後改 `CoreAudioRecorder.swift:938-978`**：把整段 if/else 換成
```swift
// SOURCE 已抽出至 PCMDownsampler（meeting-copilot 與聽寫共用）。行為等價。
let mono = PCMDownsampler.toMono16kInt16(
    interleaved: Array(UnsafeBufferPointer(start: inputSamples, count: Int(frameCount) * Int(inputChannels))),
    frameCount: Int(frameCount),
    channels: Int(inputChannels),
    inputSampleRate: inputSampleRate,
    outputSampleRate: outputSampleRate
)
guard mono.count == Int(outputFrameCount) else { return }
for i in 0..<mono.count { outputBuffer[i] = mono[i] }
```
> ⚠️ **GOTCHA**：這段跑在 `audioProcessingQueue`（**不是** realtime thread，見 `CoreAudioRecorder.swift:65`），所以這裡的 `Array(...)` 配置是**可接受**的。**不要**把 `PCMDownsampler` 用在 realtime thread 上。

- **VALIDATE**:
  1. `-only-testing:VoiceInkTests/PCMDownsamplerTests` — **PASS**
  2. **聽寫迴歸**：`make deploy` → 錄一段語音聽寫 → 確認轉錄結果與改動前一致（人工）

- **COMMIT**: `refactor(audio): extract PCMDownsampler from CoreAudioRecorder (behavior-equivalent)`

---

### Task 5: MeetingPCMRingBuffer（SPSC lock-free，照抄 CoreAudioRecorder）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/MeetingPCMRingBuffer.swift`
- Create: `VoiceInk/Services/MeetingCopilot/MeetingPCMSink.swift`
- Test:   `VoiceInkTests/MeetingPCMRingBufferTests.swift`

- **ACTION**: 預配置 slot ring，producer 在 realtime thread 只做 memcpy，滿溢丟最舊並計數。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingPCMRingBufferTests.swift
import XCTest
@testable import VoiceInk

final class MeetingPCMRingBufferTests: XCTestCase {

    func testWriteThenReadRoundTrips() {
        let ring = MeetingPCMRingBuffer(slotCount: 4, maxChannels: 3, maxFrames: 8)
        ring.write(channelBuffers: [[1, 2], [3, 4], [5, 6]], channelCount: 3, frameCount: 2, sampleRate: 48_000)

        let slot = ring.read()
        XCTAssertNotNil(slot)
        XCTAssertEqual(slot?.channelCount, 3)
        XCTAssertEqual(slot?.frameCount, 2)
        XCTAssertEqual(slot?.sampleRate, 48_000)
        XCTAssertEqual(slot?.channelBuffers, [[1, 2], [3, 4], [5, 6]])
        XCTAssertNil(ring.read(), "讀完應為空")
    }

    /// AC-3：滿溢時丟棄並計數,**不阻塞**。
    func testOverflowDropsAndCountsWithoutBlocking() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 1, maxFrames: 4)
        ring.write(channelBuffers: [[1]], channelCount: 1, frameCount: 1, sampleRate: 16_000)
        ring.write(channelBuffers: [[2]], channelCount: 1, frameCount: 1, sampleRate: 16_000)
        // 第 3 次寫入時 ring 已滿（未讀）→ 丟棄
        ring.write(channelBuffers: [[3]], channelCount: 1, frameCount: 1, sampleRate: 16_000)

        XCTAssertEqual(ring.droppedFrames, 1)
        XCTAssertEqual(ring.read()?.channelBuffers, [[1]])
        XCTAssertEqual(ring.read()?.channelBuffers, [[2]])
        XCTAssertNil(ring.read())
    }

    /// 超出 slot 容量的 frame 數 → 丟棄並計入容量丟棄,不越界寫入。
    func testOversizedFrameIsDroppedNotOverflowing() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 1, maxFrames: 4)
        ring.write(channelBuffers: [[1, 2, 3, 4, 5, 6]], channelCount: 1, frameCount: 6, sampleRate: 16_000)
        XCTAssertEqual(ring.droppedFrames, 1)
        XCTAssertNil(ring.read())
    }

    /// 聲道數超過 maxChannels → 丟棄,不越界。
    func testTooManyChannelsDropped() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 2, maxFrames: 4)
        ring.write(channelBuffers: [[1], [2], [3]], channelCount: 3, frameCount: 1, sampleRate: 16_000)
        XCTAssertEqual(ring.droppedFrames, 1)
        XCTAssertNil(ring.read())
    }
}
```
  Run: `-only-testing:VoiceInkTests/MeetingPCMRingBufferTests` — expect **FAIL**

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingPCMSink.swift
import Foundation

/// Realtime-safe PCM sink。**實作必須 lock-free 且不得配置記憶體**——
/// 這個方法在 HAL realtime thread 上被呼叫（MeetingCaptureContext.handleIO）。
protocol MeetingPCMSink: AnyObject, Sendable {
    /// 從 realtime thread 呼叫。`channelBuffers` 是 deinterleave 後的逐聲道樣本
    /// （即 `MeetingCaptureContext.channelScratch`,呼叫端持有,sink 只讀不改）。
    func write(channelBuffers: [[Float]], channelCount: Int, frameCount: Int, sampleRate: Double)
}
```
```swift
// VoiceInk/Services/MeetingCopilot/MeetingPCMRingBuffer.swift
import Foundation
import Atomics

/// 單一生產者（HAL realtime thread）／單一消費者（copilot consumer queue）的 lock-free slot ring。
///
/// **形狀完全照抄 `CoreAudioRecorder` 的 input ring**（`CoreAudioRecorder.swift:68-77, 822-888`）:
/// 同樣的 `ManagedAtomic<UInt64>` 讀寫索引、同樣的 `.relaxed`/`.acquiring`/`.releasing` 記憶體序、
/// 同樣的 backpressure 丟棄語意。**不要自創記憶體序。**
///
/// realtime 側只做:容量檢查 → memcpy 進預配置 slot → releasing store。無配置、無鎖。
///
/// ⚠️ 既有的 `handleIO` 本來就會在 realtime thread 上配置記憶體（`MeetingAudioMixer.mixToMono`
/// 每個 callback 都 `var acc = [Float](repeating:...)` 兩次,見 MeetingAudioMixer.swift:17,29）。
/// 本 sink 做的事**嚴格少於** mixToMono,所以不會讓既有狀況變糟;切分與降頻全部在 consumer 側。
final class MeetingPCMRingBuffer: MeetingPCMSink, @unchecked Sendable {

    struct Slot {
        let channelBuffers: [[Float]]
        let channelCount: Int
        let frameCount: Int
        let sampleRate: Double
    }

    /// 預配置的 slot 儲存體（flat: channel-major）。
    private final class Storage {
        let samples: UnsafeMutablePointer<Float>
        var channelCount: Int = 0
        var frameCount: Int = 0
        var sampleRate: Double = 0
        init(capacity: Int) {
            samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            samples.initialize(repeating: 0, count: capacity)
        }
        deinit { samples.deallocate() }
    }

    private let slots: [Storage]
    private let slotCount: Int
    private let maxChannels: Int
    private let maxFrames: Int

    private let writeIndex = ManagedAtomic<UInt64>(0)
    private let readIndex = ManagedAtomic<UInt64>(0)
    private let dropped = ManagedAtomic<UInt64>(0)

    /// 觀測用:被丟棄的 callback 數（背壓 + 超容量）。
    var droppedFrames: Int { Int(dropped.load(ordering: .relaxed)) }

    init(slotCount: Int = 96, maxChannels: Int = 8, maxFrames: Int = 4096) {
        self.slotCount = slotCount
        self.maxChannels = maxChannels
        self.maxFrames = maxFrames
        self.slots = (0..<slotCount).map { _ in Storage(capacity: maxChannels * maxFrames) }
    }

    // MARK: - Producer（realtime thread）

    func write(channelBuffers: [[Float]], channelCount: Int, frameCount: Int, sampleRate: Double) {
        // 容量檢查（照抄 CoreAudioRecorder:822-825）
        guard channelCount > 0, channelCount <= maxChannels,
              frameCount > 0, frameCount <= maxFrames,
              channelBuffers.count >= channelCount else {
            dropped.wrappingIncrement(ordering: .relaxed)
            return
        }

        // 背壓檢查（照抄 CoreAudioRecorder:827-832）
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        guard w - r < UInt64(slotCount) else {
            dropped.wrappingIncrement(ordering: .relaxed)
            return
        }

        let slot = slots[Int(w % UInt64(slotCount))]
        slot.channelCount = channelCount
        slot.frameCount = frameCount
        slot.sampleRate = sampleRate

        // memcpy,無配置（照抄 CoreAudioRecorder:840 的 slot.samples.update(from:count:)）
        for c in 0..<channelCount {
            channelBuffers[c].withUnsafeBufferPointer { src in
                guard let base = src.baseAddress, src.count >= frameCount else { return }
                (slot.samples + c * maxFrames).update(from: base, count: frameCount)
            }
        }

        writeIndex.store(w + 1, ordering: .releasing)
    }

    // MARK: - Consumer（一般執行緒,可配置）

    func read() -> Slot? {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        guard r < w else { return nil }

        let slot = slots[Int(r % UInt64(slotCount))]
        let ch = slot.channelCount
        let fr = slot.frameCount

        var buffers: [[Float]] = []
        buffers.reserveCapacity(ch)
        for c in 0..<ch {
            let base = slot.samples + c * maxFrames
            buffers.append(Array(UnsafeBufferPointer(start: base, count: fr)))
        }

        let out = Slot(channelBuffers: buffers, channelCount: ch, frameCount: fr, sampleRate: slot.sampleRate)
        readIndex.store(r + 1, ordering: .releasing)
        return out
    }
}
```

- **MIRROR**: `RING_BUFFER`（`CoreAudioRecorder.swift:822-888`）

- **VALIDATE**:
  1. `-only-testing:VoiceInkTests/MeetingPCMRingBufferTests` — **PASS**
  2. 回到 Task 2，**解封** `testSinkDoesNotMutateChannelBuffers`（移除 `XCTSkip`）→ `-only-testing:VoiceInkTests/MeetingCaptureRegressionTests` — **PASS**

- **GOTCHA**: `write` 的 `channelBuffers: [[Float]]` 參數會有一次 ARC retain——嚴格說 realtime thread 上不該有 ARC。但既有 `mixToMono(channelBuffers:)` 已經在做同一件事**且還多配置兩個陣列**，所以這不是新增的違規，而是嚴格更少的工作量。若日後要徹底消除，得改成把 `UnsafePointer` 傳進來——列為未來最佳化，**M1 不做**。

- **COMMIT**: `feat(meeting-copilot): lock-free SPSC ring buffer (mirrors CoreAudioRecorder)`

---

### Task 6: MeetingCopilotConfigStore（最小版）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift`

- **ACTION**: FR-3 要求 `copilotEnabled == false` 時 seam 完全不執行。需要一個開關。

- **TEST FIRST**（併入 `MeetingChannelSplitterTests` 或新建；此處用既有 store 的測試風格，直接讀寫真 UserDefaults 並還原）：
```swift
// 追加到 VoiceInkTests/MeetingCopilotReplayTests.swift（Task 12 建立）或獨立檔
func testConfigStoreDefaultsAndPersistence() {
    let key = "meetingCopilotEnabledV1"
    let original = UserDefaults.standard.object(forKey: key)
    defer {
        if let o = original { UserDefaults.standard.set(o, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    UserDefaults.standard.removeObject(forKey: key)
    let store = MeetingCopilotConfigStore()
    XCTAssertFalse(store.copilotEnabled, "預設必須關閉——未啟用時對既有 app 零影響")

    store.setCopilotEnabled(true)
    XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
}
```

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift
import Foundation
import Combine

/// meeting-copilot 設定。M1 只含音訊骨幹需要的三項;模型／熱鍵／接地開關屬 M2–M4。
///
/// 樣式鏡射 `RecorderConfigStore`（`@Published private(set)` + `…V1` key + `set…()` mutator）。
@MainActor
final class MeetingCopilotConfigStore: ObservableObject {
    static let shared = MeetingCopilotConfigStore()

    private let copilotEnabledKey = "meetingCopilotEnabledV1"
    private let asrModelNameKey = "meetingCopilotASRModelV1"
    private let transcribeLocalMicKey = "meetingCopilotTranscribeLocalMicV1"

    /// 總開關（kill switch）。**預設 false**——未啟用時 realtime seam 完全不執行,零成本。
    @Published private(set) var copilotEnabled: Bool = false

    /// 即時轉錄模型。預設本機 FluidAudio Parakeet（免 API key、免網路往返）。
    /// ⚠️ 本機 ASR **不支援術語偏置**（只有 Deepgram/Speechmatics/Soniox 走
    /// `getCustomVocabularyTerms()`）——設定 UI（M4）必須明示此取捨。
    @Published private(set) var asrModelName: String = "parakeet-tdt-0.6b-v3"

    /// 是否也即時轉錄我的麥克風（local 流）。
    @Published private(set) var transcribeLocalMic: Bool = true

    init() { load() }

    private func load() {
        let d = UserDefaults.standard
        copilotEnabled = d.bool(forKey: copilotEnabledKey)   // 缺省 false
        if let m = d.string(forKey: asrModelNameKey), !m.isEmpty { asrModelName = m }
        if d.object(forKey: transcribeLocalMicKey) != nil {
            transcribeLocalMic = d.bool(forKey: transcribeLocalMicKey)
        }
    }

    func setCopilotEnabled(_ v: Bool) {
        copilotEnabled = v
        UserDefaults.standard.set(v, forKey: copilotEnabledKey)
    }

    func setASRModelName(_ v: String) {
        asrModelName = v
        UserDefaults.standard.set(v, forKey: asrModelNameKey)
    }

    func setTranscribeLocalMic(_ v: Bool) {
        transcribeLocalMic = v
        UserDefaults.standard.set(v, forKey: transcribeLocalMicKey)
    }
}
```

- **MIRROR**: `CONFIG_STORE`

- **VALIDATE**: 測試 PASS；`copilotEnabled` 預設 **false**

- **COMMIT**: `feat(meeting-copilot): minimal config store (enabled / asr model / local mic)`

---

### Task 7: handleIO seam + GraphRates.tapChannelCount 🔴 動 realtime 路徑

**Files:**
- Modify: `VoiceInk/Services/Meeting/MeetingCaptureService.swift`
  - `MeetingCaptureContext`（:45-69）— 加 `pcmSink` + `tapChannelCount` + `sampleRate`
  - `handleIO`（:140 之前）— 插入 seam
  - `GraphRates`（:432 回傳）— 加 `tapChannelCount`
  - `start()`（:250）— 建 context 時注入 sink
  - `rebuildGraphKeepingFile()`（~:594）— **重讀** tapChannelCount

- **ACTION**: 把兩組聲道推進 ring buffer，在 `mixToMono` **之前**。落檔行為零改變。

- **TEST FIRST**: Task 2 的 `MeetingCaptureRegressionTests` 已就位且必須**維持全綠**。本 task 的「測試先行」就是：**改動前先跑一次 Task 2 的測試確認基線綠**，改動後再跑一次確認仍綠。

- **IMPLEMENT**:

1) `MeetingCaptureContext` 加欄位（`MeetingCaptureService.swift:45-69`）：
```swift
private final class MeetingCaptureContext: @unchecked Sendable {
    let extFile: ExtAudioFileRef

    /// [NEW] meeting-copilot 即時 PCM seam。nil = copilot 未啟用 → realtime thread 零額外工作。
    let pcmSink: MeetingPCMSink?
    /// [NEW] tap 的聲道數,供 consumer 側切分 remote/local。裝置重建時會更新。
    var tapChannelCount: Int
    /// [NEW] aggregate 的取樣率,供 consumer 側降頻。
    var sampleRate: Double

    // ... 既有欄位不動 ...

    init(extFile: ExtAudioFileRef, pcmSink: MeetingPCMSink?, tapChannelCount: Int, sampleRate: Double) {
        self.extFile = extFile
        self.pcmSink = pcmSink
        self.tapChannelCount = tapChannelCount
        self.sampleRate = sampleRate
    }
}
```

2) `handleIO` 插入 seam（**就在 `:140` 的 `mixToMono` 之前**）：
```swift
        tapPeak = peak

        // [NEW] meeting-copilot seam:在 mixToMono 把聲道壓扁之前,把逐聲道資料推給 sink。
        // 只讀不改 channelScratch;sink 內部只做 memcpy 進預配置 slot。
        // pcmSink == nil（copilot 未啟用）時,這行是一次 nil 檢查,零成本。
        pcmSink?.write(
            channelBuffers: channelScratch,
            channelCount: totalChannels,
            frameCount: frameCount,
            sampleRate: sampleRate
        )

        var mono = MeetingAudioMixer.mixToMono(channelBuffers: channelScratch, frameCount: frameCount)
        guard mono.count == frameCount else { return }
        // ... 既有落檔邏輯完全不動 ...
```

3) `GraphRates` 帶聲道數（`MeetingCaptureService.swift` 的 struct 定義 + `:432`）：
```swift
private struct GraphRates {
    let tapSampleRate: Double
    let aggregateSampleRate: Double
    let tapChannelCount: Int      // [NEW] — :393 已經讀到了,之前被丟掉
}

// createTapAndAggregate 結尾（:431-432）
let aggregateRate = readNominalSampleRate(deviceID: newAggregateID) ?? tapFormat.mSampleRate
return GraphRates(
    tapSampleRate: tapFormat.mSampleRate,
    aggregateSampleRate: aggregateRate,
    tapChannelCount: Int(tapFormat.mChannelsPerFrame)   // [NEW]
)
```

4) `start()` 注入 sink（`:250`）：
```swift
// [NEW] copilot 啟用時才建 ring buffer;否則 sink = nil,realtime thread 零額外工作（FR-3）。
let sink: MeetingPCMRingBuffer? = MeetingCopilotConfigStore.shared.copilotEnabled
    ? MeetingPCMRingBuffer()
    : nil
copilotRingBuffer = sink   // service 持有一份,供 LiveMeetingAudioSource 取用

let context = MeetingCaptureContext(
    extFile: extFile,
    pcmSink: sink,
    tapChannelCount: rates.tapChannelCount,
    sampleRate: rates.aggregateSampleRate
)
captureContext = context
fileClientSampleRate = rates.aggregateSampleRate
```
並在 service 上加：
```swift
/// [NEW] copilot 的即時音訊環形緩衝;nil = 未啟用。LiveMeetingAudioSource 從這裡取。
private(set) var copilotRingBuffer: MeetingPCMRingBuffer?
```

5) **`rebuildGraphKeepingFile()` 必須重讀聲道數**（~:594）——裝置切換後 tap 格式可能改變：
```swift
// 重建 tap/aggregate 後,更新 context 的聲道數與取樣率。
// ⚠️ 漏了這步 → 切換耳機後聲道會錯位,remote/local 顛倒。
let rates = try createTapAndAggregate(micEnabled: micEnabled)
captureContext?.tapChannelCount = rates.tapChannelCount
captureContext?.sampleRate = rates.aggregateSampleRate
```

- **MIRROR**: 既有 `handleIO` 的 realtime 紀律（不碰 `@MainActor` 的 self，只透過 context 工作）

- **VALIDATE**:
  1. `-only-testing:VoiceInkTests/MeetingCaptureRegressionTests` — **PASS**（落檔行為不變）
  2. 編譯：`xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGNING_ALLOWED=NO build` — 零錯誤
  3. **人工**：`make deploy` → `copilotEnabled = false`（預設）→ 錄一段會議 → 確認 m4a 正常、可轉錄、Obsidian 匯出如常（**零回歸**）
  4. **人工**：`copilotEnabled = true` → 錄一段會議 → 確認 m4a **仍然正常**，且 `copilotRingBuffer.droppedFrames` 保持在 0 或極低

- **GOTCHA**:
  - `MeetingCaptureContext` 是 `private final class`（file-scope），但 `MeetingPCMSink` 是 internal 協定——同 module，可用。
  - 切分與降頻**不要**放在 `handleIO`。realtime 側只有 memcpy。
  - `copilotEnabled` 是在 `start()` 當下讀一次；會議中途改設定**不會**生效（可接受，M1 不處理）。

- **COMMIT**: `feat(meeting-copilot): realtime PCM seam in handleIO (recording bytes unchanged)`

---

### Task 8: MeetingAudioSource 協定 + LiveMeetingAudioSource

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/MeetingAudioSource.swift`
- Create: `VoiceInk/Services/MeetingCopilot/LiveMeetingAudioSource.swift`

- **ACTION**: 建立注入層——**這是「不開 Teams 也能驗證」的整個地基**。

- **TEST FIRST**: 協定本身無行為可測；由 Task 12 的 E2E 覆蓋。本 task 的 gate 是編譯 + Task 9 的 Replay 測試能接上。

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingAudioSource.swift
import Foundation

/// 一輪音訊:已切分好的「對方」與「我」的逐聲道樣本。
struct MeetingAudioFrame {
    /// 對方（system tap 聲道）。
    let remote: [[Float]]
    /// 我（mic sub-device 聲道）。mic 未啟用時為空。
    let local: [[Float]]
    let frameCount: Int
    let sampleRate: Double
}

/// 會議音源的注入層。
///
/// **這是整個離線驗證流程的地基**:`LiveMeetingAudioSource`（CoreAudio）與
/// `ReplayMeetingAudioSource`（預錄 WAV）是它的兩個實作,而 source 以下的一切
/// （降頻 → 雙路 ASR → cue 偵測 → 三層回應）**完全相同**。
/// 因此 replay 驗證的是**真正要上線的那條 pipeline**,不是平行的假貨。
///
/// ⚠️ 這也是測試能不能存在的前提:專案記憶 `voiceink-running-unit-tests` 明載
/// 「CoreAudio AudioDeviceManager init 在 headless 下脆弱」——XCTest **必須**繞開 CoreAudio。
protocol MeetingAudioSource: AnyObject {
    func start() async throws
    func stop() async
    /// 已切分好的音訊流。
    var frames: AsyncStream<MeetingAudioFrame> { get }
}
```
```swift
// VoiceInk/Services/MeetingCopilot/LiveMeetingAudioSource.swift
import Foundation
import os

/// 正式音源:從 `MeetingCaptureService` 的 realtime ring buffer 汲取,依 tap 聲道數切分。
///
/// 切分與降頻都在**這裡**（consumer 側）做,不在 realtime thread 上做。
final class LiveMeetingAudioSource: MeetingAudioSource {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")
    private let ring: MeetingPCMRingBuffer
    private let tapChannelCount: Int
    private let pollInterval: Duration

    private var pumpTask: Task<Void, Never>?
    private var continuation: AsyncStream<MeetingAudioFrame>.Continuation?
    let frames: AsyncStream<MeetingAudioFrame>

    init(ring: MeetingPCMRingBuffer, tapChannelCount: Int, pollInterval: Duration = .milliseconds(10)) {
        self.ring = ring
        self.tapChannelCount = tapChannelCount
        self.pollInterval = pollInterval

        var cont: AsyncStream<MeetingAudioFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        self.continuation = cont
    }

    func start() async throws {
        guard pumpTask == nil else { return }
        let ring = self.ring
        let tapCount = self.tapChannelCount
        let interval = self.pollInterval
        let cont = self.continuation

        pumpTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                var drainedAny = false
                while let slot = ring.read() {
                    drainedAny = true
                    let split = MeetingChannelSplitter.split(
                        channelBuffers: slot.channelBuffers,
                        tapChannelCount: tapCount,
                        tapFirst: MeetingChannelLayout.tapFirst
                    )
                    cont?.yield(MeetingAudioFrame(
                        remote: split.remote,
                        local: split.local,
                        frameCount: slot.frameCount,
                        sampleRate: slot.sampleRate
                    ))
                }
                if !drainedAny {
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        continuation?.finish()
        if ring.droppedFrames > 0 {
            logger.warning("🎧 copilot ring dropped \(self.ring.droppedFrames, privacy: .public) callbacks")
        }
    }
}
```

- **VALIDATE**: 編譯零錯誤。

- **COMMIT**: `feat(meeting-copilot): MeetingAudioSource injection seam + live CoreAudio source`

---

### Task 9: ReplayMeetingAudioSource（讀 WAV，可加速）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/ReplayMeetingAudioSource.swift`

- **ACTION**: 從兩個 WAV 檔（remote / local）依 wall-clock（或加速）吐出 frame。**完全不碰 CoreAudio。**

- **TEST FIRST**: 由 Task 12 的 E2E 覆蓋（本 task 的產出就是那個測試的音源）。

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/ReplayMeetingAudioSource.swift
import Foundation
import AVFoundation

/// 測試/除錯音源:從預錄 WAV 重播,產出與 `LiveMeetingAudioSource` **完全相同形狀**的 frame。
///
/// **不碰 CoreAudio**——這是它能在 XCTest（host-app,headless 脆弱）中執行的原因。
///
/// - `remoteURL`: 對方的聲音（必要）
/// - `localURL`: 我的聲音（可選;nil = 我全程沒說話）
/// - `speed`: 1.0 = 實時;10.0 = 十倍速（測試用,讓 E2E 幾秒內跑完）
/// - `chunkFrames`: 每輪吐幾個 frame（模擬 IOProc 的 buffer 大小）
final class ReplayMeetingAudioSource: MeetingAudioSource {

    enum ReplayError: Error, LocalizedError {
        case cannotOpen(URL)
        var errorDescription: String? {
            switch self {
            case .cannotOpen(let u): return "無法開啟音檔:\(u.lastPathComponent)"
            }
        }
    }

    private let remoteURL: URL
    private let localURL: URL?
    private let speed: Double
    private let chunkFrames: Int

    private var pumpTask: Task<Void, Never>?
    private var continuation: AsyncStream<MeetingAudioFrame>.Continuation?
    let frames: AsyncStream<MeetingAudioFrame>

    init(remoteURL: URL, localURL: URL? = nil, speed: Double = 1.0, chunkFrames: Int = 4800) {
        self.remoteURL = remoteURL
        self.localURL = localURL
        self.speed = max(0.1, speed)
        self.chunkFrames = chunkFrames

        var cont: AsyncStream<MeetingAudioFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    func start() async throws {
        let remote = try Self.readMono(remoteURL)
        let local = try localURL.map { try Self.readMono($0) }
        let rate = remote.sampleRate

        let cont = self.continuation
        let chunk = self.chunkFrames
        let speed = self.speed

        pumpTask = Task.detached(priority: .userInitiated) {
            var offset = 0
            let total = remote.samples.count

            while !Task.isCancelled, offset < total {
                let end = min(offset + chunk, total)
                let n = end - offset

                let remoteChunk = Array(remote.samples[offset..<end])
                // local 較短時補靜音,長度永遠對齊 remote（模擬 sample-aligned 的 aggregate）
                let localChunk: [Float]
                if let l = local {
                    let lEnd = min(offset + n, l.samples.count)
                    if offset < l.samples.count {
                        var c = Array(l.samples[offset..<lEnd])
                        if c.count < n { c.append(contentsOf: [Float](repeating: 0, count: n - c.count)) }
                        localChunk = c
                    } else {
                        localChunk = [Float](repeating: 0, count: n)
                    }
                } else {
                    localChunk = []
                }

                cont?.yield(MeetingAudioFrame(
                    remote: [remoteChunk],                       // 單聲道 remote
                    local: localChunk.isEmpty ? [] : [localChunk],
                    frameCount: n,
                    sampleRate: rate
                ))

                offset = end

                // wall-clock 節奏（speed 倍速）
                let seconds = Double(n) / rate / speed
                if seconds > 0.001 {
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }
            cont?.finish()
        }
    }

    func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        continuation?.finish()
    }

    // MARK: - WAV 讀取

    private struct MonoAudio {
        let samples: [Float]
        let sampleRate: Double
    }

    private static func readMono(_ url: URL) throws -> MonoAudio {
        guard let file = try? AVAudioFile(forReading: url) else { throw ReplayError.cannotOpen(url) }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ReplayError.cannotOpen(url)
        }
        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else { throw ReplayError.cannotOpen(url) }
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)

        // 多聲道 → 等權混 mono（與 MeetingAudioMixer 同語意）
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let ch = channelData[c]
            for i in 0..<frames { mono[i] += ch[i] }
        }
        if channels > 1 {
            let d = Float(channels)
            for i in 0..<frames { mono[i] /= d }
        }
        return MonoAudio(samples: mono, sampleRate: format.sampleRate)
    }
}
```

- **VALIDATE**: 編譯零錯誤；Task 12 的 E2E 會實際驅動它。

- **GOTCHA**: `AVAudioFile` 讀 WAV **不需要** CoreAudio device stack，所以 headless 下安全。**不要**改用 `AVAudioEngine`（那會碰 device）。

- **COMMIT**: `feat(meeting-copilot): ReplayMeetingAudioSource — drive the pipeline from WAV, no CoreAudio`

---

### Task 10: MeetingTranscriptStream 協定 + Live + Fake

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/MeetingTranscriptStream.swift`

- **ACTION**: 包住 `StreamingTranscriptionService`，提供可注入的 fake。**不要改 `StreamingTranscriptionService`**——它服務聽寫路徑。

- **TEST FIRST**: 由 Task 12 覆蓋（Fake 就是那個測試的注入物）。

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingTranscriptStream.swift
import Foundation
import SwiftData

/// 一條即時轉錄流。meeting-copilot 開**兩條**:remote（對方）與 local（我）。
/// 講者歸屬 = 事件從哪條流出來,**不需要 diarization**。
///
/// 為什麼要這層包裝,而不直接用 `StreamingTranscriptionService`:
/// 1. 它的 `createProvider(for:)` 是 **private** 且對不支援串流的 provider 直接 `fatalError`
///    （`StreamingTranscriptionService.swift:252-272`）→ 無法在測試中注入 fake。
/// 2. 它服務聽寫路徑,改它的風險不成比例。
protocol MeetingTranscriptStream: AnyObject {
    func start() async throws
    /// 16kHz mono Int16 LE（`StreamingTranscriptionProvider.sendAudioChunk` 的契約）。
    func send(_ pcm16: Data)
    func finish() async
    var events: AsyncStream<StreamingTranscriptionEvent> { get }
}

// MARK: - Live（包住既有的 StreamingTranscriptionService）

@MainActor
final class LiveMeetingTranscriptStream: MeetingTranscriptStream {

    private let service: StreamingTranscriptionService
    private let model: any TranscriptionModel
    private var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    nonisolated let events: AsyncStream<StreamingTranscriptionEvent>

    init(modelContext: ModelContext, model: any TranscriptionModel) {
        self.model = model
        var cont: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont = $0 }
        self.continuation = cont

        // StreamingTranscriptionService 只透過 closure 回報 partial;committed 由它內部累積。
        // 我們把 partial 直接轉發;committed 在 finish() 時以最終文字補一則。
        self.service = StreamingTranscriptionService(
            modelContext: modelContext,
            onPartialTranscript: { [weak cont] text in
                cont?.yield(.partial(text: text))
            }
        )
    }

    func start() async throws {
        try await service.startStreaming(model: model, context: .currentDefaults)
        continuation?.yield(.sessionStarted)
    }

    nonisolated func send(_ pcm16: Data) {
        // sendAudioChunk 是 nonisolated（StreamingTranscriptionService.swift:176）——
        // 可直接從 consumer thread 呼叫。
        service.sendAudioChunk(pcm16)
    }

    func finish() async {
        if let text = try? await service.stopAndGetFinalText(), !text.isEmpty {
            continuation?.yield(.committed(text: text))
        }
        continuation?.finish()
    }
}

// MARK: - Fake（測試用;腳本化事件）

/// 測試用轉錄流:忽略音訊內容,依腳本吐事件。
///
/// ⚠️ **為什麼 E2E 不用真的 FluidAudio**（SRS 原本說「CI 可跑」是錯的）:
/// (a) `VoiceInkTests` 是 host-app bundle,headless 下 CoreAudio 初始化脆弱;
/// (b) FluidAudio 需要先下載 CoreML 模型,不是純程式碼依賴;
/// (c) 全 repo 沒有任何測試使用 Bundle fixture。
/// 真實 ASR 的驗證放在 `#if DEBUG` 選單（Task 13）由人工執行。
final class FakeMeetingTranscriptStream: MeetingTranscriptStream, @unchecked Sendable {

    /// 收到第 N 個 chunk 時吐出對應事件。
    private let script: [Int: StreamingTranscriptionEvent]
    private let finalText: String?
    private var chunkCount = 0
    private var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?
    let events: AsyncStream<StreamingTranscriptionEvent>

    /// 觀測用:收到的總位元組數（讓測試能斷言「音訊真的流到這裡了」）。
    private(set) var receivedBytes = 0

    init(script: [Int: StreamingTranscriptionEvent] = [:], finalText: String? = nil) {
        self.script = script
        self.finalText = finalText
        var cont: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    func start() async throws { continuation?.yield(.sessionStarted) }

    func send(_ pcm16: Data) {
        receivedBytes += pcm16.count
        chunkCount += 1
        if let e = script[chunkCount] { continuation?.yield(e) }
    }

    func finish() async {
        if let t = finalText { continuation?.yield(.committed(text: t)) }
        continuation?.finish()
    }
}
```

- **VALIDATE**: 編譯零錯誤。

- **GOTCHA**: `StreamingTranscriptionService` 是 `@MainActor`，但 `sendAudioChunk` 是 `nonisolated`。`LiveMeetingTranscriptStream.send` 也標 `nonisolated` 才能從 consumer thread 直接呼叫，**不要**包成 `Task { @MainActor in ... }`（會引入延遲與亂序）。

- **COMMIT**: `feat(meeting-copilot): MeetingTranscriptStream protocol + live wrapper + fake`

---

### Task 11: MeetingLiveTranscriber（雙路接線）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/MeetingLiveTranscriber.swift`

- **ACTION**: source → 降頻 → 兩條 ASR。累積雙軌逐字稿。**這是 M1 的交付核心。**

- **TEST FIRST**: Task 12 的 E2E 就是它的測試。

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingLiveTranscriber.swift
import Foundation
import os

/// 把一個 `MeetingAudioSource` 接到**兩條**轉錄流:remote（對方）與 local（我）。
///
/// **講者歸屬 = 事件從哪條流出來。** 零 diarization、零成本、100% 準確。
@MainActor
final class MeetingLiveTranscriber: ObservableObject {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private let source: MeetingAudioSource
    private let remoteStream: MeetingTranscriptStream
    private let localStream: MeetingTranscriptStream?

    private var pumpTask: Task<Void, Never>?
    private var remoteEventTask: Task<Void, Never>?
    private var localEventTask: Task<Void, Never>?

    /// 累積的逐字稿（committed）。
    @Published private(set) var remoteTranscript: String = ""
    @Published private(set) var localTranscript: String = ""
    /// 最新的未定稿（partial），供 UI 即時顯示。
    @Published private(set) var remotePartial: String = ""
    @Published private(set) var localPartial: String = ""

    /// 每當 remote 有一段 committed 文字時呼叫 —— M2 的 `ResponseCueExtractor` 掛在這裡。
    var onRemoteCommitted: ((String) -> Void)?

    init(
        source: MeetingAudioSource,
        remoteStream: MeetingTranscriptStream,
        localStream: MeetingTranscriptStream?
    ) {
        self.source = source
        self.remoteStream = remoteStream
        self.localStream = localStream
    }

    func start() async throws {
        try await remoteStream.start()
        try await localStream?.start()
        try await source.start()

        startEventConsumers()

        let source = self.source
        let remote = self.remoteStream
        let local = self.localStream

        pumpTask = Task.detached(priority: .userInitiated) {
            for await frame in source.frames {
                if Task.isCancelled { break }

                // remote → 降頻 → 送 ASR
                if !frame.remote.isEmpty {
                    let data = PCMDownsampler.pcm16Data(
                        channelBuffers: frame.remote,
                        frameCount: frame.frameCount,
                        inputSampleRate: frame.sampleRate
                    )
                    if !data.isEmpty { remote.send(data) }
                }

                // local → 降頻 → 送 ASR（若啟用）
                if let local, !frame.local.isEmpty {
                    let data = PCMDownsampler.pcm16Data(
                        channelBuffers: frame.local,
                        frameCount: frame.frameCount,
                        inputSampleRate: frame.sampleRate
                    )
                    if !data.isEmpty { local.send(data) }
                }
            }
        }
    }

    private func startEventConsumers() {
        remoteEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.remoteStream.events {
                switch event {
                case .partial(let t):
                    self.remotePartial = t
                case .committed(let t):
                    guard !t.isEmpty else { continue }
                    self.remoteTranscript += (self.remoteTranscript.isEmpty ? "" : " ") + t
                    self.remotePartial = ""
                    self.onRemoteCommitted?(t)        // ← M2 的接點
                case .error(let e):
                    // 失敗必須靜默（分享螢幕時任何 modal 都會暴露本功能）——只記 log。
                    self.logger.error("🎧 remote ASR error: \(e.localizedDescription, privacy: .public)")
                case .sessionStarted:
                    break
                }
            }
        }

        guard let localStream else { return }
        localEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in localStream.events {
                switch event {
                case .partial(let t):
                    self.localPartial = t
                case .committed(let t):
                    guard !t.isEmpty else { continue }
                    self.localTranscript += (self.localTranscript.isEmpty ? "" : " ") + t
                    self.localPartial = ""
                case .error(let e):
                    self.logger.error("🎧 local ASR error: \(e.localizedDescription, privacy: .public)")
                case .sessionStarted:
                    break
                }
            }
        }
    }

    func stop() async {
        await source.stop()
        pumpTask?.cancel(); pumpTask = nil
        await remoteStream.finish()
        await localStream?.finish()
        remoteEventTask?.cancel(); remoteEventTask = nil
        localEventTask?.cancel(); localEventTask = nil
    }
}
```

- **VALIDATE**: 編譯零錯誤；Task 12 驗證行為。

- **COMMIT**: `feat(meeting-copilot): MeetingLiveTranscriber — dual-stream wiring, speaker attribution by source`

---

### Task 12: 端到端 replay 測試（fake ASR，hermetic）🎯 M1 的驗收

**Files:**
- Create: `VoiceInkTests/MeetingCopilotReplayTests.swift`

- **ACTION**: 用**合成 WAV** 跑完整 pipeline，斷言講者歸屬正確。**不開 Teams、不碰 CoreAudio、不需網路、不需 API key。**

- **TEST FIRST / IMPLEMENT**（此 task 產出的就是測試）：
```swift
// VoiceInkTests/MeetingCopilotReplayTests.swift
import XCTest
import AVFoundation
@testable import VoiceInk

/// M1 的驗收:不開 Teams/Meet、不碰 CoreAudio,用預錄 WAV 端到端驅動 pipeline。
///
/// ASR 用 `FakeMeetingTranscriptStream`（腳本化事件）——見該型別的註解說明為何不用真 FluidAudio。
/// 真實 ASR 的驗證在 `#if DEBUG` 選單（Task 13），由人工執行。
@MainActor
final class MeetingCopilotReplayTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCopilotReplayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// 合成一個 WAV:16kHz mono,指定頻率的正弦波。
    /// （測試不需要「真的語音」——ASR 是 fake;要驗的是**接線**。）
    private func writeSineWAV(named name: String, hz: Double, seconds: Double, amplitude: Float = 0.5) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let rate = 16_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = amplitude * Float(sin(2.0 * .pi * hz * Double(i) / rate))
        }
        try file.write(from: buffer)
        return url
    }

    /// AC-14（音訊半部）:remote 與 local 兩條音訊各自流到**自己的**轉錄流,
    /// 且 committed 文字落到正確的講者欄位。**這是「講者歸屬零成本」的證明。**
    func testEndToEndReplayRoutesRemoteAndLocalToSeparateStreams() async throws {
        let remoteWAV = try writeSineWAV(named: "remote.wav", hz: 440, seconds: 0.5)
        let localWAV  = try writeSineWAV(named: "local.wav",  hz: 880, seconds: 0.5)

        let source = ReplayMeetingAudioSource(
            remoteURL: remoteWAV,
            localURL: localWAV,
            speed: 50.0,          // 加速,測試數百毫秒內完成
            chunkFrames: 1600     // 0.1s @16k
        )

        let remoteASR = FakeMeetingTranscriptStream(finalText: "你會怎麼設計一個短網址服務？")
        let localASR  = FakeMeetingTranscriptStream(finalText: "我先想一下。")

        let transcriber = MeetingLiveTranscriber(
            source: source,
            remoteStream: remoteASR,
            localStream: localASR
        )

        var cues: [String] = []
        transcriber.onRemoteCommitted = { cues.append($0) }

        try await transcriber.start()

        // 等 replay 跑完（0.5s 音檔 / 50x ≈ 10ms,給足餘裕）
        try await Task.sleep(for: .milliseconds(800))
        await transcriber.stop()

        // 1. 兩條流都真的收到音訊
        XCTAssertGreaterThan(remoteASR.receivedBytes, 0, "remote 音訊未流到 ASR")
        XCTAssertGreaterThan(localASR.receivedBytes, 0, "local 音訊未流到 ASR")

        // 2. 位元組數符合 16k mono Int16 的預期量級（0.5s → 16000*0.5*2 = 16000 bytes）
        XCTAssertEqual(Double(remoteASR.receivedBytes), 16_000, accuracy: 2_000)

        // 3. **講者歸屬正確** —— 這是 M1 的全部意義
        XCTAssertEqual(transcriber.remoteTranscript, "你會怎麼設計一個短網址服務？")
        XCTAssertEqual(transcriber.localTranscript, "我先想一下。")

        // 4. remote committed 有觸發回呼（M2 的 cue 抽取會掛在這）
        XCTAssertEqual(cues, ["你會怎麼設計一個短網址服務？"])
    }

    /// mic 關閉（localStream = nil）→ 只有 remote 流,不崩。
    func testReplayWithoutLocalStream() async throws {
        let remoteWAV = try writeSineWAV(named: "remote_only.wav", hz: 440, seconds: 0.3)
        let source = ReplayMeetingAudioSource(remoteURL: remoteWAV, localURL: nil, speed: 50.0, chunkFrames: 1600)
        let remoteASR = FakeMeetingTranscriptStream(finalText: "只有對方在說話")

        let transcriber = MeetingLiveTranscriber(source: source, remoteStream: remoteASR, localStream: nil)
        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(600))
        await transcriber.stop()

        XCTAssertGreaterThan(remoteASR.receivedBytes, 0)
        XCTAssertEqual(transcriber.remoteTranscript, "只有對方在說話")
        XCTAssertTrue(transcriber.localTranscript.isEmpty)
    }

    /// 降頻正確性:48kHz 來源 → 送出的位元組數應為 16k 的量。
    func testDownsamplesFrom48kSource() async throws {
        let url = tmpDir.appendingPathComponent("remote48k.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(48_000)   // 1 秒
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { ch[i] = 0.5 * Float(sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0)) }
        try file.write(from: buffer)

        let source = ReplayMeetingAudioSource(remoteURL: url, localURL: nil, speed: 100.0, chunkFrames: 4800)
        let remoteASR = FakeMeetingTranscriptStream()
        let transcriber = MeetingLiveTranscriber(source: source, remoteStream: remoteASR, localStream: nil)

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(600))
        await transcriber.stop()

        // 1 秒 @16kHz mono Int16 = 32000 bytes（±容忍插值邊界）
        XCTAssertEqual(Double(remoteASR.receivedBytes), 32_000, accuracy: 3_000)
    }
}
```

- **VALIDATE**:
  ```bash
  xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
    -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    -only-testing:VoiceInkTests/MeetingCopilotReplayTests
  ```
  Expected: **PASS**（3 個測試全綠）

- **GOTCHA**: `AVAudioFile(forWriting:settings:)` 用 `format.settings` 會寫出 **Float32 WAV**（`AVAudioFile` 預設 caf/wav 容器依副檔名）。`ReplayMeetingAudioSource.readMono` 用 `file.processingFormat` 讀，格式自洽，不需手動轉換。

- **COMMIT**: `test(meeting-copilot): end-to-end replay from WAV — speaker attribution verified without Teams`

---

### Task 13: DEBUG 選單「Replay 會議音檔」（真 ASR，人工驗證）

**Files:**
- Modify: `VoiceInk/Views/MenuBarView.swift`

- **ACTION**: 讓你能在**不開任何會議軟體**的情況下，用真實的 FluidAudio ASR 跑一個 WAV，肉眼看逐字稿出來。

- **TEST FIRST**: 無自動化測試（這是人工驗證工具）。gate 是編譯 + 人工跑通。

- **IMPLEMENT**（加在 `MenuBarView` 的 menu 內）：
```swift
#if DEBUG
Divider()
Button("Replay 會議音檔…（DEBUG）") {
    Task { await runMeetingReplayDebug() }
}
#endif
```
```swift
#if DEBUG
@MainActor
private func runMeetingReplayDebug() async {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio]
    panel.message = "選一個「對方聲音」的音檔（模擬會議中對方說話）"
    guard panel.runModal() == .OK, let remoteURL = panel.url else { return }

    guard let model = TranscriptionModelRegistry.allModels
        .first(where: { $0.name == MeetingCopilotConfigStore.shared.asrModelName && $0.supportsStreaming })
        ?? TranscriptionModelRegistry.allModels.first(where: { $0.supportsStreaming })
    else {
        NotificationManager.shared.showNotification(title: "找不到可用的串流模型", type: .error)
        return
    }

    let source = ReplayMeetingAudioSource(remoteURL: remoteURL, localURL: nil, speed: 1.0)
    let remoteASR = LiveMeetingTranscriptStream(modelContext: modelContext, model: model)
    let transcriber = MeetingLiveTranscriber(source: source, remoteStream: remoteASR, localStream: nil)

    transcriber.onRemoteCommitted = { text in
        os_log("🎧 [replay] remote committed: %{public}@", text)
    }

    do {
        try await transcriber.start()
        NotificationManager.shared.showNotification(title: "Replay 開始 — 看 Console 的 🎧 log", type: .info)
    } catch {
        os_log("🎧 [replay] failed: %{public}@", error.localizedDescription)
    }
}
#endif
```

- **VALIDATE**（**人工**）:
  1. `make deploy`
  2. 錄一段自己講「你會怎麼設計一個短網址服務？」存成 WAV（或用任何含語音的音檔）
  3. 選單 → 「Replay 會議音檔…（DEBUG）」→ 選那個檔
  4. Console.app 過濾 `🎧` → **應該看到真實 ASR 的 committed 文字流出來**
  5. 這證明：**source → 降頻 → 真 ASR → 講者歸屬** 整條路在真實模型下可用，且**全程沒開任何會議軟體**

- **GOTCHA**: `TranscriptionModelRegistry` 的公開存取子名稱需確認（`allModels` vs `predefinedModels`）——`TranscriptionModelRegistry.swift:9` 是 `private static let predefinedModels`，所以要找它的 public 出口。實作時 grep `TranscriptionModelRegistry\.` 看既有呼叫端怎麼取。

- **COMMIT**: `feat(meeting-copilot): DEBUG replay menu — validate with real ASR, no meeting app`

---

### Task 14: Bump build + 全套迴歸

**Files:**
- Modify: `VoiceInk.xcodeproj/project.pbxproj`（`CURRENT_PROJECT_VERSION` 247 → **248**，**Debug + Release 兩處都要**）

- **ACTION**: 收尾。

- **VALIDATE**:
  1. **全套測試**（不只新的——確認零回歸）:
     ```bash
     xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
       -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
       -xcconfig LocalBuild.xcconfig \
       CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
       CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
       SWIFT_ENABLE_EXPLICIT_MODULES=NO
     ```
     EXPECT: **全綠**，特別是既有的 `MeetingAudioMixerTests` / `MeetingImportTests` / `MeetingExportTests` / `RecorderPipelineTests`
  2. 確認 `grep -c "CURRENT_PROJECT_VERSION = 248" VoiceInk.xcodeproj/project.pbxproj` → **2**
  3. **回報 build 號給使用者**（專案記憶 `voiceink-report-build-number`），並提醒他們 `! make deploy` 後到 Settings → About 確認顯示 build 248

- **COMMIT**: `chore: bump build to 248 (meeting-copilot M1)`

---

## Testing Strategy

### Unit Tests

| Test | Input | Expected | Edge? |
|---|---|---|---|
| `MeetingChannelSplitterTests::splitsRemoteAndLocalByTapChannelCount` | 3 聲道，tapCount=2 | remote=前2、local=後1 | — |
| `…::testMicDisabledYieldsEmptyLocal` | 2 聲道，tapCount=2 | local 空 | ✅ |
| `…::testFewerChannelsThanTapCountFallsBackToAllRemote` | 1 聲道，tapCount=2 | 全 remote，不崩 | ✅ |
| `…::testSubdeviceFirstLayout` | tapFirst=false | 仍正確切分 | ✅ |
| `PCMDownsamplerTests::testDownsamples48kTo16k` | 300 frame @48k | 100 frame | — |
| `…::testClipsOutOfRangeSamples` | ±2.0 | 夾到 ±32767/32768 | ✅ |
| `…::testPCM16DataIsLittleEndian` | 1.0 | `[0xFF, 0x7F]` | — |
| `MeetingPCMRingBufferTests::testOverflowDropsAndCountsWithoutBlocking` | 寫滿再寫 | 丟棄+計數，不阻塞 | ✅ |
| `…::testOversizedFrameIsDroppedNotOverflowing` | frame > maxFrames | 丟棄，不越界 | ✅ |
| `MeetingCaptureRegressionTests::testMixToMonoGoldenOutputUnchanged` | 固定 3 聲道 | golden mono | 🔴 AC-2 |
| `MeetingCopilotReplayTests::testEndToEndReplayRoutesRemoteAndLocalToSeparateStreams` | 兩個合成 WAV | **講者歸屬正確** | 🔴 M1 驗收 |

### Edge Cases Checklist
- [x] 空輸入（splitter / downsampler / ring）
- [x] 麥克風未啟用（local 流為空）
- [x] Ring buffer 滿溢
- [x] Frame 數超出 slot 容量
- [x] 聲道數超出 maxChannels
- [x] 48k → 16k 降頻
- [x] 削波（±2.0）
- [x] tapFirst 兩種佈局
- [ ] **裝置切換中途改變 tapChannelCount** — Task 7 有處理，但**只有人工可驗**（拔耳機）

---

## Validation Commands

### 編譯（快速 gate，不啟動 host）
```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```
EXPECT: 零錯誤。（專案記憶：compile-only 未簽章沒問題，是最快的 gate。）

### 單元測試（**必須用這個完整形式**）
```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  -only-testing:VoiceInkTests/<TestClass>
```
EXPECT: PASS。

> 🔴 **為什麼不能用普通 `xcodebuild test`**（專案記憶 `voiceink-running-unit-tests`）：
> `VoiceInkTests` 是 **host-app** bundle，runner 會啟動 `VoiceInk.app`。未簽章時
> SwiftData 的 `dictionary` store 用 `.private("iCloud...")` CloudKit → `PFCloudKitContainerProvider`
> 在無 iCloud entitlement 下 `_os_crash`，**host 開機即死**。上面的完整形式鏡射 `make local`
> （ad-hoc 簽章 + `LOCAL_BUILD` flag → `#if LOCAL_BUILD` 把 dictionary CloudKit 翻成 `.none`）。
> `SWIFT_ENABLE_EXPLICIT_MODULES=NO` 也是必要的，否則 Xcode 16+ 在 `@testable import` 會失敗。
> **`-only-testing` 仍會編譯所有測試檔**——任一檔編譯錯誤 = 整輪失敗。

### 部署（**人工執行，不要自動跑**）
```bash
make deploy
```
> 專案記憶 `voiceink-build-no-ghost-apps`：**不要 build 進 /tmp**（LaunchServices 會註冊重複圖示）。
> 專案記憶：**不自動 deploy**——由使用者自己跑，然後在 Settings → About 確認 build 號。

### 手動驗證
- [ ] **Task 1 probe**：兩個情境（靜音 mic / 靜音喇叭）互補 → `tapFirst` 值確定
- [ ] `copilotEnabled = false`（預設）→ 錄會議 → m4a 正常、轉錄正常、Obsidian 匯出正常（**零回歸**）
- [ ] `copilotEnabled = true` → 錄會議 → m4a **仍然正常**；`droppedFrames` 為 0 或極低
- [ ] 語音聽寫（dictation）仍正常（Task 4 動了 `CoreAudioRecorder`）
- [ ] **Task 13**：DEBUG 選單 replay 一個含語音的 WAV → Console 看到真實 ASR 的 🎧 committed 文字（**全程沒開 Teams/Meet**）
- [ ] 會議中途拔/插耳機 → 聲道不錯位（remote 仍是對方）

---

## Acceptance Criteria

- [ ] **AC-1**（聲道分流）：`MeetingChannelSplitterTests` 全綠，且 `tapFirst` 是**實機量測**的值，不是猜的
- [ ] **AC-2**（錄音零回歸）：`MeetingCaptureRegressionTests` 綠；人工錄一段會議，m4a 與匯出行為與改動前一致
- [ ] **AC-3**（realtime 不阻塞）：`MeetingPCMRingBufferTests` 綠；滿溢丟棄並計數
- [ ] **AC-14（音訊半部）**：`MeetingCopilotReplayTests` 綠——**不開 Teams/Meet、不碰 CoreAudio**，從 WAV 端到端跑出正確的雙軌講者歸屬
- [ ] 全套測試零回歸（既有 Meeting* / Recorder* 測試全綠）
- [ ] 編譯零錯誤、零新警告
- [ ] Build 248，已回報給使用者

## Completion Checklist
- [ ] 程式碼遵循既有 pattern（ring buffer 記憶體序照抄、純函式 namespace、config store 樣式）
- [ ] `PCMDownsampler` 抽出後**行為逐位元等價**，聽寫路徑無回歸
- [ ] realtime seam 只做 memcpy，切分與降頻在 consumer 側
- [ ] `copilotEnabled = false` 時 realtime thread **零額外工作**
- [ ] 沒有硬編碼值（slot 數、maxFrames 皆為 init 參數）
- [ ] 沒有超出 M1 範圍的新增（無 cue / 無 LLM / 無 overlay / 無新頁面 / 無 SwiftData store）

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **`tapFirst` 量錯** | M | **H** — remote/local 顛倒，症狀隱晦 | Task 1 兩情境互補驗證；不互補就停下來 |
| 動 `handleIO` 弄壞錄音落檔 | M | **H** — 會先失去一場真實會議才發現 | Task 2 **先**寫迴歸測試；Task 7 前後各跑一次；人工錄一段確認 |
| 抽 `PCMDownsampler` 弄壞聽寫 | M | H | 位元等價測試；人工聽寫迴歸 |
| ring buffer 記憶體序寫錯 | M | H | **照抄** `CoreAudioRecorder:822-888`，一字不改 |
| 裝置切換後聲道錯位 | M | H | Task 7 步驟 5 重讀 `tapChannelCount`；人工拔耳機驗證 |
| host-app 測試在 CI/headless 掛掉 | **H** | M | 完整 `xcodebuild test` 形式（記憶）；E2E 用 fake ASR **不碰 CoreAudio** |

## Notes

- **M1 刻意不含任何 UI**。交付是「從 WAV 跑出雙軌逐字稿 + 錄音零回歸」，這正是全案風險最高、最該先釘死的部分。
- `MeetingLiveTranscriber.onRemoteCommitted` 是 **M2 的接點**——`ResponseCueExtractor` 直接掛上去。
- SRS 的四項修正（見文件頂部）**應在 M1 完成後回寫進 SRS**，避免 M2 重蹈。

---

## M2–M4 路線圖（本 plan 不做）

| Milestone | 範圍 | FR | AC | 依賴 |
|---|---|---|---|---|
| **M2 — Cue 偵測 + 三層回應 + SSE** | `meeting.store`（`MeetingLiveSession` / `MeetingLiveCue`）；repo 內自持 `StreamingChatClient`（SSE）+ `AIService.streamChat`；`ResponseCueExtractor`（四分類 + 去重）；`Tier0Classifier`（**免 LLM**）；`GroundingProvider`（brief + RAG 重用 `RetrievalService` + 螢幕 OCR 重用 `ScreenCaptureService.captureAndExtractText()`）；`AnswerCoordinator`（Tier1/Tier2 + **最新一則預跑** + 取消） | FR-8 ~ FR-20 | AC-4 ~ AC-14 | M1（`onRemoteCommitted`） |
| **M3 — Overlay + 熱鍵** | `CopilotOverlayPanel`（clone `MeetingIndicatorPanel` + `sharingType = .none` + `ignoresMouseEvents` + `.screenSaver` level + 近鏡頭定位 + 說話淡出）；toggle + **peek（按住顯示，沿用 push-to-talk 的 keyDown/keyUp）**兩個熱鍵 | FR-21 ~ FR-28 | AC-15 ~ AC-17 | M2 |
| **M4 — 頁面 + 設定 + 既有缺陷修復** | `ViewType.meetingCopilot`（2 檔 6 處）；「會議錄音管理」頁（clone `VoiceLibraryView`）；完整 `MeetingCopilotConfigStore` + 設定 UI（三個模型、brief、各開關、**本機 ASR 無術語偏置的明示**）；**補上 `.toggleMeetingRecording` 缺失的 `ShortcutRecorder`**（自 build 227 起無法設定，且逃過衝突偵測） | FR-29 ~ FR-32 | AC-18、AC-19 | M3 |

> M3 的 **AC-15（螢幕分享排除）必須實機驗證三種情境**：Teams 原生分享整螢幕／Chrome+Meet `getDisplayMedia` 分享整螢幕／分享單一視窗。**任一失敗，整個功能的前提就不成立**——這是 M3 的 go/no-go gate。
