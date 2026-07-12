---
linear_issue: null
---
# SRS: meeting-copilot M4 — 隱蔽浮動 overlay + 熱鍵（Covert Overlay + Hotkeys）

> **本文件是 umbrella SRS `docs/srs/meeting-copilot-live-assist.srs.md` 的 M4 切片。**
> 只涵蓋 M4 里程碑（覆蓋層視窗 + 兩個熱鍵 + 順手修 `.toggleMeetingRecording` 缺陷）。
> M2（cue 偵測引擎）與 M3（三層回應 + SSE + grounding）為前置依賴：M4 只**呈現** M2/M3 已算好的
> `@Published` 狀態，不含 cue 抽取、不含 LLM 串流、不含 grounding。M5（管理頁 + 完整設定 UI）承接
> 兩熱鍵的 `ShortcutRecorder` row 與 overlay 設定項的 UI。

## Metadata
- **Module**: `meeting-copilot`（新模組；M1 音訊骨幹已 commit，build 248）
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source PRD**: N/A（承 umbrella SRS `meeting-copilot-live-assist.srs.md`）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-12
- **Grill level**: 1 (standard)
- **依賴**: M2（cue store + `MeetingCopilotController.@Published cues`）、M3（`AnswerCoordinator` 的三層狀態、
  local 流 RMS）。M4 讀取其狀態並呈現。
- **build number**: M4 → 251（bump `CURRENT_PROJECT_VERSION`，Debug + Release 兩處）。

## Feature Summary

把 M2/M3 已算好的 cue 與三層回應狀態，呈現在一個**盡力**不被螢幕分享擷取的浮動 overlay。overlay
以 `NSPanel` 為底（clone `MeetingIndicatorPanel`），`sharingType = .none` + `.screenSaver` level +
`canBecomeKey = false`（不搶焦點）+ `ignoresMouseEvents`（依設定切換）。視覺上 `opener` 以最大字級單獨
呈現、cue 清單最新最上最大舊的縮灰、三層漸進渲染、我說話時淡出至 `speakingOpacity`，並在頂部常駐一條
**螢幕分享邊界警告條**。

兩個新全域熱鍵：`.toggleMeetingCopilotOverlay`（釘住/toggle）與 `.peekMeetingCopilotOverlay`（**按住顯示、
放開隱藏**，走 push-to-talk 的 keyDown/keyUp 機制）。同時順手修既有缺陷：`.toggleMeetingRecording`
自 build 227 加入後**從未進入衝突偵測清單**（本 milestone 補資料層；其 `ShortcutRecorder` UI row 屬 M5）。

> 🔴 **誠實約束（核心風險，不得軟化）**：`sharingType = .none` 在 **macOS 15.4+ 被 ScreenCaptureKit 忽略**。
> Apple DTS 明言目前沒有公開 API 可防螢幕擷取；Chrome / Google Meet 的 `getDisplayMedia` 走 SCK。
> **分享整個螢幕時 overlay 會被錄到。** 安全模式是分享**單一視窗/分頁**。仍設 `sharingType = .none`
> （防 legacy 擷取路徑、Zoom 的視窗過濾、以及所有 per-window/tab 分享），但 **UI 與文件不得宣稱無條件隱形**。
> 見「Architecture Notes › 螢幕分享隱蔽性的真實邊界」與 Risks。（來源：Apple Developer Forums thread 792152
> + tauri #14200，2026-07 查證；memory: voiceink-sharingtype-sck-limitation。）

---

## Delta from Current Module State

> M4 對既有程式碼的侵入面集中在**熱鍵系統 5 處**與**新增 overlay 元件**。overlay 元件全為新增，
> 只**唯讀取用** M2/M3 已存在的 `@Published` 狀態與 M1 的 local-stream RMS，不改其實作。

### New Data Models

無。M4 不新增任何 SwiftData `@Model`。overlay 呈現的狀態全部來自 M2 的 `MeetingLiveCue`
（cue 文字、kind、status）與 M3 的三層欄位（`tier0Keywords` / `tier1Opener` / `tier1BulletsRaw` /
`tier2Analysis` / `tier2FollowUpsRaw` / `tier2UncertaintiesRaw`，見 umbrella SRS Data Models）。

### New Settings（擴充 `MeetingCopilotConfigStore`，UserDefaults，`…V1` key 後綴）

以下三項 overlay 行為設定在 M4 由 config store 提供資料層（`@Published private(set)` + `set…()` mutator
+ `load()`，鏡射 M1 既有慣例）；其設定頁 UI row 屬 M5。

| 設定 | 預設 | 說明 |
|---|---|---|
| `overlayClickThrough` | false | 點擊穿透。決定 `panel.ignoresMouseEvents`。 |
| `speakingOpacity` | 0.35 | 我說話時 overlay 的不透明度。 |
| `maxCuesShown` | 5 | overlay 列出最近幾則 cue。 |

### Changed Business Logic — 熱鍵系統（5 處，跨 3 檔）

新增兩個 `ShortcutAction` case，並修 `.toggleMeetingRecording` 的衝突偵測缺陷：

| 檔案:位置 | 改動 | 為何非改不可 |
|---|---|---|
| `ShortcutAction.swift:3-20`（enum） | 新增 `case toggleMeetingCopilotOverlay` + `case peekMeetingCopilotOverlay`。 | 兩個新熱鍵動作。 |
| `ShortcutAction.swift:34-61`（`storageName`，**exhaustive，無 default**） | 為兩新 case 各加 arm（`"toggleMeetingCopilotOverlay"` / `"peekMeetingCopilotOverlay"`）。 | 漏 arm 直接 **compile error**（好）。 |
| `ShortcutAction.swift:63-98`（`displayName`，**exhaustive，無 default**） | 為兩新 case 各加 `String(localized:)` arm。 | 同上，漏 arm compile error。 |
| `ShortcutAction.swift:100-107`（`globalUtilityActions`） | append 兩新 case。 | `refreshShortcutMonitor` 只監看 `ShortcutStore.shortcuts(for: globalUtilityActions)`；不加則事件 tap 永遠看不到這兩鍵（`RecordingShortcutManager.swift:198`）。 |
| `ShortcutAction.swift:113-122`（`legacyKeyboardShortcutActions`） | append **`.toggleMeetingRecording` + 兩新 case**。 | `ShortcutValidator.allStoredActions` 由此建（`ShortcutValidator.swift:436-442`）；不加則三者的鍵**逃過衝突偵測**。這正是 FR-32 的資料層修復。加入安全：其 `legacyKeyboardShortcutsNames` 回 `[]`，migration no-op。 |
| `ShortcutMigration.swift:251-275`（`legacyKeyboardShortcutsNames`，**exhaustive，無 default**） | 把兩新 case 併入既有 `case .recorderPanelEscape, .recorderPanelMode, .toggleMeetingRecording: return []` 那一 arm。 | 漏則 **compile error**。兩新動作無 legacy KeyboardShortcuts 鍵。 |
| `RecordingShortcutManager.swift:212-246`（`refreshShortcutMonitor` 的 `onKeyDown`/`onKeyUp` 閉包） | `onKeyDown` 加**顯式 branch**：`toggleMeetingCopilotOverlay` → 無動作（toggle 走 keyUp）；`peekMeetingCopilotOverlay` → overlay show。`onKeyUp` else-path：toggle → overlay toggle；peek → overlay hide。 | keyDown 對 `recordingMode(for:)==nil` 的 action 被 `guard` 丟棄（`:216`）；peek 要在按下時顯示，必須加顯式 keyDown branch，**不能**靠既有 swallow。 |
| `RecordingShortcutManager.swift:314-366`（`handleGlobalShortcut`，有 `default: break`） | 加 `case .toggleMeetingCopilotOverlay:` → 呼叫 overlay window manager 的 toggle（keyUp-only 分派）。peek 的 hide 也可落在此處的 else-path。 | 沿用 `.toggleMeetingRecording:` 同款 keyUp-only 全域動作樣式（`:360-362`）。有 default，不加不會 compile error，但功能不通。 |

> **陷阱（recon-hotkeys.md:562-563）**：**不得**把 peek action 加進 `recordingMode(for:)`（`:248-257`）使其回傳非 nil。
> 那會把 keyDown+keyUp 都路由進 `RecordingShortcutModeHandler`，該 handler 驅動的是**迷你錄音面板的
> push-to-talk（聽寫）**，不是會議 overlay——目標錯誤。M4 的正解是在 `refreshShortcutMonitor` 的
> 閉包內直接對 overlay window manager 做 show/hide，並自行複製 push-to-talk 的兩個守衛
> （`isShortcutPressed` 擋 key-repeat auto-fire、0.5s `shortcutPressCooldown`，見 `RecordingShortcutManager.swift:266-334`），
> 因為按住一鍵會連發 keyDown。

### New / Changed API — 新增 overlay 元件（全為新增檔）

| 新元件 | clone 基底 / 依據 | 純新增能力 |
|---|---|---|
| `CopilotOverlayPanel`（`Views/MeetingCopilot/CopilotOverlayPanel.swift`，new） | clone `MeetingIndicatorPanel`（`Views/Meeting/MeetingIndicatorView.swift:39-60`）——已具 `.nonactivatingPanel` + `canBecomeKey == false` + `.canJoinAllSpaces` + 透明。 | `sharingType = .none`（全 repo 首次 Swift 使用）；`ignoresMouseEvents`（首次使用，依 `overlayClickThrough`）；`level = .screenSaver`（既有最高 `NotchRecorderPanel` 的 `.statusBar + 3` = 28，`.screenSaver` = 1000）；`collectionBehavior` 採 NotchRecorder 集合 `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`（`NotchRecorderPanel.swift:110`）；`isMovable = false` + `isMovableByWindowBackground = false`（防 peek 時被拖離近鏡頭錨點）。 |
| `CopilotOverlayView`（`Views/MeetingCopilot/CopilotOverlayView.swift`，new） | 新 SwiftUI view，繁中字面（不進 xcstrings）。 | `opener` 最大字級單獨呈現；cue 清單最新最上最大、舊的縮單行變灰、已回答下沉變灰；三層漸進渲染（Tier 0 關鍵字 → Tier 1 opener+bullets → Tier 2 analysis+followUps+uncertainties）；我說話時整體不透明度降至 `speakingOpacity`；頂部常駐**螢幕分享邊界警告條**。 |
| `CopilotOverlayWindowManager`（`Views/MeetingCopilot/CopilotOverlayWindowManager.swift`，new） | clone `MeetingIndicatorWindowManager`（`Views/Meeting/MeetingIndicatorView.swift:62-101`）的 show/hide/retain 生命週期 + `NSHostingController` 接法；定位改採 `NotchRecorderPanel.show()`（`NotchRecorderPanel.swift:135-147`）每次 show 都重算 + `setFrame`。 | `show()` / `hide()` / `peek`；`calculateWindowMetrics()` 錨定**螢幕上方中央**（近鏡頭），優先取會議 app 所在螢幕、退回 `NSScreen.main`；訂閱 `NSApplication.didChangeScreenParametersNotification`（0.1s debounce，`NotchRecorderPanel.swift:141-147`）重算位置。 |

### Explicitly Out of Scope（M4 不做）

- **cue 抽取、四分類、去重**（M2）；**三層 LLM 串流、SSE、grounding、預跑**（M3）。M4 只呈現其結果。
- **兩熱鍵的 `ShortcutRecorder` 設定 row 與 overlay 設定項（`overlayClickThrough` / `speakingOpacity`
  / `maxCuesShown`）的設定頁 UI**——屬 M5（`MeetingCopilotSettingsView` + `SettingsView`）。M4 只補
  `.toggleMeetingRecording` 進**衝突偵測資料層**（`legacyKeyboardShortcutActions`），其 UI row 亦屬 M5。
- **多螢幕「跟隨會議視窗移動到另一台顯示器」的即時追蹤**。repo 現無此邏輯（recon-windows.md:462）；
  M4 只在 `didChangeScreenParametersNotification`（插拔/解析度變更）時重算，不追 app focus 換螢幕。
  進 Open Questions。
- **`ScreenCaptureService` OCR 接地**（M3 用途）與 overlay 無關，不在此。
- 明確不動：`MeetingIndicatorPanel` 本身、`MiniRecorderPanel` / `NotchRecorderPanel`、聽寫 push-to-talk
  的 `RecordingShortcutModeHandler` 路徑。

---

## Functional Requirements（僅 M4）

### Overlay 視窗
- [ ] **FR-21** 兩個熱鍵：`.toggleMeetingCopilotOverlay`（釘住/toggle）與 `.peekMeetingCopilotOverlay`
  （**按住顯示、放開隱藏**，沿用 push-to-talk 的 keyDown/keyUp 機制 `RecordingShortcutManager.swift:266-334`）。
- [ ] **FR-22** overlay `sharingType = .none`——盡力使螢幕分享（legacy 擷取、Zoom 視窗過濾、per-window/tab
  分享）擷取不到本視窗，且不出現在分享視窗選擇器。**⚠️ 於 macOS 15.4+ 分享整個螢幕時此保證失效**（見
  FR 下方註記與 Risks）。
- [ ] **FR-23** overlay 可點擊穿透（`overlayClickThrough` 切換 `ignoresMouseEvents`），且 `canBecomeKey = false`
  → **永不**從會議 app 搶走鍵盤焦點；不套用 `DictionaryQuickAddPanel` 的 focus save/restore（那會在 hide 時
  `activate()` 把焦點從 Teams 搶走，recon-windows.md:230）。
- [ ] **FR-24** overlay 錨定**螢幕上方中央**（近鏡頭）；優先取會議 app 所在螢幕，退回 `NSScreen.main`；
  `show()` 每次都重算 `calculateWindowMetrics()` + `setFrame`（**不得**繼承 `MeetingIndicatorWindowManager`
  的 frozen-frame bug，recon-windows.md:464）。
- [ ] **FR-25** local 流（我的麥克風）RMS 超過門檻 → overlay 不透明度降至 `speakingOpacity`（預設 0.35）；
  停止說話 1.5 秒後恢復。RMS 直接取自 M1 的 ring buffer，零額外成本。
- [ ] **FR-26** `opener` 以最大字級單獨呈現（唯一必讀項）；最新 cue 永遠在最上方且最大，較舊 cue 縮為
  單行並變灰，已回答的 cue 下沉變灰；最多顯示 `maxCuesShown` 則；三層漸進渲染。

> **FR-22 誠實註記（必寫入 overlay UI 的警告條與 M5 設定頁）**：`sharingType = .none` 在
> macOS 15.4+ 被 ScreenCaptureKit 忽略。**分享整個螢幕會被錄到；安全模式是分享單一視窗/分頁。**
> overlay 頂部常駐一條警告條明示此邊界，不得宣稱無條件隱形。

### 既有缺陷修復
- [ ] **FR-32** 補上 `.toggleMeetingRecording` 的衝突偵測資料層：加入 `legacyKeyboardShortcutActions`
  （`ShortcutAction.swift:113-122`），使 `ShortcutValidator.allStoredActions`（`ShortcutValidator.swift:436-442`）
  納入其鍵做重複偵測。兩個新熱鍵動作同時加入。（其 `ShortcutRecorder` UI row 屬 M5。）

---

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 隱蔽性（盡力，非保證） | 分享**單一視窗/分頁**時 overlay 不被擷取 | `sharingType = .none` + `getDisplayMedia` 選擇器排除 |
| 隱蔽性（誠實邊界） | 分享**整個螢幕**時明示會被錄到 | overlay 常駐警告條 + M5 設定頁明示；**不宣稱無條件隱形** |
| 不搶焦點 | 熱鍵召喚 overlay 全程 Teams 仍為前景 | `canBecomeKey = false` + `orderFrontRegardless()`（非 `makeKeyAndOrderFront`） |
| 視窗層級 | 浮於所有既有 panel 之上 | `.screenSaver`（1000）> 既有最高 `.statusBar + 3`（28，`NotchRecorderPanel.swift:24`） |
| 定位正確性 | 每次 show 都落在會議螢幕上方中央 | `show()` 重算 + `setFrame`（避 frozen-frame bug）；`didChangeScreenParametersNotification` 0.1s debounce 重算 |
| 熱鍵可靠性 | 按住 peek 不因 key-repeat 連觸 | 複製 `isShortcutPressed` + 0.5s `shortcutPressCooldown` 守衛 |
| 衝突偵測完整性 | 三個會議熱鍵皆參與重複偵測 | 三者入 `legacyKeyboardShortcutActions` → `allStoredActions` |
| 失敗隱蔽性 | overlay 相關失敗不產生可見系統 UI | 不用 `NotificationManager`（有聲、搶焦點、無 `sharingType`，會被廣播，recon-windows.md:472）；log-only |

---

## Architecture Notes

### 螢幕分享隱蔽性的真實邊界（🔴 不可省略）

`sharingType` 與 `ignoresMouseEvents` 在**全 repo 從未於 Swift 使用過**（recon-windows.md:456-458，
所有既有 hit 都在 docs）。M4 是首次 Swift 使用，因此**沒有 in-repo 先例可驗證** `.none` 在三條擷取
路徑上都成立。真實情況（canon §3 第 1 點）：

- `sharingType = .none` 是**正規 macOS API**（密碼管理器用它避免自身視窗被錄進畫面），仍值得設——
  它擋 legacy 擷取路徑、Zoom 的視窗過濾、以及所有 per-window/tab 分享。
- **但 macOS 15.4+ 的 ScreenCaptureKit 忽略此旗標**。Chrome / Google Meet 的 `getDisplayMedia`
  分享**整個螢幕**走 SCK → overlay **會被錄到**。Apple DTS 明言目前無公開 API 可防螢幕擷取。
- 因此**安全模式是分享單一視窗/分頁**。overlay 頂部**常駐一條警告條**明示此邊界；M5 設定頁亦明示。
  **絕不宣稱無條件隱形。** 這道實機驗證（三情境）由 AC-15 以人工 gate 把關（本 milestone 只寫進 plan
  的手動驗證步驟，非自動化測試）。

### Overlay panel 組裝（clone base + 純新增）

clone base 是 `MeetingIndicatorPanel`（`Views/Meeting/MeetingIndicatorView.swift:39-60`），已具
`.nonactivatingPanel` + `canBecomeKey/canBecomeMain == false` + `.canJoinAllSpaces` + 透明。M4 在其上：

- **視窗層級**：`level = .screenSaver`。census（recon-windows.md:474）：`.normal`(0) / `.floating`(3) /
  `.mainMenu`(24) / `.statusBar`(25) / `.statusBar+3`(28，現最高) → `.screenSaver`(1000) 全清。
  **副作用**：亦蓋過 notch recorder pill——若使用者在 overlay 顯示時聽寫，overlay 會蓋住 notch。
  取捨（是否改用 `.statusBar + 4` 為天花板）進 Open Questions。
- **collectionBehavior**：採 `NotchRecorderPanel` 集合 `[.canJoinAllSpaces, .fullScreenAuxiliary,
  .stationary, .ignoresCycle]`（`NotchRecorderPanel.swift:110`）。`.fullScreenAuxiliary` 讓 overlay 能浮在
  全螢幕 Teams/Meet 之上（**必要**）；`.stationary` 於 Mission Control 不移動；`.ignoresCycle` 不進 Cmd+`。
- **isMovable = false + isMovableByWindowBackground = false**：clone base 兩者皆 true
  （`MeetingIndicatorView.swift:56-57`），若照抄，peek 時 `ignoresMouseEvents=false` 使用者會把 overlay
  拖離近鏡頭錨點（recon-windows.md:458）。M4 明確設 false。
- **不套 focus save/restore**：`DictionaryQuickAddPanel`（`DictionaryQuickAddPanel.swift:22-52`）存/還原
  `previousApp` 只因它 `canBecomeKey=true` + `makeKeyAndOrderFront` 真的搶焦點。M4 走
  `canBecomeKey=false` + `orderFrontRegardless()` 從不搶焦點，該路徑照抄會是 dead code，且 hide 時的
  `activate()` 會把焦點從 Teams 搶走（recon-windows.md:230）。

### 定位與多螢幕

repo 內**所有** panel 一律硬寫 `NSScreen.main`（recon-windows.md:460），無跟隨邏輯。M4 的
`calculateWindowMetrics()` 錨定螢幕上方中央（近鏡頭；理由見 umbrella SRS：讀 overlay 時視線接近鏡頭），
優先取會議 app 所在螢幕、退回 `NSScreen.main`。多螢幕反應性唯一先例是 `NotchRecorderPanel` 訂閱
`NSApplication.didChangeScreenParametersNotification`（`NotchRecorderPanel.swift:141-147`，**0.1s
asyncAfter debounce**——AppKit 同步讀 NSScreen 幾何會拿到 stale 值）。M4 逐字沿用此 pattern。
**注意**：它只在顯示器插拔/解析度變更時觸發，**不**追使用者把會議視窗移到另一台既有顯示器——那需從零寫，
不在 M4（Open Questions）。同時**不得**繼承 `MeetingIndicatorWindowManager` 的 frozen-frame bug
（`calculateWindowMetrics()` 只在 `initializeWindow()` 呼叫一次，show 只 `orderFrontRegardless`，
recon-windows.md:464）；M4 的 `show()` 每次重算 + `setFrame`，比照 `NotchRecorderPanel.show()`
（`NotchRecorderPanel.swift:135-139`）。

### 熱鍵：toggle 與 press-and-hold peek

CGEvent tap（`ShortcutMonitor`）**對每個註冊 shortcut 一律同時發 keyDown 與 keyUp**
（`ShortcutMonitor.swift:160-174` 的 `transitionForKeyShortcut`）；「keyUp-only」是
`RecordingShortcutManager.refreshShortcutMonitor` 的 `onKeyDown` 閉包用
`guard let mode = recordingMode(for: action) else { return }`（`RecordingShortcutManager.swift:216`）**丟掉**
globalUtilityActions 的 keyDown 造成的。因此：

- **toggle**（`.toggleMeetingCopilotOverlay`）：純 keyUp-only 全域動作，樣式完全比照既有
  `.toggleMeetingRecording`——在 `handleGlobalShortcut`（`RecordingShortcutManager.swift:314-366`）加一
  `case` 呼叫 overlay window manager toggle。
- **peek**（`.peekMeetingCopilotOverlay`）：要在**按下時顯示、放開時隱藏**。show-on-press 必須在
  `onKeyDown` 閉包加**顯式 branch**（`recordingMode` 仍回 nil，故不能靠既有 swallow）；hide-on-release
  走 `onKeyUp` else-path。press-and-hold 的語意先例是
  `RecordingShortcutModeHandler.handleKeyDown/handleKeyUp` 的 `.pushToTalk`
  （`RecordingShortcutManager.swift:266-331`：keyDown show、keyUp hide），但其 show/hide 閉包綁死迷你錄音面板，
  **不能**指向會議 overlay。M4 在監看閉包內**手搓** show/hide 對 `CopilotOverlayWindowManager`，並複製其
  兩個守衛（`isShortcutPressed` 擋 key-repeat、0.5s `shortcutPressCooldown`）。

### 熱鍵：兩個 exhaustive switch + 衝突偵測

新增 case 會使兩個**無 default** 的 switch compile error（好，強制處理）：`ShortcutAction.storageName`
（`ShortcutAction.swift:34`）、`ShortcutAction.displayName`（`:63`）、以及
`ShortcutMigration.legacyKeyboardShortcutsNames`（`ShortcutMigration.swift:251`）。其餘（`isStored`、
`recordingMode(for:)`、`handleGlobalShortcut`、`ShortcutValidator`）皆有 default，不加 arm 也 compile，
但功能不通。衝突偵測缺陷根因（recon-hotkeys.md:445）：`allStoredActions = legacyKeyboardShortcutActions
+ modes`，而 `.toggleMeetingRecording` 只在 `globalUtilityActions`、不在 `legacyKeyboardShortcutActions`
→ 其鍵對衝突偵測**雙向隱形**。修法：把 `.toggleMeetingRecording` + 兩新 case 一併加入
`legacyKeyboardShortcutActions`（安全：其 `legacyKeyboardShortcutsNames` 回 `[]`，`migrateLegacyKeyboardShortcut` no-op）。

### 失敗必須靜默（承 umbrella 可靠性契約）

overlay 相關失敗**不得**用 `NotificationManager.showNotification`（recon-windows.md:472）：它 (1) 是
無 `sharingType` 的可見 NSPanel → 分享螢幕時「錯誤 toast」被廣播；(2) `.error` 呼 `playEscSound()` →
會議中發出可聞聲；(3) `makeKeyAndOrderFront` 搶焦點。三者皆對會議 copilot 失格。M4 一律 log-only。

---

## Acceptance Criteria

> AC-16、AC-17 為 M4 自動化（含人工輔證）；AC-15（螢幕分享排除三情境）為**人工 gate**，
> 只能實機驗證，寫進本 milestone plan 的手動驗證步驟，非自動化測試。

### AC-16: Overlay 不搶焦點 + Peek 模式
- **Given**: Teams 為前景、游標在其輸入框，overlay 隱藏
- **When**: **按住** `.peekMeetingCopilotOverlay` 熱鍵，然後放開
- **Then**: 按住期間 overlay 顯示、放開即隱藏；全程 Teams 仍為前景 app，鍵盤焦點未轉移；
  key-repeat 不造成重複 show（`isShortcutPressed` 守衛生效）
- **Test**: `CopilotOverlayPanelTests::canBecomeKeyIsFalse`（斷言 `panel.canBecomeKey == false` 且
  `panel.canBecomeMain == false`）+ 人工驗證按住/放開與焦點

### AC-17: 我說話時自動淡出
- **Given**: overlay 顯示中，`speakingOpacity = 0.35`
- **When**: local 流 RMS 超過門檻（我在說話），隨後停止
- **Then**: 不透明度降至 0.35；停止說話 1.5 秒後恢復為 1.0
- **Test**: `OverlayDimmingTests::dimsWhileLocalStreamActive`（以合成 RMS 序列驅動，斷言不透明度轉換與
  1.5s 恢復）

### AC-15: Overlay 不被螢幕分享擷取（實機，人工 gate — 非自動化）
- **Given**: overlay 顯示中
- **When**: (a) Teams 原生 app 分享整個螢幕；(b) Chrome/Meet `getDisplayMedia` 分享整個螢幕；
  (c) Chrome/Meet 分享單一視窗
- **Then**: 情境 (c)（單一視窗/分頁）接收端畫面**不含** overlay，且 overlay **不出現在**分享視窗選擇器；
  情境 (a)(b)（分享整個螢幕，macOS 15.4+）**預期 overlay 會被錄到** → 此為已知邊界，overlay 警告條與
  M5 設定頁已明示，**不視為 bug**；驗證重點是警告條確實呈現且文案誠實
- **Test**: 人工驗證（實機，需第二台裝置或錄製接收端畫面存證）。寫進 plan 的手動驗證步驟。

### AC-19（部分，衝突偵測資料層）: 會議熱鍵納入衝突偵測
- **Given**: `.toggleMeetingRecording` 已設一鍵
- **When**: 嘗試把同一鍵指派給另一動作（或反向）
- **Then**: `ShortcutValidator.validationError` 回 `.alreadyUsedBy`；三個會議熱鍵
  （`.toggleMeetingRecording` / `.toggleMeetingCopilotOverlay` / `.peekMeetingCopilotOverlay`）皆在
  `allStoredActions` 內參與偵測
- **Test**: `MeetingShortcutTests::meetingShortcutsParticipateInConflictDetection`
  （斷言三者皆在 `ShortcutValidator.allStoredActions`，且衝突鍵被拒）
  > 註：AC-19 的 `ShortcutRecorder` UI row 由 M5 補齊；M4 只交付資料層（FR-32）。

---

## Open Questions

- [ ] **視窗層級天花板**：`.screenSaver`(1000) 會蓋過 notch recorder pill——使用者在 overlay 顯示時聽寫，
  overlay 會蓋住 notch。是否改用 `.statusBar + 4`（29）為天花板以讓出 notch？（recon-windows.md:474）
- [ ] **多螢幕追蹤**：使用者把會議視窗移到**另一台既有顯示器**時，overlay 是否要跟隨？repo 現無此邏輯
  （`didChangeScreenParametersNotification` 只在插拔/解析度變更觸發，不追 app focus 換螢幕，
  recon-windows.md:462）。若要，需在 `NSWorkspace.didActivateApplicationNotification` 或輪詢上新寫。
- [ ] **peek 綁 modifier-only 鍵**（如 Right-Cmd）也支援按住（`handleModifierOnlyShortcut` 走 flagsChanged
  release，recon-hotkeys.md:577），但這類 peek 不 interruptible（`interruptibleActions` 只含 primary/secondary）——
  是否需要？傾向：不需要，peek 本就非錄音動作。
- [ ] **Input Monitoring 權限**：`warnIfGlobalShortcutInputBlocked` 只在有 recording（primary/secondary）
  shortcut 時才提示（recon-hotkeys.md:575）。只用會議熱鍵、無聽寫熱鍵的使用者，tap 可能靜默未安裝 →
  兩個新熱鍵不觸發。是否需為會議熱鍵獨立補一次權限提示？
- [ ] `speakingOpacity` 淡出的 RMS 門檻在**喇叭情境**（不戴耳機）下會被對方聲音經 mic 誤觸發（umbrella SRS
  Risks 已列）——M4 只呈現；門檻與 remote-能量互斥閘門的最終值待 M2/M3 實機調校。
