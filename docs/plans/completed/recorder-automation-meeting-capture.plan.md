---
linear_issue: null
---
# Plan: Meeting Capture（免 bot 會議錄製 → Recorder 管線）

> **For agentic workers:** `/prp-implement` routes this plan by `Metadata.Type` below. Tasks use Mode B（任務先測）: per task, write one behavior-locking test first where a testable seam exists; hardware-only paths (CoreAudio capture graph) are validated manually per AC + the Linear verification checklist.

## Summary
One hotkey / menu-bar click records an online meeting: system audio (CoreAudio **process tap**) + microphone mixed into one mono m4a, then fed through the EXISTING recorder import pipeline (`.meetingCapture` origin → scribe_v2 whole-file transcription+diarization → 繁中 → fixed 「會議」 category (skips classifier) → template → Obsidian). New: `MeetingCaptureService` (capture graph), `MeetingCaptureController` (glue), floating indicator window, menu-bar item, global shortcut, settings section, `NSAudioCaptureUsageDescription`.

## User Story
As a 線上會議頻繁的使用者, I want 一鍵錄下整場會議（雙方聲音）並在會後自動得到分好類的 Obsidian 筆記, so that 我不必邊開會邊記錄也不怕漏掉決議。

## Problem → Solution
會議內容完全在管線外（只有錄音筆/資料夾來源）→ 新增「會議」音源：tap+mic 混錄檔案落地後，複用管線後段 100%（去重、轉錄、diarization、分類、模板、匯出、保留策略）。

## Metadata
- **Module**: recorder-automation
- **Parent Plan**: N/A
- **Source PRD**: docs/prd/meeting-capture-to-obsidian.prd.md
- **Source Feature SRS**: docs/srs/recorder-automation-meeting-capture.srs.md
- **Source Module Spec**: docs/spec/recorder-automation.spec.md
- **Source Linear Issue**: N/A（產生後回填）
- **Type**: feature
- **Size**: L
- **Complexity**: Large
- **Rigor**: balanced
- **Mode**: B — 任務先測
- **TDD**: on (task-level; hardware paths manual)
- **Commit cadence**: per-task
- **Estimated Files**: ~15（9 modified + 6 created）

---

## ⚠️ Implementation Progress（2026-07-07 交接註記：Fable → Opus）

> 實作進行到一半因模型切換暫停。已完成部分 commit 在 `feat/meeting-capture` 分支（**尚未 build 驗證**）。接手者：從「待做」繼續，第一步先跑 Validation Commands 的 build＋測試把已完成部分驗綠。

**已完成**（依本 plan 任務）：
- ✅ T1 設定欄位 — 落地 API：`meetingFixedCategorySelection`/`meetingFixedCategory`/`meetingMicEnabled`/`setMeetingFixedCategoryId(_:)`/`setMeetingMicEnabled(_:)`；測試 `MeetingCaptureConfigTests`（含臨時「會議」分類 upsert/清理）
- ✅ T2+T4（合併執行）— `process` 簽名：`fixedCategory: RecorderCategory? = nil` 位於 `device:` 與 `modelContext:` 之間；`assignCategory` 含零 provider 時跳過 AI 標題的 fallback；ATM 額外擴了兩個 gate：失敗通知改 switch（`.recorderImport, .meetingCapture`）、`transcribeSamples` 的 ElevenLabs 單次 diarize 路徑以 `runsRecorderPipeline` bool 涵蓋 meeting；`來源:` frontmatter 不走 esc()（測試契約）；chip 在 RecordingCard header badge 列
- ✅ T5 — 三檔已建；CoreAudio 序列照 AudioCap 驗證；**build 時優先驗證的不確定 API**：`CATapDescription(stereoGlobalTapButExcludeProcesses:)` 標籤、`.isPrivate` vs `privateTap`、AAC ASBD 若 -50 錯誤補 `mFramesPerPacket = 1024`、`kAudioSubDeviceDriftCompensationKey`；`MeetingCaptureContext` 為 file-scope class（避 actor 隔離推斷）；有 `static let shared`
- ✅ T8 設定 UI（「會議錄製」Section 位於 分析/分類 之間；「上方→下方」文案已修）
- ✅ T9 Info.plist `NSAudioCaptureUsageDescription`

**待做**：T3（`stageMeetingFile`/`importMeetingFile`——照 plan Task 3，enum 已含 `sourceLabel` 參數）→ T6 → T7 → 每波 build＋測試＋code-reviewer → T10（OPTIONAL 可跳過）→ T11 收尾（bump build → `make deploy` → spec Change History → Linear 驗證 issue，Linear 尚未授權，需先 `/mcp` 授權）。

**Deviation 記錄**：測試按任務分檔（`MeetingCaptureConfigTests` / `MeetingAudioMixerTests` / `MeetingOriginTests` / `MeetingExportTests` 已建；`MeetingImportTests` / `MeetingShortcutTests` 待 T3/T7），非 plan 原寫的單一 `MeetingCaptureTests.swift`——避免多 agent 同檔衝突。

---

## UX Design

### Before
```
┌ 線上會議 ────────────────────────────┐
│ Zoom/Meet 開會 → 會後憑記憶補記/不記   │
│ VoiceInk 只吃錄音筆與資料夾           │
└──────────────────────────────────────┘
```

### After
```
┌ 會議開始前 ──────────────────────────┐   ┌ 錄製中（浮動指示器）─┐
│ 選單列「開始會議錄製」或 全域快捷鍵    │ → │ ● 00:42:13   [停止]  │
└──────────────────────────────────────┘   └──────────────────────┘
        ↓ 停止
┌ 自動 ────────────────────────────────────────────────────────────┐
│ 通知「已匯入，處理中」→ 轉錄+講者分離 → 固定歸「會議」→ 模板分析   │
│ → Obsidian/會議/250707_1030 <AI標題>.md；Recording Management 可查 │
└──────────────────────────────────────────────────────────────────┘
```

### Interaction Changes
| Touchpoint | Before | After | Notes |
|---|---|---|---|
| MenuBarView | 無會議項 | 「開始會議錄製」↔「停止會議錄製 (mm:ss)」 | 標題由 controller @Published 驅動 |
| 全域快捷鍵 | — | `.toggleMeetingRecording`（utility action，任何聽寫狀態皆可觸發） | Settings 快捷鍵頁自動出現（列舉 `globalUtilityActions`） |
| 浮動視窗 | — | 紅點＋計時＋停止鈕（non-activating panel） | 與聽寫 mini recorder 各自獨立、可並存 |
| 錄音設定頁 | 無 | 新 Section「會議錄製」：固定分類 Picker、收麥克風開關 | 依現有 Form Section 樣式 |
| Recording Management | — | 會議紀錄多一個來源標籤 chip「會議 · Zoom」 | `recorderSourceLabel` |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/recorder-automation-meeting-capture.srs.md` | all | 本功能需求 + AC |
| P0 | `docs/spec/recorder-automation.spec.md` | Key Decisions 節 | 地雷：ElevenLabs 整檔、不 chunk、不加本地 diarizer |
| P0 | https://github.com/insidegui/AudioCap | ProcessTap 相關檔 | tap+aggregate+IOProc 的權威範例（Task 5 實作前必讀） |
| P1 | `VoiceInk/Services/RecorderAutomation/RecorderImportService.swift` | 91-137, 365-394 | importNewFiles/copyIntoAppStorage/pendingMeta 慣例 |
| P1 | `VoiceInk/Services/AudioFileTranscriptionManager.swift` | 48-61, 89-108, 263-311 | addToQueue/origin 分支/後處理呼叫點 |
| P1 | `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | 83-205 | process/suggestCategory/makeRecorderTitle 結構 |
| P1 | `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` | 33-133, 173-211 | per-field 設定慣例 |
| P1 | `VoiceInk/Views/Recorder/MiniWindowManager.swift` + `MiniRecorderPanel.swift` | all | 指示器視窗管理/panel 樣式要鏡射 |
| P1 | `VoiceInk/Shortcuts/ShortcutAction.swift` + `RecordingShortcutManager.swift` | all / 212-268, 314-337 | utility shortcut 註冊與處理 |
| P1 | `VoiceInk/Services/RecorderAutomation/VaultExportService.swift` | buildMarkdown/ExportInput | Task 4 加 sourceLabel 前確認參數序 |
| P2 | `VoiceInk/CoreAudioRecorder.swift` | 343-470, 555-600 | AUHAL/ExtAudioFile 慣例（格式常數參考） |
| P2 | `VoiceInk/Views/Settings/RecorderModeSettingsView.swift` | 1-70 | 設定 Section 樣式 |
| P2 | `VoiceInk/Views/MenuBarView.swift` | 38-95 | 選單按鈕樣式 |
| P2 | 記憶檔 `voiceink-running-unit-tests` / `voiceink-build-no-ghost-apps` / `voiceink-report-build-number` | — | 測試/建置/部署鐵律 |

## External Documentation

| Topic | Source | Key Takeaway |
|---|---|---|
| Process tap | developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps | `CATapDescription` → `AudioHardwareCreateProcessTap` → 私有 aggregate → IOProc |
| 參考實作 | github.com/insidegui/AudioCap；github.com/makeusabrew/audiotee | PID→ProcessObject 轉換、權限 probe、teardown 順序 |
| TCC | NSAudioCaptureUsageDescription（bundle resources 文件） | 首次建 tap 觸發提示；**無狀態查詢 API**；bucket=`SystemAudioCaptureRequests`（重置：`tccutil reset SystemAudioCaptureRequests`）；未正確簽名→提示永不出現 |
| 已知雷 | maven.de/2025/04/coreaudio-taps-for-dummies | ⚠️ AVAudioEngine 對 tap-backed aggregate 靜默失效 → 必須 raw HAL IOProc；裝置切換→全零 buffer→tap+aggregate 一起重建 |

---

## Patterns to Mirror

### CONFIG_FIELD（新設定欄位完整鏈）
```swift
// SOURCE: RecorderConfigStore.swift:50,83,120,204-207（recorderConvertToTraditional 全鏈）
@Published private(set) var recorderConvertToTraditional: Bool = false      // 1. property
private let recConvertTraditionalKey = "recorderConvertToTraditionalV1"     // 2. V1 key
recorderConvertToTraditional = UserDefaults.standard.bool(forKey: recConvertTraditionalKey) // 3. load()
func setRecorderConvertToTraditional(_ on: Bool) {                          // 4. setter
    recorderConvertToTraditional = on
    UserDefaults.standard.set(on, forKey: recConvertTraditionalKey)
}
// 「0/nil 也是合法值」時用 object 判存在：SOURCE :127
recorderMinImportSizeValue = (UserDefaults.standard.object(forKey: recMinImportSizeValueKey) as? Int) ?? 500
```

### QUEUE_ORIGIN_BRANCH（origin 標記 → 後處理）
```swift
// SOURCE: AudioFileTranscriptionManager.swift:265-268, 286-293
if case let .recorderImport(deviceId, fingerprint) = item.origin {
    transcription.recorderSourceDeviceId = deviceId
    transcription.importFingerprint = fingerprint
}
...
if case let .recorderImport(deviceId, _) = item.origin,
   let enhancementService = engine.enhancementService,
   let aiService = enhancementService.getAIService() {
    let device = RecorderConfigStore.shared.device(byId: deviceId)
    await RecorderPostProcessor.shared.process(
        transcription: transcription, rawText: cleanedText, device: device,
        modelContext: modelContext, enhancementService: enhancementService, aiService: aiService)
}
```

### IMPORT_ENQUEUE（保留 inFlight/pendingMeta/startProcessing 慣例）
```swift
// SOURCE: RecorderImportService.swift:122-135
inFlight.insert(c.fingerprint)   // reserve before the async copy (closes the await gap)
guard let copied = await copyIntoAppStorage(c.url) else { inFlight.remove(c.fingerprint); continue }
pendingMeta[c.fingerprint] = (c.fileName, c.byteSize)
AudioTranscriptionManager.shared.addToQueue(urls: [copied],
    origin: .recorderImport(deviceId: device.id, fingerprint: c.fingerprint))
...
let recorderMode = RecorderTranscriptionConfig.current()
AudioTranscriptionManager.shared.startProcessing(modelContext: modelContext, engine: engine, mode: recorderMode)
```

### SHORTCUT_ACTION（utility 快捷鍵四件套）
```swift
// SOURCE: ShortcutAction.swift:29-54（storageName）、:56-89（displayName）、:91-97（globalUtilityActions）
static let globalUtilityActions: [Self] = [
    .pasteLastTranscription, .pasteLastEnhancement, .retryLastTranscription,
    .openHistoryWindow, .quickAddToDictionary
]
// SOURCE: RecordingShortcutManager.swift:314-337（處理 switch；utility 走 onKeyUp、不受聽寫狀態 gate）
private func handleGlobalShortcut(_ action: ShortcutAction) async {
    switch action {
    case .quickAddToDictionary:
        DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
    default: break
    }
}
```

### WINDOW_MANAGER（浮動視窗管理器）
```swift
// SOURCE: MiniWindowManager.swift:33-62
func show() { if panel == nil { initializeWindow() }; panel?.show() }
func hide() { panel?.orderOut(nil) }
private func initializeWindow() {
    deinitializeWindow()
    let metrics = MiniRecorderPanel.calculateWindowMetrics()
    let newPanel = MiniRecorderPanel(contentRect: metrics)
    newPanel.contentView = NSHostingController(rootView: makeView()).view
    panel = newPanel
    windowController = NSWindowController(window: newPanel)
}
```

### NOTIFICATION_WITH_ACTION（權限引導通知）
```swift
// SOURCE: RecordingShortcutManager.swift:286-300
NotificationManager.shared.showNotification(
    title: String(localized: "Recording shortcut needs Input Monitoring permission"),
    type: .warning, duration: 8.0,
    actionButton: (String(localized: "Open Settings"), Self.openInputMonitoringSettings))
private static func openInputMonitoringSettings() {
    _ = CGRequestListenEventAccess()
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
        NSWorkspace.shared.open(url)
    }
}
```

### SETTINGS_SECTION（Form Section＋InfoTip 樣式）
```swift
// SOURCE: RecorderModeSettingsView.swift:19-37
Form {
    Section("語音轉文字") {
        Toggle(isOn: convertTraditionalBinding) {
            HStack(spacing: 4) {
                Text("輸出繁體中文")
                InfoTip("用 OpenCC 把逐字稿與講者分段從簡體轉成繁體…")
            }
        }
    }
}
```

### TEST_STRUCTURE（host-app 測試慣例：真 UserDefaults 要還原、in-memory container）
```swift
// SOURCE: VoiceInkTests/RecorderImportServiceTests.swift:6-33
@MainActor
final class RecorderImportServiceTests: XCTestCase {
    func testScanReturnsOnlyNewSupportedFiles() async throws {
        let store = RecorderConfigStore.shared
        let prevValue = store.recorderMinImportSizeValue
        store.setRecorderMinImportSize(value: 0, unit: prevUnit)
        defer { store.setRecorderMinImportSize(value: prevValue, unit: prevUnit) }
        let ctx = try ModelContext(ModelContainer(for: ImportLedgerEntry.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        ...
    }
}
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` | UPDATE | meetingFixedCategory 選擇 + meetingMicEnabled |
| `VoiceInk/Models/AudioFileQueueItem.swift` | UPDATE | `QueueItemOrigin.meetingCapture(fingerprint:)` |
| `VoiceInk/Services/AudioFileTranscriptionManager.swift` | UPDATE | meeting 分支：fingerprint/label/後處理(fixedCategory) |
| `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | UPDATE | `process(fixedCategory:)` + `assignCategory` helper |
| `VoiceInk/Services/RecorderAutomation/RecorderImportService.swift` | UPDATE | `stageMeetingFile` + `importMeetingFile` |
| `VoiceInk/Models/Transcription.swift` | UPDATE | `recorderSourceLabel: String?`（additive） |
| `VoiceInk/Services/RecorderAutomation/VaultExportService.swift` | UPDATE | frontmatter `來源:` sourceLabel |
| `VoiceInk/Views/History/RecorderHistoryView.swift` | UPDATE | RecordingCard 來源標籤 chip |
| `VoiceInk/Services/Meeting/MeetingCaptureService.swift` | CREATE | tap+aggregate+IOProc+ExtAudioFile 擷取核心 |
| `VoiceInk/Services/Meeting/MeetingAudioMixer.swift` | CREATE | 純函式混音（可測） |
| `VoiceInk/Services/Meeting/MeetingCaptureController.swift` | CREATE | 狀態/計時/通知/匯入 glue |
| `VoiceInk/Views/Meeting/MeetingIndicatorView.swift` + `MeetingIndicatorWindowManager.swift` | CREATE | 浮動指示器 |
| `VoiceInk/Shortcuts/ShortcutAction.swift` + `RecordingShortcutManager.swift` | UPDATE | `.toggleMeetingRecording` |
| `VoiceInk/Views/MenuBarView.swift` | UPDATE | 開始/停止項 |
| `VoiceInk/Views/Settings/RecorderModeSettingsView.swift` | UPDATE | 「會議錄製」Section |
| `VoiceInk/Info.plist` | UPDATE | `NSAudioCaptureUsageDescription` |
| `VoiceInkTests/MeetingCaptureTests.swift` | CREATE | Task 1-5 的 seam 測試 |

## NOT Building
- 即時字幕/串流 HUD；自動開錄；行事曆/平台整合；雙聲道我方/對方分離；自建 AEC（喇叭迴音靠 UI 提示戴耳機）；FR-8 會議 app 提醒通知（列為 Task 10 OPTIONAL，可延後）。
- ❌ 任何 chunking 邏輯改動、❌ 本地 diarizer（module spec Key Decisions 鎖死）。

---

## Step-by-Step Tasks

### Task 1: 會議設定欄位（RecorderConfigStore）
- **ACTION**: 新增固定分類三態選擇（未設定→預設找名為「會議」的分類；`""` sentinel→自動分類；uuid→指定分類）與 `meetingMicEnabled`。
- **TEST FIRST**（加入 `VoiceInkTests/MeetingCaptureTests.swift`）:
  ```swift
  @MainActor
  final class MeetingCaptureConfigTests: XCTestCase {
      func testMeetingCategorySelectionThreeStates() {
          let store = RecorderConfigStore.shared
          let prev = UserDefaults.standard.string(forKey: "recorderMeetingFixedCategoryV1")
          defer { UserDefaults.standard.set(prev, forKey: "recorderMeetingFixedCategoryV1")
                  if prev == nil { UserDefaults.standard.removeObject(forKey: "recorderMeetingFixedCategoryV1") } }

          UserDefaults.standard.removeObject(forKey: "recorderMeetingFixedCategoryV1")
          store.load()
          // 未設定 → 預設解析為名為「會議」的內建分類（seed 保證存在）
          XCTAssertEqual(store.meetingFixedCategory?.name, "會議")

          store.setMeetingFixedCategoryId(nil)          // 使用者明選「自動分類」
          XCTAssertNil(store.meetingFixedCategory)

          let target = store.categories.first(where: { $0.isFallback })!
          store.setMeetingFixedCategoryId(target.id)    // 指定分類
          XCTAssertEqual(store.meetingFixedCategory?.id, target.id)
      }
      func testMeetingMicEnabledDefaultTrueAndPersists() {
          let store = RecorderConfigStore.shared
          let prev = store.meetingMicEnabled
          defer { store.setMeetingMicEnabled(prev) }
          store.setMeetingMicEnabled(false)
          XCTAssertFalse(store.meetingMicEnabled)
      }
  }
  ```
  Run: `xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig SWIFT_ENABLE_EXPLICIT_MODULES=NO -only-testing:VoiceInkTests/MeetingCaptureConfigTests` — expect FAIL（成員不存在）
- **IMPLEMENT**（`RecorderConfigStore.swift`，鏡射 CONFIG_FIELD）:
  ```swift
  /// 會議錄製固定分類選擇。三態儲存於同一 String key：
  ///   key 不存在＝未設定 → 預設解析為名為「會議」的分類（找不到則自動分類）；
  ///   ""＝使用者明選自動分類；uuidString＝指定分類。
  @Published private(set) var meetingFixedCategorySelection: String?   // raw storage mirror
  /// 會議錄製是否混入麥克風（false＝只錄系統音訊）。預設 true。
  @Published private(set) var meetingMicEnabled: Bool = true
  private let meetingFixedCategoryKey = "recorderMeetingFixedCategoryV1"
  private let meetingMicEnabledKey    = "recorderMeetingMicEnabledV1"
  // load() 內：
  meetingFixedCategorySelection = UserDefaults.standard.string(forKey: meetingFixedCategoryKey)
  meetingMicEnabled = (UserDefaults.standard.object(forKey: meetingMicEnabledKey) as? Bool) ?? true
  // setters：
  func setMeetingFixedCategoryId(_ id: UUID?) {
      meetingFixedCategorySelection = id?.uuidString ?? ""   // "" = 明選自動
      UserDefaults.standard.set(meetingFixedCategorySelection, forKey: meetingFixedCategoryKey)
  }
  func setMeetingMicEnabled(_ on: Bool) {
      meetingMicEnabled = on; UserDefaults.standard.set(on, forKey: meetingMicEnabledKey)
  }
  /// 解析後的固定分類；nil＝走自動分類。
  var meetingFixedCategory: RecorderCategory? {
      switch meetingFixedCategorySelection {
      case nil:  return categories.first(where: { $0.name == "會議" })
      case "":   return nil
      case let raw?: return UUID(uuidString: raw).flatMap { category(byId: $0) }
      }
  }
  ```
- **MIRROR**: CONFIG_FIELD；三態存在性判斷鏡射 `:127` 的 object-presence 技巧。
- **VALIDATE**: 同上指令 — expect PASS。
- **COMMIT**: `feat(meeting): recorder config for fixed category + mic toggle`

### Task 2: `.meetingCapture` origin ＋ 固定分類縫合點
- **ACTION**: origin 新 case；ATM 分支設 metadata＋以 fixedCategory 呼叫後處理；PostProcessor 增參數（預設 nil，既有路徑零行為變化）。
- **TEST FIRST**:
  ```swift
  @MainActor
  final class MeetingOriginTests: XCTestCase {
      func testMeetingOriginCarriesFingerprintAndLabel() {
          let o = QueueItemOrigin.meetingCapture(fingerprint: "fp1", sourceLabel: "會議 · Zoom")
          guard case let .meetingCapture(fp, label) = o else { return XCTFail() }
          XCTAssertEqual(fp, "fp1"); XCTAssertEqual(label, "會議 · Zoom")
      }
  }
  ```
  Run（`-only-testing:VoiceInkTests/MeetingOriginTests`）— expect FAIL
- **IMPLEMENT**:
  1. `AudioFileQueueItem.swift:26-29`:
     ```swift
     enum QueueItemOrigin: Equatable {
         case manual
         case recorderImport(deviceId: UUID, fingerprint: String)
         case meetingCapture(fingerprint: String, sourceLabel: String)
     }
     ```
  2. `RecorderPostProcessor.swift`：`process(...)` 增 `fixedCategory: RecorderCategory? = nil`；`:128` 改為：
     ```swift
     if let fixed = fixedCategory {
         await assignCategory(transcription: transcription, category: fixed, rawText: rawText,
                              modelContext: modelContext, aiService: aiService)
     } else {
         await suggestCategory(transcription: transcription, rawText: rawText, modelContext: modelContext,
                               enhancementService: enhancementService, aiService: aiService)
     }
     ```
     新 helper（鏡射 suggestCategory `:180-191` 的欄位＋標題邏輯，**不呼叫 classifier**）:
     ```swift
     /// 固定分類：設定分類欄位＋產生標題，完全不觸發 TranscriptClassificationService。
     private func assignCategory(
         transcription: Transcription, category: RecorderCategory, rawText: String,
         modelContext: ModelContext, aiService: AIService
     ) async {
         transcription.recorderCategoryId = category.id
         transcription.recorderCategoryName = category.name
         transcription.classificationConfidence = nil
         let model = resolvedClassifierModel(aiService: aiService)   // 便宜模型產標題，與 suggestCategory 一致
         let recordingTime = transcription.importFingerprint
             .flatMap { ImportLedger.shared.fileName(forFingerprint: $0, in: modelContext) }
             .flatMap { RecorderRecordingTime.parse(fromFileName: $0) }
             ?? transcription.timestamp
         transcription.recorderTitle = await makeRecorderTitle(
             from: rawText, model: model, aiService: aiService, timestamp: recordingTime)
         try? modelContext.save()
     }
     ```
  3. `AudioFileTranscriptionManager.swift`：在 `:265-268` 後加、`:286-293` 後加（鏡射 QUEUE_ORIGIN_BRANCH）:
     ```swift
     if case let .meetingCapture(fingerprint, sourceLabel) = item.origin {
         transcription.importFingerprint = fingerprint
         transcription.recorderSourceLabel = sourceLabel      // Task 4 新欄位
     }
     ...
     if case .meetingCapture = item.origin,
        let enhancementService = engine.enhancementService,
        let aiService = enhancementService.getAIService() {
         await RecorderPostProcessor.shared.process(
             transcription: transcription, rawText: cleanedText, device: nil,
             fixedCategory: RecorderConfigStore.shared.meetingFixedCategory,
             modelContext: modelContext, enhancementService: enhancementService, aiService: aiService)
     }
     ```
     並把 `:303` 失敗通知的 `if case .recorderImport` 擴成 `if case .recorderImport = item.origin` `|| case .meetingCapture`（Swift 寫法：`switch item.origin { case .recorderImport, .meetingCapture: notify; default: break }`）。
- **GOTCHA**: `process` 內 `finalizeImport`（`:137-139`）只在 `device != nil` 走 → meeting（device nil）天然跳過 delete-after-import，正確。
- **VALIDATE**: 新測試 PASS＋既有 `VoiceInkTests` 全綠（參數預設 nil 不影響舊路徑）。
- **COMMIT**: `feat(meeting): meetingCapture queue origin + fixed-category post-processing seam`

### Task 3: `stageMeetingFile` / `importMeetingFile`（RecorderImportService）
- **ACTION**: 會議檔進管線的入口：staging 複製（可測純步驟）＋ enqueue/startProcessing（薄 orchestrator）。
- **TEST FIRST**:
  ```swift
  @MainActor
  final class MeetingImportTests: XCTestCase {
      func testStageMeetingFileFingerprintsAndCopies() async throws {
          let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtg-\(UUID())")
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: dir) }
          let src = dir.appendingPathComponent("250707_1030 會議Zoom.m4a")
          try Data([1,2,3,4]).write(to: src)

          let staged = try await RecorderImportService.shared.stageMeetingFile(src)
          XCTAssertEqual(staged.fingerprint, try ImportLedger.contentFingerprint(for: src))
          XCTAssertEqual(staged.displayName, "250707_1030 會議Zoom.m4a")
          XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedURL.path))
          XCTAssertTrue(staged.stagedURL.path.contains("RecorderImports"))
      }
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**（`RecorderImportService.swift`，鏡射 IMPORT_ENQUEUE 與 `copyIntoAppStorage:368-382`）:
  ```swift
  struct StagedMeetingFile { let stagedURL: URL; let fingerprint: String; let displayName: String; let byteSize: Int }

  /// 可測純步驟：fingerprint＋複製進 RecorderImports staging。不 enqueue、不動 inFlight。
  func stageMeetingFile(_ src: URL) async throws -> StagedMeetingFile {
      let fp = try await Self.fingerprintOffMain(src)
      let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      guard let copied = await copyIntoAppStorage(src) else { throw CocoaError(.fileWriteUnknown) }
      return StagedMeetingFile(stagedURL: copied, fingerprint: fp,
                               displayName: src.lastPathComponent, byteSize: size)
  }

  /// 會議錄製完成 → 走既有管線。與 importNewFiles 對稱：inFlight 護欄、pendingMeta 供 ledger、
  /// Recorder Mode 轉錄、通知。成功 enqueue 後刪除 capture 暫存原檔（app 內部檔案，非使用者資料）。
  func importMeetingFile(_ src: URL, sourceLabel: String) {
      guard let modelContext, let engine else { logger.error("Import service not configured"); return }
      Task { @MainActor in
          guard let staged = try? await stageMeetingFile(src) else {
              NotificationManager.shared.showNotification(title: "會議錄音匯入失敗", type: .error, duration: 5)
              return
          }
          if inFlight.contains(staged.fingerprint) { return }
          if ImportLedger.shared.isImported(fingerprint: staged.fingerprint, in: modelContext) { return }
          inFlight.insert(staged.fingerprint)
          pendingMeta[staged.fingerprint] = (staged.displayName, staged.byteSize)
          AudioTranscriptionManager.shared.addToQueue(urls: [staged.stagedURL],
              origin: .meetingCapture(fingerprint: staged.fingerprint, sourceLabel: sourceLabel))
          try? FileManager.default.removeItem(at: src)
          NotificationManager.shared.showNotification(title: "會議錄音已匯入，處理中…", type: .info, duration: 3)
          AudioTranscriptionManager.shared.startProcessing(
              modelContext: modelContext, engine: engine, mode: RecorderTranscriptionConfig.current())
      }
  }
  ```
- **GOTCHA**: capture 檔名帶 `yyMMdd_HHmm` 開錄時間戳（Task 5 命名），`RecorderRecordingTime.parse` 的既有 regex `[0-9]{6}_[0-9]{4}` 直接吃到 → 筆記時間＝會議開始時間，零額外程式。
- **VALIDATE**: 新測試 PASS；`ImportLedgerTests` 等既有測試綠。
- **COMMIT**: `feat(meeting): stage + import meeting recordings into the pipeline`

### Task 4: `recorderSourceLabel` 欄位＋匯出 frontmatter＋卡片 chip
- **ACTION**: Transcription additive 欄位；VaultExport frontmatter `來源:`；RecordingCard 顯示 chip。
- **TEST FIRST**（先讀 VaultExportService 確認 `ExportInput` 參數序再定稿測試）:
  ```swift
  final class MeetingExportTests: XCTestCase {
      func testFrontmatterIncludesSourceLabel() {
          let input = VaultExportService.ExportInput(
              analysis: "A", rawTranscript: "R", categoryName: "會議", deviceName: nil,
              sourceLabel: "會議 · Zoom",                    // 新參數（default nil，插在 deviceName 後）
              date: Date(timeIntervalSince1970: 0),
              transcriptionModel: nil, enhancementModel: nil, confidence: nil)
          let md = VaultExportService.shared.buildMarkdown(input, includeRawTranscript: false)
          XCTAssertTrue(md.contains("來源: 會議 · Zoom"))
      }
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**:
  1. `Transcription.swift`（鏡射既有 optional 欄位區 `:37-47`）: `var recorderSourceLabel: String?`（additive，lightweight migration）。
  2. `VaultExportService.ExportInput` 加 `var sourceLabel: String? = nil`；`buildMarkdown` frontmatter 段在 `deviceName` 行後加：`if let label = input.sourceLabel { lines.append("來源: \(label)") }`（比照 deviceName 的寫法——動手前先讀該檔確認 frontmatter 組裝的實際行）。
  3. `RecorderPostProcessor.exportToVault`（`:318-334`）建 `ExportInput` 時傳 `sourceLabel: transcription.recorderSourceLabel`。
  4. `RecorderHistoryView.swift` RecordingCard 標題列（`:280-320` 一帶，比照分類 badge 樣式）加：
     ```swift
     if let label = item.recorderSourceLabel {
         Text(label).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
             .background(Capsule().fill(Color.secondary.opacity(0.15)))
     }
     ```
- **VALIDATE**: 新測試 PASS＋建置綠。
- **COMMIT**: `feat(meeting): source label on transcription, vault frontmatter, history chip`

### Task 5: `MeetingCaptureService`＋`MeetingAudioMixer`（核心擷取）
- **ACTION**: process tap＋私有 aggregate（tap＋mic，各開 drift compensation）＋ raw HAL IOProc → 混音 mono → ExtAudioFile AAC m4a；輸出裝置變更→整組重建；任何失敗→ finalize 保檔。
- **TEST FIRST**（純混音數學）:
  ```swift
  final class MeetingAudioMixerTests: XCTestCase {
      func testMixAveragesAllChannelsToMono() {
          // 兩個 buffer：tap 立體聲 [L=1,R=0 ...]、mic 單聲道 [0.5 ...]，同 frame 數
          let tap: [[Float]] = [[1, 1], [0, 0]]      // ch-major: L[frames], R[frames]
          let mic: [[Float]] = [[0.5, 0.5]]
          let mono = MeetingAudioMixer.mixToMono(channelBuffers: tap + mic, frameCount: 2)
          XCTAssertEqual(mono, [0.5, 0.5])           // (1+0+0.5)/3
      }
      func testMixHandlesEmptyInput() {
          XCTAssertEqual(MeetingAudioMixer.mixToMono(channelBuffers: [], frameCount: 0), [])
      }
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**:
  1. `MeetingAudioMixer.swift`（純函式，vDSP 平均）:
     ```swift
     import Accelerate
     enum MeetingAudioMixer {
         /// 所有輸入聲道等權平均成 mono。channelBuffers = 各聲道的 Float32 樣本（等長 frameCount）。
         static func mixToMono(channelBuffers: [[Float]], frameCount: Int) -> [Float] {
             guard frameCount > 0, !channelBuffers.isEmpty else { return [] }
             var acc = [Float](repeating: 0, count: frameCount)
             for ch in channelBuffers { vDSP.add(acc, ch, result: &acc) }
             var out = [Float](repeating: 0, count: frameCount)
             vDSP.divide(acc, Float(channelBuffers.count), result: &out)
             return out
         }
     }
     ```
  2. `MeetingCaptureService.swift` — 骨架（**實作前必讀 AudioCap**；常數名以 AudioCap/Apple docs 為準）:
     ```swift
     @MainActor final class MeetingCaptureService: ObservableObject {
         enum State: Equatable { case idle, recording(started: Date), failed(String) }
         @Published private(set) var state: State = .idle
         private var tapID = AudioObjectID(kAudioObjectUnknown)
         private var aggregateID = AudioDeviceID(kAudioObjectUnknown)
         private var ioProcID: AudioDeviceIOProcID?
         private var extFile: ExtAudioFileRef?
         private var outputURL: URL?
         private var deviceChangeListener: AudioObjectPropertyListenerBlock?

         func start(micEnabled: Bool) async throws -> Void {
             // 1) 檔名帶開錄時間戳（供 RecorderRecordingTime.parse 回收）＋前景 app 名
             //    "250707_1030 會議Zoom.m4a" → staging tmp dir（ApplicationSupport/.../MeetingCaptures）
             // 2) tap：CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObject()])
             //    tapDesc.uuid 保留；AudioHardwareCreateProcessTap(tapDesc, &tapID)
             //    ※ 建 tap 這步觸發 TCC；err != noErr → throw .permissionOrTapFailed
             // 3) aggregate（私有）：AudioHardwareCreateAggregateDevice([
             //      kAudioAggregateDeviceUIDKey: UUID().uuidString,
             //      kAudioAggregateDeviceIsPrivateKey: true,
             //      kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
             //                                         kAudioSubTapDriftCompensationKey: true]],
             //      kAudioAggregateDeviceSubDeviceListKey: micEnabled
             //          ? [[kAudioSubDeviceUIDKey: defaultInputDeviceUID(),
             //              kAudioSubDeviceDriftCompensationKey: true]] : []
             //    ], &aggregateID)
             // 4) ExtAudioFileCreateWithURL(url, kAudioFileM4AType, aacASBD(mono, aggRate), …)
             //    kExtAudioFileProperty_ClientDataFormat = Float32 packed mono @ aggRate
             // 5) AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inData, _, _, _ in
             //      let mono = MeetingAudioMixer.mixToMono(channelBuffers: floats(from: inData), frameCount: n)
             //      ExtAudioFileWriteAsync(extFile, n, ablFor(mono))
             //    }; AudioDeviceStart(aggregateID, ioProcID)
             // 6) default-output-device listener（kAudioHardwarePropertyDefaultOutputDevice on
             //    kAudioObjectSystemObject）→ Task { await rebuildGraphKeepingFile() }
             // 7) state = .recording(started: now)
         }
         /// teardown tap+aggregate → 重建（沿用同一 extFile 續寫）。重建失敗 → stop() 保檔＋通知。
         private func rebuildGraphKeepingFile() async { /* stop IOProc → destroy agg+tap → 2)-5) */ }
         func stop() async -> URL? {
             // AudioDeviceStop → DestroyIOProcID → AudioHardwareDestroyAggregateDevice
             // → AudioHardwareDestroyProcessTap → ExtAudioFileDispose(flush) → state=.idle → return outputURL
         }
     }
     ```
  3. 零訊號 probe：開錄後 5 秒累計 RMS；若 tap 聲道全零 → `NotificationManager` warning「未收到系統音訊——可能未授權或會議尚無聲音」＋開設定 action（鏡射 NOTIFICATION_WITH_ACTION；pane anchor 先試 `Privacy_AudioCapture`，無效 fallback `com.apple.preference.security`——實作時驗證，見 Open Question）。
- **GOTCHA**（全部來自研究，違反即壞）:
  - ❌ AVAudioEngine 驅動 tap aggregate 會靜默失效 → 只能 raw HAL IOProc。
  - aggregate 只放 tap＋mic，**不要**把被 tap 的實體輸出裝置也放進去。
  - `exclusive`/mute 行為旗標弄反 → 錄到靜音；照 AudioCap 的預設。
  - TCC 無查詢 API；未簽名 build 提示永不彈 → 一律用 `make deploy` 版測試；授權後可能需重啟 app（AC-2 驗證）。
  - 裝置切換後 all-zero：tap 與 aggregate **兩者一起**重建；只重啟 IOProc 不可靠。
  - IOProc 內不 alloc：mixer scratch buffer 預先配置、ExtAudioFileWriteAsync 先以 0 frames 預熱（Apple 慣例）。
- **VALIDATE**: mixer 測試 PASS；`make local` 建置綠；真機手動：`tccutil reset SystemAudioCaptureRequests com.prakashjoshipax.VoiceInk` 後首錄觸發授權 → 播 YouTube＋講話 2 分鐘 → 停止 → staging 出現可播放 m4a（雙方聲音皆在）。
- **COMMIT**: `feat(meeting): CoreAudio process-tap capture service + mono mixer`

### Task 6: `MeetingCaptureController`＋指示器＋選單列
- **ACTION**: glue singleton（start/stop/toggle、經過時間、通知、willTerminate 保檔）＋浮動指示器＋選單列動態項。
- **TEST FIRST**: 無穩定 seam（UI/AppKit）——以 VALIDATE 手動清單替代（Mode B 的硬體豁免）。
- **IMPLEMENT**:
  1. `MeetingCaptureController.swift`:
     ```swift
     @MainActor final class MeetingCaptureController: ObservableObject {
         static let shared = MeetingCaptureController()
         @Published private(set) var isRecording = false
         @Published private(set) var elapsedText = "00:00"
         private let service = MeetingCaptureService()
         private var indicator: MeetingIndicatorWindowManager?
         private var timer: Timer?
         private var sourceLabel = "會議"
         private init() {
             NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                 object: nil, queue: .main) { [weak self] _ in
                 Task { @MainActor in await self?.stopAndImport() }   // 保檔：quit 也 finalize
             }
         }
         func toggle() async { isRecording ? await stopAndImport() : await start() }
         func start() async {
             let app = NSWorkspace.shared.frontmostApplication?.localizedName
             sourceLabel = app.map { "會議 · \($0)" } ?? "會議"
             do { try await service.start(micEnabled: RecorderConfigStore.shared.meetingMicEnabled) }
             catch {
                 NotificationManager.shared.showNotification(
                     title: "無法開始會議錄製（可能未授權系統音訊）", type: .error, duration: 8,
                     actionButton: ("開啟設定", Self.openAudioCapturePrivacySettings))
                 return
             }
             isRecording = true; startTimer(); indicatorShow()
         }
         func stopAndImport() async {
             guard isRecording else { return }
             timer?.invalidate(); indicator?.hide(); isRecording = false
             guard let url = await service.stop() else { return }
             RecorderImportService.shared.importMeetingFile(url, sourceLabel: sourceLabel)
         }
         // startTimer(): 1s Timer 更新 elapsedText（mm:ss / h:mm:ss）
     }
     ```
  2. `MeetingIndicatorView.swift`：紅點（`Circle().fill(.red)` + 呼吸動畫）＋ `Text(controller.elapsedText).monospacedDigit()` ＋停止鈕 → `controller.stopAndImport()`；`MeetingIndicatorWindowManager` 鏡射 WINDOW_MANAGER（panel 樣式抄 `MiniRecorderPanel` 的 non-activating/floating 設定，尺寸 ~180×44，右上角定位）。
  3. `MenuBarView.swift` `completedOnboardingMenu`（`:43` 附近，鏡射既有 Button）:
     ```swift
     Button(meetingController.isRecording
            ? "停止會議錄製（\(meetingController.elapsedText)）" : "開始會議錄製") {
         Task { await MeetingCaptureController.shared.toggle() }
     }
     ```
     （`@ObservedObject private var meetingController = MeetingCaptureController.shared` 於 view 頂部。）
- **GOTCHA**: 指示器 panel 不可搶焦點（non-activating）——會議中使用者正在打字；停止鈕要 `.buttonStyle(.plain)` 避免 focus ring。
- **VALIDATE**: 手動：選單列開錄 → 指示器出現且計時走 → 從指示器停止 → 通知＋幾分鐘後 Obsidian 出筆記；quit app 途中錄製 → 檔案仍完成匯入（下次啟動佇列處理）。
- **COMMIT**: `feat(meeting): capture controller, floating indicator, menu bar item`

### Task 7: 全域快捷鍵 `.toggleMeetingRecording`
- **ACTION**: 四件套註冊＋處理 case。
- **TEST FIRST**（enum 完整性小測試）:
  ```swift
  final class MeetingShortcutTests: XCTestCase {
      func testToggleMeetingIsGlobalUtility() {
          XCTAssertTrue(ShortcutAction.globalUtilityActions.contains(.toggleMeetingRecording))
          XCTAssertEqual(ShortcutAction.toggleMeetingRecording.storageName, "toggleMeetingRecording")
      }
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**（鏡射 SHORTCUT_ACTION）: `ShortcutAction.swift` 加 case `toggleMeetingRecording`、`storageName` `"toggleMeetingRecording"`、`displayName` `String(localized: "Toggle Meeting Recording")`、`globalUtilityActions` 尾端加入；`RecordingShortcutManager.handleGlobalShortcut`（`:314`）加：
  ```swift
  case .toggleMeetingRecording:
      await MeetingCaptureController.shared.toggle()
  ```
- **GOTCHA**: utility action 走 keyUp、不受 `canHandleShortcutAction` 的聽寫狀態 gate（`:92-96` 只 gate 錄音類）→ 聽寫進行中也能啟停會議錄製，符合 SRS。Settings 快捷鍵頁列舉 `globalUtilityActions` → 自動出現（實作時確認）。
- **VALIDATE**: 測試 PASS；手動設一組快捷鍵，於任意 app 前景按下可啟停。
- **COMMIT**: `feat(meeting): global toggle shortcut`

### Task 8: 設定 UI（RecorderModeSettingsView 新 Section）
- **ACTION**: 「會議錄製」Section：固定分類 Picker（含「自動分類」）＋收麥克風 Toggle＋說明文案。
- **TEST FIRST**: N/A（純 SwiftUI 宣告）——VALIDATE 手動。
- **IMPLEMENT**（鏡射 SETTINGS_SECTION，插在「分析」Section 之後）:
  ```swift
  Section("會議錄製") {
      Picker("固定分類", selection: meetingCategoryBinding) {   // Binding<UUID?>
          Text("自動分類").tag(UUID?.none)
          ForEach(store.categories) { c in Text(c.name).tag(UUID?.some(c.id)) }
      }
      Text("會議錄音預設直接歸入所選分類（跳過 AI 分類、結果穩定）；選「自動分類」則與錄音筆相同流程。")
          .font(.caption).foregroundStyle(.secondary)
      Toggle(isOn: meetingMicBinding) {
          HStack(spacing: 4) {
              Text("同時收錄麥克風")
              InfoTip("關閉後只錄系統音訊（對方聲音）。用喇叭開會時麥克風會收到迴音，建議戴耳機。")
          }
      }
      Text("匯出行為沿用上方「自動匯出」開關：開＝會後直接出 Obsidian 筆記；關＝留在 Recording Management 手動套用。")
          .font(.caption).foregroundStyle(.secondary)
  }
  ```
  Bindings 比照檔內既有 `convertTraditionalBinding` 寫法（get store 值 / set 呼叫 setter）。
- **VALIDATE**: 建置綠；設定頁顯示、選擇持久化（重啟 app 仍在）。
- **COMMIT**: `feat(meeting): settings section for fixed category + mic toggle`

### Task 9: Info.plist 權限字串＋拒絕引導
- **ACTION**: `NSAudioCaptureUsageDescription`；拒絕/失敗時的引導通知已在 Task 5/6 實作——此任務補 plist＋驗證全流程。
- **TEST FIRST**: N/A（plist）。
- **IMPLEMENT**: `Info.plist`（`:21-22` `NSScreenCaptureUsageDescription` 之後，鏡射同格式）:
  ```xml
  <key>NSAudioCaptureUsageDescription</key>
  <string>VoiceInk 需要錄製系統音訊，才能在會議模式中錄下線上會議雙方的聲音並轉成筆記。</string>
  ```
- **GOTCHA**: 提示只對正確簽名的 build 出現 → 用 `make deploy` 版驗證；`tccutil reset SystemAudioCaptureRequests com.prakashjoshipax.VoiceInk` 可重測首次授權。
- **VALIDATE**: 手動 AC-2：拒絕授權 → 3 秒內錯誤通知＋開設定按鈕，狀態回 idle。
- **COMMIT**: `feat(meeting): system-audio capture usage description + denial guidance`

### Task 10（OPTIONAL，可延後）: 會議 app 偵測提醒（SRS FR-8 / Should）
- **ACTION**: 前景 app ∈ {us.zoom.xos, com.microsoft.teams2} 或瀏覽器 URL 含 meet.google.com（`BrowserURLService` 既有）＋未在錄 → 每 app-session 提醒一次「要開始錄會議嗎？」通知（action 直接開錄）。
- **TEST FIRST**: bundle-id 判斷純函式測試（`MeetingAppDetector.isMeetingContext(bundleId:url:)`）。
- **IMPLEMENT**: 掛在既有 `ActiveWindowService` 的前景變化通知上；去重 set 以 bundleId＋當日為 key。
- **VALIDATE**: 手動開 Zoom → 收到一次提醒；重複切換不重複提醒。
- **COMMIT**: `feat(meeting): optional meeting-app reminder`

### Task 11: 收尾——build 號、文件、部署、Linear 驗證 issue
- **ACTION**:
  1. `project.pbxproj` `CURRENT_PROJECT_VERSION` +1（**兩處 configuration 都要**；回報 build 號給使用者——Settings → About 可核對）。
  2. `docs/spec/recorder-automation.spec.md` Change History 加一行「Meeting capture implemented (build N)」＋ 本 plan 移到 `docs/plans/completed/`（由 /prp-implement 收尾流程處理）。
  3. `make deploy`（絕不 build 進 /tmp——ghost icon 鐵律）。
  4. 在 Linear voiceink 專案開**手動驗證 issue**：標題含功能名＋build 號；內容=「做了什麼」＋下方 Manual Validation 清單逐條轉為 checkbox。
- **VALIDATE**: Settings → About 顯示新 build 號；Linear issue 連結回報。
- **COMMIT**: `chore(meeting): bump build, docs, deploy`

---

## Testing Strategy

### Unit Tests
| Test | Input | Expected Output | Edge Case? |
|---|---|---|---|
| ConfigThreeStates | key 未設/""/uuid | 會議分類/nil/指定分類 | 三態 sentinel |
| MicEnabledDefault | 未設定 | true | object-presence |
| MeetingOriginRoundtrip | .meetingCapture(fp,label) | 取回一致 | — |
| StageMeetingFile | tmp m4a | fingerprint=真 SHA、staging 存在 | copy 失敗 throw |
| MixToMono | 3 聲道等長 | 等權平均 | 空輸入→[] |
| FrontmatterSourceLabel | sourceLabel 有值 | `來源:` 行存在 | nil→無該行 |
| ShortcutRegistration | — | 在 globalUtilityActions | — |

### Edge Cases Checklist
- [ ] TCC 拒絕（AC-2）
- [ ] 錄製中接上/拔掉 AirPods（AC-3：續錄或保檔通知，無長段零訊號）
- [ ] 錄製中 quit app（willTerminate 保檔，重啟後可手動匯入或已入佇列）
- [ ] `meetingMicEnabled=false`（AC-6：檔案只有系統音訊）
- [ ] 會議全程無聲（零 RMS 警告出現、檔案仍完成）
- [ ] 3 小時長會議（m4a ~135MB，不觸發 chunk；scribe_v2 單請求）
- [ ] 聽寫錄音進行中啟停會議錄製（互不干擾）
- [ ] 固定分類被使用者刪除（meetingFixedCategory 解析失敗 → 回 nil → 自動分類，不崩潰）

## Validation Commands

### Static / Build
```bash
make local
```
EXPECT: BUILD SUCCEEDED（.local-build，絕不 /tmp）

### Unit Tests（host-app 測試需 local 簽名設定，見記憶檔）
```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO -only-testing:VoiceInkTests
```
EXPECT: 全綠（新增 ~7 tests＋既有全部）

### Deploy（手動驗證前）
```bash
make deploy
```
EXPECT: /Applications/VoiceInk.app 更新；Settings → About 顯示新 build 號

### Manual Validation（→ Task 11 轉為 Linear 驗證 issue）
- [ ] 首次開錄跳系統音訊授權；允許後（必要時重啟 app）錄製正常
- [ ] AC-1：Zoom 播音＋自己說話 2 分鐘 → 停止 → 通知 → Obsidian/會議/ 出現筆記；逐字稿含雙方內容；講者分段存在；分類=會議；request log **無分類呼叫**
- [ ] AC-2：拒絕授權 → 錯誤通知＋開設定按鈕；狀態回 idle
- [ ] AC-3：錄製中切 AirPods → 錄音續行或保檔通知
- [ ] AC-5：快捷鍵與選單列一致；聽寫中可用；指示器計時正確
- [ ] AC-6：關麥克風 → 檔案只有對方聲音
- [ ] 標題/檔名時間＝開錄時間（非匯入時間）；來源 chip「會議 · Zoom」顯示；frontmatter `來源:` 存在

## Acceptance Criteria
- [ ] SRS AC-1〜AC-6 全數通過（上方清單映射）
- [ ] 所有 Validation Commands 通過、既有測試零回歸
- [ ] 匯出筆記與 Recording Management 行為與錄音筆來源一致（保留策略/orphan sweep 相容）

## Completion Checklist
- [ ] 程式碼與鏡射模式一致（設定鏈/origin 分支/視窗管理器/快捷鍵四件套）
- [ ] 通知/錯誤文案繁中、比照既有語氣
- [ ] 無硬編路徑；staging 目錄在 Application Support 下
- [ ] Key Decisions 未被違反（無 chunk 改動、無本地 diarizer、scribe_v2 不動）
- [ ] build 號已 bump 並回報；`make deploy` 完成；Linear 驗證 issue 已開

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| TCC 授權後需重啟才生效（Tahoe 未實證） | M | M | AC-2 首測即驗證；引導文案含「必要時重啟」 |
| 裝置切換重建失敗 → 錄音中斷 | M | M | 保檔 finalize＋通知（絕不無聲丟失）；AC-3 |
| 喇叭迴音讓 diarization 混亂 | M | L | 設定頁耳機提示；實測不佳再評估雙聲道 |
| Privacy pane deep-link anchor 不正確 | M | L | 實作時驗證；fallback 開 Privacy 根頁 |
| ExtAudioFile AAC 在 IOProc 節奏下寫入卡頓 | L | M | WriteAsync＋預熱；不行退回 CAF/PCM（檔案大 10 倍仍 << 2GB） |

## Notes
- 混音等權平均在「人聲 vs 系統」音量差大時可能偏小聲——v1 接受，之後可加 per-source gain（設定已預留位置）。
- Task 10 為 OPTIONAL：時間緊可直接跳過，不影響 AC。
- 實作全程遵守三份記憶檔鐵律：測試跑法、不建進 /tmp、回報 build 號。
