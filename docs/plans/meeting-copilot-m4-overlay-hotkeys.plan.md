---
linear_issue: null
---
# Plan: Meeting Copilot M4 — 隱蔽浮動 overlay + 熱鍵（Covert Overlay + Hotkeys）

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type`。**Mode B（任務先測）**：每個 task 先寫一個鎖行為的測試 → 實作 → 通過 → commit。**Rigor: strict** — 測試 gate 全強制（overlay 直接暴露在會議對方眼前的風險 + 熱鍵系統是全 app 共用路徑）。
>
> **⚠️ 前置依賴：M2 與 M3 必須已實作並 commit。** M4 只**呈現** M2 的 `MeetingCopilotController.@Published cues` 與 M3 回寫在 `MeetingLiveCue` 上的 tier 欄位，不重做任何偵測 / LLM 邏輯。開工前先讀 M2 / M3 的實作 report（`docs/reports/`），確認實際落地的型別面（特別是 `MeetingCopilotController` 的建構點與 `MeetingLiveCue` 的 tier 欄位型別），與本 plan 引用處對齊。
>
> **🔴 誠實約束（本 milestone 的核心風險，不得軟化）**：`sharingType = .none` 在 **macOS 15.4+ 被 ScreenCaptureKit 忽略**。分享**整個螢幕**時 overlay **會被錄到**；安全模式是分享**單一視窗/分頁**。overlay 必須常駐警告條明示此邊界，**不得宣稱無條件隱形**。（canon §3 第 1 點；memory `voiceink-sharingtype-sck-limitation`；Apple Developer Forums thread 792152 + tauri #14200，2026-07 查證。）
>
> **Checkbox states:** `- [ ]` todo · `- [~]` in-progress · `- [x]` done。`[~]` 不是完成。

## Summary

把 M2/M3 已算好的狀態（cue 清單 + 三層回應）呈現在一個**盡力**不被螢幕分享擷取的浮動 overlay：`CopilotOverlayPanel`（clone `MeetingIndicatorPanel` + `sharingType = .none` + `.screenSaver` level + `canBecomeKey = false` 永不搶焦點 + `ignoresMouseEvents` 依設定切換）、`CopilotOverlayView`（opener 最大字級、cue 最新最上最大、三層漸進渲染、頂部常駐螢幕分享邊界警告條）、`CopilotOverlayWindowManager`（show/hide/peek，錨定螢幕上方中央＝近鏡頭，優先會議 app 所在螢幕退回 `NSScreen.main`）。我說話時 overlay 淡出至 `speakingOpacity`（RMS 取自 M1 audio pump，零額外成本）。

兩個新全域熱鍵：`.toggleMeetingCopilotOverlay`（釘住/toggle，keyUp-only 比照 `.toggleMeetingRecording`）與 `.peekMeetingCopilotOverlay`（**按住顯示、放開隱藏**——在 `refreshShortcutMonitor` 的 `onKeyDown` 閉包加顯式 branch，並複製 push-to-talk 的 key-repeat/cooldown 守衛）。同時**順手修既有缺陷 FR-32**：`.toggleMeetingRecording` 自 build 227 起不在 `legacyKeyboardShortcutActions` → 其鍵對衝突偵測雙向隱形；本 milestone 補資料層（其 `ShortcutRecorder` UI row 屬 M5）。

## User Story

As a 開會中被問問題的使用者, I want 一鍵（或按住一鍵）叫出一個對方（盡力）看不到、且永不搶走我鍵盤焦點的浮動提示視窗, so that 我能在 Teams/Meet 前景不變的情況下瞄一眼開口稿就接話。

## Problem → Solution

M2/M3 把「該回什麼」算好了，但狀態只存在 SwiftData 與 `@Published` 裡，會議中根本看不到；而任何普通視窗都會（1）被螢幕分享錄到、（2）搶走 Teams 的鍵盤焦點、（3）蓋不住全螢幕會議視窗。
→ 專用 `NSPanel`：`sharingType = .none`（擋 legacy 擷取 + Zoom 視窗過濾 + 所有 per-window/tab 分享；**macOS 15.4+ 分享整螢幕除外，UI 誠實明示**）+ `canBecomeKey = false` + `orderFrontRegardless()`（從不搶焦點）+ `.fullScreenAuxiliary`（浮在全螢幕會議上）+ `.screenSaver` level（蓋過所有既有 panel）+ 熱鍵 toggle/peek（不用滑鼠、不切 app）。

## Metadata
- **Module**: meeting-copilot
- **Parent Plan**: N/A（依賴鏈 M2 → M3 → **M4** → M5）
- **Source PRD**: N/A
- **Source Feature SRS**: `docs/srs/meeting-copilot-m4-overlay-hotkeys.srs.md`（umbrella `docs/srs/meeting-copilot-live-assist.srs.md` 的 M4 切片）
- **Source Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source Linear Issue**: N/A（`docs/prp.config.yml` → `skip: true`）
- **Type**: feature ｜ **Size**: L ｜ **Complexity**: Large
- **Rigor**: strict ｜ **Mode**: B — 任務先測 ｜ **TDD**: on（task-level）｜ **Commit cadence**: per-task
- **Estimated Files**: ~17（5 created + 6 modified + 7 test files 中 1 併檔）
- **Build**: 250 → **251**（M2=249、M3=250 之後；bump `CURRENT_PROJECT_VERSION`，Debug + Release **兩處**）
- **FR 覆蓋**: FR-21 ~ FR-26、FR-32
- **AC 覆蓋**: AC-16、AC-17、AC-19（衝突偵測資料層半部）；**AC-15 = 人工 gate**（實機三情境，見 Validation）

---

## ⚠️ 規劃期發現（實作前必讀）

以下是 canon §3 與 recon 交叉驗證 codebase 才確定的事實，直接決定本 plan 的形狀：

### 發現 1 — `sharingType = .none` 在 macOS 15.4+ 被 ScreenCaptureKit 忽略 🔴

Apple DTS 明言「目前沒有公開 API 可防螢幕擷取」；Chrome / Google Meet 的 `getDisplayMedia` 走 SCK。→ **分享整個螢幕時 overlay 會被錄到。** 仍要設 `sharingType = .none`（擋 legacy 擷取、Zoom 的視窗過濾、所有 per-window/tab 分享——密碼管理器同款用法），但：
- overlay 頂部**常駐警告條**：「分享整個螢幕會被錄到；安全模式 = 分享單一視窗/分頁」（Task 6）。
- **AC-15 的三情境實機驗證是人工 gate**（Task 9 手動驗證），其中情境 (a)(b)（分享整螢幕）**預期 overlay 被錄到、不視為 bug**，驗證重點是警告條誠實呈現。
- 任何文件與 UI 文案**不得宣稱無條件隱形**。

### 發現 2 — `sharingType` 與 `ignoresMouseEvents` 全 repo 從未在 Swift 用過

grep 確認：兩者的所有 hit 都在 docs（recon-windows.md:456-458）。M4 是**首次 Swift 使用**，沒有 in-repo 先例可驗證行為 → 這正是 AC-15 必須實機驗證的原因。另外 `ignoresMouseEvents` 一旦設 false（可點擊），clone base `MeetingIndicatorPanel` 的 `isMovable = true` + `isMovableByWindowBackground = true` 會讓使用者把 overlay 拖離近鏡頭錨點——**兩者都要改設 false**（Task 5）。

### 發現 3 — `MeetingIndicatorWindowManager` 有 frozen-frame bug，不要繼承

它的 `calculateWindowMetrics()` 只在 `initializeWindow()` 呼叫**一次**，`show()` 只 `orderFrontRegardless()` 不 `setFrame` → 位置凍結在第一次 show 時的 `NSScreen.main`（recon-windows.md:464）。`MiniRecorderPanel.show()` 與 `NotchRecorderPanel.show()` 都是每次 show 重算 + `setFrame`。→ Task 7 的 `show()` **每次重算**。

### 發現 4 — peek 絕不能走 `recordingMode(for:)`（陷阱）

CGEvent tap（`ShortcutMonitor`）對每個註冊 shortcut **一律同時發 keyDown 與 keyUp**；「keyUp-only」是 `RecordingShortcutManager.refreshShortcutMonitor` 的 `onKeyDown` 閉包用 `guard let mode = recordingMode(for: action) else { return }` **丟掉** keyDown 造成的（recon-hotkeys.md:561）。若把 peek 加進 `recordingMode(for:)` 讓它回非 nil，keyDown+keyUp 會全路由進 `RecordingShortcutModeHandler`——那驅動的是**迷你錄音面板的聽寫 push-to-talk**，目標錯誤（recon-hotkeys.md:563）。正解：`onKeyDown` 閉包加**顯式 peek branch**，並自行複製 push-to-talk 的兩個守衛（`isShortcutPressed` 擋 key-repeat auto-fire + 0.5s cooldown），因為按住一鍵會連發 keyDown（Task 7/8）。

### 發現 5 — 衝突偵測缺陷的根因（FR-32）

`ShortcutValidator.allStoredActions = legacyKeyboardShortcutActions + modes`（`ShortcutValidator.swift:436-442`），而 `.toggleMeetingRecording` 只在 `globalUtilityActions`、**不在** `legacyKeyboardShortcutActions` → 其鍵對衝突偵測**雙向隱形**（recon-hotkeys.md:445）。修法採選項 (a)：把 `.toggleMeetingRecording` + 兩新 case 一併加入 `legacyKeyboardShortcutActions`。**加入安全**：三者的 `legacyKeyboardShortcutsNames` 回 `[]`，`migrateLegacyKeyboardShortcut` no-op（Task 1）。

### 發現 6 — `.screenSaver`(1000) 會蓋過 notch recorder pill

全 repo level census（recon-windows.md:474）：`.normal`(0) / `.floating`(3) / `.mainMenu`(24) / `.statusBar`(25) / `.statusBar+3`(28，現最高)。`.screenSaver` = 1000 全清——但也蓋過 notch pill：使用者在 overlay 顯示時聽寫，overlay 會蓋住 notch。**已接受此取捨**（SRS Open Question；overlay 錨在螢幕上方中央、notch pill 也在上方中央，重疊機率高但聽寫時本就不該盯 overlay）；若實機體驗差，退用 `.statusBar + 4` 只需改一行。

### 發現 7 — `NotificationManager` 對本 milestone 三重失格

`showNotification` (1) 渲染**無 `sharingType`** 的可見 NSPanel → 分享時錯誤 toast 被廣播給全會議；(2) `.error` 呼 `SoundManager.shared.playEscSound()` → 會議中可聞聲；(3) `makeKeyAndOrderFront` 搶焦點（recon-windows.md:472）。→ M4 所有失敗路徑一律 **log-only**。同理**不套** `DictionaryQuickAddPanel` 的 focus save/restore——那是給 `canBecomeKey=true` 的 panel 用的，hide 時的 `previousApp?.activate()` 會把焦點從 Teams 搶走（recon-windows.md:230）。

### 發現 8 — Input Monitoring 權限提示有缺口

`warnIfGlobalShortcutInputBlocked` 只在設有 recording（primary/secondary）shortcut 時提示（recon-hotkeys.md:575）。只用會議熱鍵、無聽寫熱鍵的使用者，CGEvent tap 可能**靜默未安裝** → 兩個新熱鍵完全不觸發且無任何錯誤。M4 不改此邏輯（屬既有行為），但 Task 9 手動驗證含此情境，且列入 Risks。

### 發現 9 — 多螢幕「跟隨」不存在，M4 不新寫

repo 內唯一的多螢幕反應性是 `NotchRecorderPanel` 訂閱 `NSApplication.didChangeScreenParametersNotification`（**0.1s asyncAfter debounce**——同步讀 NSScreen 會拿到 stale 幾何；recon-windows.md:154）。它只在顯示器插拔/解析度變更觸發，**不**追使用者把會議視窗移到另一台既有顯示器。M4 逐字沿用此 pattern + 每次 show 重算；「即時跟隨」明確不做（SRS Open Question）。

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/meeting-copilot-m4-overlay-hotkeys.srs.md` | all | 本 milestone 的需求 + AC + 誠實約束全文 |
| P0 | `docs/reports/`（M2、M3 的實作 report） | all | **M4 消費其交付**：`MeetingCopilotController` 建構點、`@Published cues`、`MeetingLiveCue` tier 欄位實際型別 |
| P0 | `VoiceInk/Views/Meeting/MeetingIndicatorView.swift` | 39-60（panel）、62-101（manager） | **Task 5/7 的 clone base**。注意 frozen-frame bug（發現 3）不要照抄 |
| P0 | `VoiceInk/Views/Recorder/NotchRecorderPanel.swift` | 9-45（level + collectionBehavior）、75-91（show 重算 + screen-change debounce） | 最高 level 先例 + 唯一多螢幕反應性 pattern |
| P0 | `VoiceInk/Shortcuts/ShortcutAction.swift` | 3-123 | Task 1 的 5 處改動全在此檔（enum / storageName / displayName / globalUtilityActions / legacyKeyboardShortcutActions） |
| P0 | `VoiceInk/Shortcuts/RecordingShortcutManager.swift` | 212-260（`refreshShortcutMonitor` 閉包 + `recordingMode(for:)`）、266-334（push-to-talk 守衛）、314-366（`handleGlobalShortcut`） | Task 8 的侵入點；**發現 4 的陷阱就在 :248-257** |
| P0 | 專案記憶 `voiceink-running-unit-tests` | all | **測試指令必須照它寫**，否則 host crash（CloudKit `_os_crash`） |
| P0 | 專案記憶 `voiceink-sharingtype-sck-limitation` | all | 發現 1 的權威出處 |
| P1 | `VoiceInk/Shortcuts/ShortcutMigration.swift` | 251-275（`legacyKeyboardShortcutsNames`，exhaustive 無 default） | Task 1 必改，否則 compile error |
| P1 | `VoiceInk/Shortcuts/ShortcutValidator.swift` | 25-97（`validationError` + `allStoredActions`） | FR-32 的行為驗證面 |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | all | Task 2 擴充的對象；`@Published private(set)` + `…V1` key + `set…()` 樣式 |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingLiveTranscriber.swift` | 64-111（`start` + `startAudioPump`） | Task 4 的 RMS hook 插點 |
| P1 | `VoiceInk/Views/Dictionary/DictionaryQuickAddPanel.swift` | 22-52 | **反面教材**：focus save/restore 與 `makeKeyAndOrderFront` 為何不能抄（發現 7） |
| P2 | `VoiceInk/Views/Recorder/MiniRecorderPanel.swift` | 33-61 | oversized-host-NSRect + SwiftUI 控可視大小的 idiom（overlay 卡片隨 tier 內容伸縮） |
| P2 | `VoiceInkTests/MeetingAudioMixerTests.swift` | all | 純 seam 測試的房子風格 |
| P2 | 專案記憶 `voiceink-report-build-number`、`voiceink-build-no-ghost-apps` | all | bump build 並回報；**不要 build 進 /tmp**；**不自動 deploy** |

## External Documentation

無需外部研究——`sharingType` / `ignoresMouseEvents` / `CGWindowListCopyWindowInfo` 皆為標準 AppKit/CG API；SCK 限制已由 canon 查證定案（發現 1），實作期不要再花時間找「繞過 SCK」的方法——**不存在公開 API**。

---

## Patterns to Mirror

### OVERLAY_PANEL_BASE — clone 基底（Task 5 照抄再加料）
```swift
// SOURCE: VoiceInk/Views/Meeting/MeetingIndicatorView.swift:39-60
/// 指示器專用 panel:鏡射 `MiniRecorderPanel` 的浮動設定,但絕不成為 key window。
final class MeetingIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }
}
```
> M4 差異（全部在 Task 5）：`level = .screenSaver`；collectionBehavior 換 NotchRecorder 集合；**`isMovable` / `isMovableByWindowBackground` 改 false**（發現 2）；新增 `sharingType = .none` + `ignoresMouseEvents`。

### WINDOW_LEVEL_COLLECTION — 最高 level + 完整 collectionBehavior（Task 5 照抄）
```swift
// SOURCE: VoiceInk/Views/Recorder/NotchRecorderPanel.swift:103-116（節錄自 init）
        self.isFloatingPanel = true
        self.level = .statusBar + 3
        self.backgroundColor = .clear
        self.isOpaque = false
        self.alphaValue = 1.0
        self.hasShadow = false
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
```
> `.fullScreenAuxiliary` = 能浮在全螢幕 Teams/Meet 之上（**必要**）；`.stationary` = Mission Control 不動；`.ignoresCycle` = 不進 Cmd+`。M4 的 level 用 `.screenSaver`（發現 6）。

### SHOW_RECOMPUTE_AND_SCREEN_CHANGE — 每次 show 重算 + 螢幕變更 debounce（Task 7 照抄）
```swift
// SOURCE: VoiceInk/Views/Recorder/NotchRecorderPanel.swift:135-152
    func show() {
        let metrics = NotchRecorderPanel.calculateWindowMetrics()
        setFrame(metrics.frame, display: true)
        orderFrontRegardless()
    }

    @objc private func handleScreenParametersChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let metrics = NotchRecorderPanel.calculateWindowMetrics()
            self.setFrame(metrics.frame, display: true)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
```
> 0.1s debounce 是必要的——AppKit 在 notification 內同步讀 NSScreen 會拿到 stale 幾何（recon-windows.md:154）。

### WINDOW_MANAGER_LIFECYCLE — retain + NSHostingController 接法（Task 7 照抄生命週期，**不抄** frozen-frame bug）
```swift
// SOURCE: VoiceInk/Views/Meeting/MeetingIndicatorView.swift:62-101
@MainActor
final class MeetingIndicatorWindowManager {
    private var windowController: NSWindowController?
    private var panel: MeetingIndicatorPanel?
    private weak var controller: MeetingCaptureController?

    init(controller: MeetingCaptureController) {
        self.controller = controller
    }

    func show() {
        if panel == nil { initializeWindow() }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func initializeWindow() {
        guard let controller else { return }
        let metrics = Self.calculateWindowMetrics()
        let newPanel = MeetingIndicatorPanel(contentRect: metrics)
        let hosting = NSHostingController(rootView: MeetingIndicatorView(controller: controller))
        newPanel.contentView = hosting.view
        newPanel.setFrame(metrics, display: true)
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }
```
> RETENTION 語意照抄：strong `panel` + strong `windowController`（純為 retain）；`hide()` 只 `orderOut(nil)`，panel 存活重用，永不 `close()`。**但 `show()` 必須加 `setFrame(重算, display: true)`**（發現 3）。

### KEYDOWN_SWALLOW — keyDown 在哪裡被丟掉（Task 8 的侵入點）
```swift
// SOURCE: VoiceInk/Shortcuts/RecordingShortcutManager.swift:213-237（refreshShortcutMonitor 閉包）
        onKeyDown: { [weak self] action, eventTime in
            Task { @MainActor in
                guard let self else { return }
                guard let mode = self.recordingMode(for: action) else { return }
                await self.shortcutModeHandler.handleKeyDown(
                    action: action,
                    eventTime: eventTime,
                    mode: mode
                )
            }
        },
        onKeyUp: { [weak self] action, eventTime in
            Task { @MainActor in
                guard let self else { return }
                if let mode = self.recordingMode(for: action) {
                    await self.shortcutModeHandler.handleKeyUp(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                } else {
                    await self.handleGlobalShortcut(action)
                }
            }
        },
```
> peek 的 show-on-press 必須在 `onKeyDown` 的 `guard let mode` **之前**加顯式 branch（發現 4）；hide-on-release 走 `onKeyUp` else-path 的 `handleGlobalShortcut`。

### GLOBAL_KEYUP_DISPATCH — keyUp-only 全域動作樣式（Task 8 的 toggle 照抄）
```swift
// SOURCE: VoiceInk/Shortcuts/RecordingShortcutManager.swift:358-365（handleGlobalShortcut 節錄）
    case .quickAddToDictionary:
        DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
    case .toggleMeetingRecording:
        // 會議錄製與聽寫狀態機解耦——任何聽寫狀態下都可啟停。
        await MeetingCaptureController.shared.toggle()
    default:
        break
```

### PUSH_TO_TALK_GUARDS — key-repeat / cooldown 守衛（Task 7 的 `CopilotPeekGuard` 複製其語意）
```swift
// SOURCE: VoiceInk/Shortcuts/RecordingShortcutManager.swift:272-279（RecordingShortcutModeHandler.handleKeyDown 開頭）
    if interruptedRecordingActions.remove(action) != nil { return }
    if let lastTrigger = lastShortcutPressTime,
       Date().timeIntervalSince(lastTrigger) < shortcutPressCooldown { return }
    guard !isShortcutPressed else { return }
    isShortcutPressed = true
```
> 按住一鍵會連發 keyDown；`isShortcutPressed` 擋 key-repeat auto-fire、0.5s `shortcutPressCooldown` 擋短時間重觸。peek 手搓 show/hide 時**必須**複製這兩個守衛（recon-hotkeys.md:565）。

### EXHAUSTIVE_MIGRATION_ARM — 新 case 併入零 legacy arm（Task 1 照抄）
```swift
// SOURCE: VoiceInk/Shortcuts/ShortcutMigration.swift:395-398（legacyKeyboardShortcutsNames 末 arm）
    case .recorderPanelEscape, .recorderPanelMode, .toggleMeetingRecording:
        // toggleMeetingRecording 是新動作,不存在 legacy KeyboardShortcuts 鍵。
        return []
```
> exhaustive、無 default——不加新 case 的 arm **直接 compile error**（好）。兩新動作併入這一 arm。

### CONFLICT_VALIDATOR — 衝突偵測的來源清單（Task 1 修的就是這裡的輸入）
```swift
// SOURCE: VoiceInk/Shortcuts/ShortcutValidator.swift:424-442
private static func storedActionConflicting(with candidate: Shortcut, excluding actionToIgnore: ShortcutAction) -> ShortcutAction? {
    for action in allStoredActions where action != actionToIgnore {
        guard let existingShortcut = ShortcutStore.shortcut(for: action) else {
            continue
        }
        if existingShortcut.conflicts(with: candidate) {
            return action
        }
    }
    return nil
}

private static var allStoredActions: [ShortcutAction] {
    var seenActions = Set<ShortcutAction>()
    let actions = ShortcutAction.legacyKeyboardShortcutActions +
        ModeManager.shared.configurations.map { ShortcutAction.mode($0.id) }

    return actions.filter { seenActions.insert($0).inserted }
}
```

### CONFIG_STORE — 既有 M1 store 樣式（Task 2 照抄延伸）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift:17-19, 30, 66-70
    private let copilotEnabledKey = "meetingCopilotEnabledV1"
    ...
    @Published private(set) var copilotEnabled: Bool = false
    ...
    func setCopilotEnabled(_ value: Bool) {
        copilotEnabled = value
        UserDefaults.standard.set(value, forKey: copilotEnabledKey)
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

### ANTI_PATTERN — 兩個**不能抄**的既有 pattern
```swift
// SOURCE: VoiceInk/Views/Dictionary/DictionaryQuickAddPanel.swift:200, 220-227 — ❌ 不要抄
        previousApp = NSWorkspace.shared.frontmostApplication
        ...
    func hide() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        previousApp?.activate(options: .activateIgnoringOtherApps)   // ← hide 時搶焦點,會把 Teams 拉下前景
        previousApp = nil
    }
```
> 這套 save/restore 只因該 panel `canBecomeKey=true` + `makeKeyAndOrderFront` 真的搶焦點才需要。M4 的 panel `canBecomeKey=false` + `orderFrontRegardless()` **從不搶焦點**，照抄會是 dead code + hide 時反而搶焦點（發現 7）。同理 `NotificationManager.showNotification` 全面禁用（無 sharingType 的可見 panel + `.error` 播聲音 + 搶焦點）——失敗一律 log-only。

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Shortcuts/ShortcutAction.swift` | UPDATE | 兩新 case + storageName/displayName arms + `globalUtilityActions` append + `legacyKeyboardShortcutActions` append（含 `.toggleMeetingRecording`，FR-32） |
| `VoiceInk/Shortcuts/ShortcutMigration.swift` | UPDATE | `legacyKeyboardShortcutsNames` exhaustive switch 併入兩新 case（不改 = compile error） |
| `VoiceInk/Shortcuts/RecordingShortcutManager.swift` | UPDATE | `onKeyDown` 顯式 peek branch；`handleGlobalShortcut` 加 toggle + peek-release 兩 case |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | UPDATE | 三項 overlay 設定資料層（`overlayClickThrough` / `speakingOpacity` / `maxCuesShown`；UI row 屬 M5） |
| `VoiceInk/Services/MeetingCopilot/MeetingLiveTranscriber.swift` | UPDATE | `onLocalLevel` RMS 回呼（M4 說話淡出的接點；FR-25） |
| `VoiceInk/Services/MeetingCopilot/OverlayDimmingModel.swift` | CREATE | 說話淡出純狀態機 + RMS 純函式（AC-17 的可測核心） |
| `VoiceInk/Views/MeetingCopilot/CopilotOverlayPanel.swift` | CREATE | clone `MeetingIndicatorPanel` + sharingType/.screenSaver/click-through/不可拖曳（FR-22/23） |
| `VoiceInk/Views/MeetingCopilot/CopilotOverlayArranger.swift` | CREATE | cue 排列純函式（最新最上最大、舊的縮灰、已回答下沉；FR-26 的可測核心） |
| `VoiceInk/Views/MeetingCopilot/CopilotOverlayView.swift` | CREATE | opener 最大字級、三層漸進渲染、警告條（繁中字面，不進 xcstrings） |
| `VoiceInk/Views/MeetingCopilot/CopilotOverlayWindowManager.swift` | CREATE | show/hide/toggle/peek + 近鏡頭定位 + 螢幕變更重算 + `CopilotPeekGuard`（FR-21/24/25） |
| `VoiceInk.xcodeproj/project.pbxproj` | UPDATE | `CURRENT_PROJECT_VERSION` 250 → 251（Debug + Release **兩處**） |
| `VoiceInkTests/MeetingShortcutTests.swift` | CREATE | AC-19 資料層（衝突偵測行為驗證） |
| `VoiceInkTests/CopilotOverlayConfigTests.swift` | CREATE | 三設定的預設值 / 持久化 / clamp |
| `VoiceInkTests/OverlayDimmingTests.swift` | CREATE | AC-17（合成 RMS 序列 → 不透明度轉換 + 1.5s 恢復） |
| `VoiceInkTests/MeetingLocalLevelTests.swift` | CREATE | FR-25 接點（replay WAV → `onLocalLevel` 回報正能量） |
| `VoiceInkTests/CopilotOverlayPanelTests.swift` | CREATE | AC-16 自動化半部（canBecomeKey/sharingType/level/collectionBehavior/不可拖曳） |
| `VoiceInkTests/CopilotOverlayArrangerTests.swift` | CREATE | FR-26（排序 / emphasis / maxCount） |
| `VoiceInkTests/CopilotOverlayWindowManagerTests.swift` | CREATE | 近鏡頭 anchorRect 純函式 + `CopilotPeekGuard`（key-repeat / cooldown） |

> **pbxproj**：專案用 `PBXFileSystemSynchronizedRootGroup`，新 `.swift` 檔**自動入 target**，不需手動註冊。唯一要改 pbxproj 的是 build number。

## NOT Building（M4 明確不做）

- **cue 抽取、四分類、去重**（M2）；**三層 LLM 串流、SSE、grounding、預跑、取消**（M3）——M4 只呈現其結果
- **兩熱鍵的 `ShortcutRecorder` 設定 row** 與三項 overlay 設定的**設定頁 UI** → **M5**（`MeetingCopilotSettingsView` + `SettingsView`）。M4 只交付資料層
- `.toggleMeetingRecording` 的 `ShortcutRecorder` UI row → **M5**（M4 只補衝突偵測資料層，FR-32）
- **多螢幕即時跟隨**（會議視窗移到另一台既有顯示器）——repo 無此邏輯（發現 9），只做插拔/解析度變更重算
- **Input Monitoring 權限提示改造**（發現 8）——列入 Risks 與手動驗證，不改 `warnIfGlobalShortcutInputBlocked`
- 螢幕 OCR（`ScreenCaptureService`）——M3 的接地用途，與 overlay 無關
- 不動：`MeetingIndicatorPanel` 本身、`MiniRecorderPanel` / `NotchRecorderPanel`、聽寫 push-to-talk 的 `RecordingShortcutModeHandler` 路徑
- 不引入任何「防 SCK 擷取」的 hack（私有 API / 遮罩層）——**不存在公開解法，誠實明示即是解法**

---

## Step-by-Step Tasks

### Task 1: 熱鍵資料層 — 兩新 action + 修 `.toggleMeetingRecording` 衝突偵測（FR-21 資料層 + FR-32）

**Files:**
- Modify: `VoiceInk/Shortcuts/ShortcutAction.swift`
- Modify: `VoiceInk/Shortcuts/ShortcutMigration.swift`
- Test:   `VoiceInkTests/MeetingShortcutTests.swift`

> 三個 exhaustive switch（`storageName` / `displayName` / `legacyKeyboardShortcutsNames`）會在加 case 後 compile error——**這是設計好的護欄**，逐一補 arm。其餘（`isStored`、`recordingMode(for:)`、`handleGlobalShortcut`、validator）有 default，不加 arm 也編譯，但功能不通——Task 8 處理 dispatch。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingShortcutTests.swift
import XCTest
import Carbon.HIToolbox
@testable import VoiceInk

/// FR-32 + AC-19（資料層半部）:三個會議熱鍵皆須參與衝突偵測。
/// 行為驗證走 `ShortcutValidator.validationError`(public 面),不碰 private 的 allStoredActions。
/// ⚠️ host-app 測試讀寫**真** UserDefaults——setUp 快照、tearDown 還原,不得殘留。
final class MeetingShortcutTests: XCTestCase {

    private let meetingActions: [ShortcutAction] = [
        .toggleMeetingRecording,
        .toggleMeetingCopilotOverlay,
        .peekMeetingCopilotOverlay
    ]
    private var savedData: [String: Data?] = [:]

    override func setUp() {
        super.setUp()
        for action in meetingActions {
            savedData[action.userDefaultsKey] = UserDefaults.standard.data(forKey: action.userDefaultsKey)
        }
    }

    override func tearDown() {
        for action in meetingActions {
            ShortcutStore.removeShortcutStorage(for: action)
            if let data = savedData[action.userDefaultsKey] ?? nil {
                UserDefaults.standard.set(data, forKey: action.userDefaultsKey)
            }
        }
        super.tearDown()
    }

    // MARK: - 儲存/監看面

    func testNewActionStorageNamesAreStable() {
        XCTAssertEqual(ShortcutAction.toggleMeetingCopilotOverlay.storageName, "toggleMeetingCopilotOverlay")
        XCTAssertEqual(ShortcutAction.peekMeetingCopilotOverlay.storageName, "peekMeetingCopilotOverlay")
        // isStored 走 default → true,鍵才會被 ShortcutStore 持久化
        XCTAssertTrue(ShortcutAction.toggleMeetingCopilotOverlay.isStored)
        XCTAssertTrue(ShortcutAction.peekMeetingCopilotOverlay.isStored)
    }

    /// refreshShortcutMonitor 只監看 `ShortcutStore.shortcuts(for: globalUtilityActions)`
    /// (RecordingShortcutManager.swift:198)——不在清單裡 = 事件 tap 永遠看不到這兩鍵。
    func testNewActionsAreGlobalUtilityActions() {
        XCTAssertTrue(ShortcutAction.globalUtilityActions.contains(.toggleMeetingCopilotOverlay))
        XCTAssertTrue(ShortcutAction.globalUtilityActions.contains(.peekMeetingCopilotOverlay))
    }

    // MARK: - AC-19:衝突偵測(FR-32 的核心)

    /// build 227 缺陷:.toggleMeetingRecording 的鍵對衝突偵測雙向隱形。修復後:
    /// 給它設一鍵 → 同一鍵指派給其他動作必須被拒(.alreadyUsedBy)。
    func testMeetingRecordingShortcutParticipatesInConflictDetection() {
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_9), modifierFlags: [.command, .option, .control])
        ShortcutStore.setShortcut(shortcut, for: .toggleMeetingRecording)
        XCTAssertNotNil(ShortcutStore.shortcut(for: .toggleMeetingRecording), "前置:鍵必須真的存進去")

        let error = ShortcutValidator.validationError(for: shortcut, action: .pasteLastTranscription)
        XCTAssertEqual(error, .alreadyUsedBy(ShortcutAction.toggleMeetingRecording.displayName))
    }

    func testOverlayToggleShortcutParticipatesInConflictDetection() {
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_8), modifierFlags: [.command, .option, .control])
        ShortcutStore.setShortcut(shortcut, for: .toggleMeetingCopilotOverlay)
        XCTAssertNotNil(ShortcutStore.shortcut(for: .toggleMeetingCopilotOverlay))

        let error = ShortcutValidator.validationError(for: shortcut, action: .openHistoryWindow)
        XCTAssertEqual(error, .alreadyUsedBy(ShortcutAction.toggleMeetingCopilotOverlay.displayName))
    }

    func testPeekShortcutParticipatesInConflictDetection() {
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_7), modifierFlags: [.command, .option, .control])
        ShortcutStore.setShortcut(shortcut, for: .peekMeetingCopilotOverlay)
        XCTAssertNotNil(ShortcutStore.shortcut(for: .peekMeetingCopilotOverlay))

        // 反向:其他動作已占用的鍵,也不能指派給 peek
        let error = ShortcutValidator.validationError(for: shortcut, action: .toggleMeetingCopilotOverlay)
        XCTAssertEqual(error, .alreadyUsedBy(ShortcutAction.peekMeetingCopilotOverlay.displayName))
    }
}
```
  Run（**必須用這個完整指令，見專案記憶 `voiceink-running-unit-tests`**）:
  ```bash
  xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
    -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    -only-testing:VoiceInkTests/MeetingShortcutTests
  ```
  Expected: **FAIL**（`.toggleMeetingCopilotOverlay` 不存在 → compile error）。

- **IMPLEMENT**（`ShortcutAction.swift`，五處）:
```swift
// 1) enum(ShortcutAction.swift:3-20)— .toggleMeetingRecording 之後加:
    case toggleMeetingCopilotOverlay
    case peekMeetingCopilotOverlay

// 2) storageName(:34-61,exhaustive)— .toggleMeetingRecording arm 之後加:
        case .toggleMeetingCopilotOverlay:
            return "toggleMeetingCopilotOverlay"
        case .peekMeetingCopilotOverlay:
            return "peekMeetingCopilotOverlay"

// 3) displayName(:63-98,exhaustive)— .toggleMeetingRecording arm 之後加:
        case .toggleMeetingCopilotOverlay:
            return String(localized: "Toggle Meeting Copilot Overlay")
        case .peekMeetingCopilotOverlay:
            return String(localized: "Peek Meeting Copilot Overlay")

// 4) globalUtilityActions(:100-107)— 末端 append:
    static let globalUtilityActions: [Self] = [
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .openHistoryWindow,
        .quickAddToDictionary,
        .toggleMeetingRecording,
        .toggleMeetingCopilotOverlay,
        .peekMeetingCopilotOverlay
    ]

// 5) legacyKeyboardShortcutActions(:113-122)— 末端 append(🔴 FR-32:含 .toggleMeetingRecording):
    static let legacyKeyboardShortcutActions: [Self] = [
        .primaryRecording,
        .secondaryRecording,
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .cancelRecorder,
        .openHistoryWindow,
        .quickAddToDictionary,
        // FR-32:自 build 227 起 .toggleMeetingRecording 不在此清單 → 其鍵逃過
        // ShortcutValidator.allStoredActions 的衝突偵測(雙向隱形)。加入安全:
        // 三者的 legacyKeyboardShortcutsNames 回 [],migrateLegacyKeyboardShortcut no-op。
        .toggleMeetingRecording,
        .toggleMeetingCopilotOverlay,
        .peekMeetingCopilotOverlay
    ]
```
  `ShortcutMigration.swift:251-275`（exhaustive，不改 = compile error）——兩新 case 併入末 arm:
```swift
        case .recorderPanelEscape, .recorderPanelMode, .toggleMeetingRecording,
             .toggleMeetingCopilotOverlay, .peekMeetingCopilotOverlay:
            // 會議相關動作皆為新動作,不存在 legacy KeyboardShortcuts 鍵。
            return []
```

- **MIRROR**: `EXHAUSTIVE_MIGRATION_ARM` + `CONFLICT_VALIDATOR`

- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingShortcutTests` — expect **PASS**（5 測試全綠）。順帶確認全專案編譯（exhaustive switch 都補齊了）。

- **GOTCHA**: `isStored` / `recordingMode(for:)` / `handleGlobalShortcut` / `ShortcutValidator` 都有 default——**不要**在本 task 動它們。特別是 `recordingMode(for:)`：peek **絕不能**加進去（發現 4）。

- **COMMIT**: `feat(meeting-copilot): overlay hotkey actions + fix meeting-recording conflict detection (FR-32)`

---

### Task 2: MeetingCopilotConfigStore 擴充三項 overlay 設定

**Files:**
- Modify: `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift`
- Test:   `VoiceInkTests/CopilotOverlayConfigTests.swift`

- **ACTION**: 提供 `overlayClickThrough`（預設 false）/ `speakingOpacity`（預設 0.35）/ `maxCuesShown`（預設 5）的資料層。設定頁 UI row 屬 M5。

- **TEST FIRST**:
```swift
// VoiceInkTests/CopilotOverlayConfigTests.swift
import XCTest
@testable import VoiceInk

@MainActor
final class CopilotOverlayConfigTests: XCTestCase {

    private let keys = [
        "meetingCopilotOverlayClickThroughV1",
        "meetingCopilotSpeakingOpacityV1",
        "meetingCopilotMaxCuesShownV1"
    ]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    func testOverlayDefaults() {
        let store = MeetingCopilotConfigStore()
        XCTAssertFalse(store.overlayClickThrough, "預設不穿透——第一次用得先能點得到")
        XCTAssertEqual(store.speakingOpacity, 0.35, accuracy: 1e-9)
        XCTAssertEqual(store.maxCuesShown, 5)
    }

    func testOverlaySettingsPersistAndReload() {
        let store = MeetingCopilotConfigStore()
        store.setOverlayClickThrough(true)
        store.setSpeakingOpacity(0.5)
        store.setMaxCuesShown(3)

        let reloaded = MeetingCopilotConfigStore()
        XCTAssertTrue(reloaded.overlayClickThrough)
        XCTAssertEqual(reloaded.speakingOpacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(reloaded.maxCuesShown, 3)
    }

    /// speakingOpacity 夾在 [0.05, 1.0]:0 會讓 overlay 隱形到找不回來,>1 無意義。
    func testSpeakingOpacityIsClamped() {
        let store = MeetingCopilotConfigStore()
        store.setSpeakingOpacity(0.0)
        XCTAssertEqual(store.speakingOpacity, 0.05, accuracy: 1e-9)
        store.setSpeakingOpacity(2.0)
        XCTAssertEqual(store.speakingOpacity, 1.0, accuracy: 1e-9)
    }

    /// maxCuesShown 夾在 [1, 20]。
    func testMaxCuesShownIsClamped() {
        let store = MeetingCopilotConfigStore()
        store.setMaxCuesShown(0)
        XCTAssertEqual(store.maxCuesShown, 1)
        store.setMaxCuesShown(999)
        XCTAssertEqual(store.maxCuesShown, 20)
    }
}
```
  Run: `-only-testing:VoiceInkTests/CopilotOverlayConfigTests` — expect **FAIL**（屬性不存在）

- **IMPLEMENT**（追加到 `MeetingCopilotConfigStore`，照既有樣式）:
```swift
    // MARK: - Overlay 設定(M4;設定頁 UI row 屬 M5)

    private let overlayClickThroughKey = "meetingCopilotOverlayClickThroughV1"
    private let speakingOpacityKey = "meetingCopilotSpeakingOpacityV1"
    private let maxCuesShownKey = "meetingCopilotMaxCuesShownV1"

    /// 點擊穿透。決定 `CopilotOverlayPanel.ignoresMouseEvents`。預設 false(可點 cue 觸發 Tier 2)。
    @Published private(set) var overlayClickThrough: Bool = false

    /// 我說話時 overlay 的不透明度(FR-25)。夾在 [0.05, 1.0]。
    @Published private(set) var speakingOpacity: Double = 0.35

    /// overlay 最多列出幾則 cue(FR-26)。夾在 [1, 20]。
    @Published private(set) var maxCuesShown: Int = 5

    func setOverlayClickThrough(_ value: Bool) {
        overlayClickThrough = value
        UserDefaults.standard.set(value, forKey: overlayClickThroughKey)
    }

    func setSpeakingOpacity(_ value: Double) {
        let clamped = min(max(value, 0.05), 1.0)
        speakingOpacity = clamped
        UserDefaults.standard.set(clamped, forKey: speakingOpacityKey)
    }

    func setMaxCuesShown(_ value: Int) {
        let clamped = min(max(value, 1), 20)
        maxCuesShown = clamped
        UserDefaults.standard.set(clamped, forKey: maxCuesShownKey)
    }
```
  並在既有 `load()` 內追加:
```swift
        overlayClickThrough = d.bool(forKey: overlayClickThroughKey)   // 未設定 → false

        if d.object(forKey: speakingOpacityKey) != nil {
            speakingOpacity = min(max(d.double(forKey: speakingOpacityKey), 0.05), 1.0)
        }

        if d.object(forKey: maxCuesShownKey) != nil {
            maxCuesShown = min(max(d.integer(forKey: maxCuesShownKey), 1), 20)
        }
```

- **MIRROR**: `CONFIG_STORE`

- **VALIDATE**: `-only-testing:VoiceInkTests/CopilotOverlayConfigTests` — **PASS**（4 測試全綠）

- **GOTCHA**: M2/M3 也擴充過這個檔（fast/deep model、grounding 開關）——追加時放在檔尾自己的 `MARK` 區塊，不要動既有鍵名。

- **COMMIT**: `feat(meeting-copilot): overlay config data layer (clickThrough/speakingOpacity/maxCuesShown)`

---

### Task 3: OverlayDimmingModel — 說話淡出純狀態機（AC-17 的可測核心）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/OverlayDimmingModel.swift`
- Test:   `VoiceInkTests/OverlayDimmingTests.swift`

- **ACTION**: 「local RMS 超門檻 → 淡出到 `speakingOpacity`；停止說話 1.5s 後恢復 1.0」做成免 UI、免 timer 的純狀態機——每個 RMS 樣本進來時判定當下該有的不透明度。（音訊 frame 在會議進行中持續抵達，靜音時 RMS≈0 也照樣回報，所以**不需要**額外 timer 驅動恢復。）

- **TEST FIRST**:
```swift
// VoiceInkTests/OverlayDimmingTests.swift
import XCTest
@testable import VoiceInk

/// AC-17:我說話時淡出至 speakingOpacity;停止說話 1.5 秒後恢復 1.0。
/// 以合成 RMS 序列驅動,不碰 UI、不碰 timer。
final class OverlayDimmingTests: XCTestCase {

    func testDimsWhileLocalStreamActive() {
        var model = OverlayDimmingModel(speakingOpacity: 0.35)
        // t=0:大聲說話 → 立即淡出
        XCTAssertEqual(model.update(rms: 0.5, at: 0.0), 0.35, accuracy: 1e-9)
        // t=0.5:還在說 → 維持淡出
        XCTAssertEqual(model.update(rms: 0.3, at: 0.5), 0.35, accuracy: 1e-9)
    }

    func testRecoversAfterOnePointFiveSecondsOfSilence() {
        var model = OverlayDimmingModel(speakingOpacity: 0.35)
        _ = model.update(rms: 0.5, at: 0.0)          // 說話
        // 靜音 1.49s → 仍淡出(未滿 1.5s)
        XCTAssertEqual(model.update(rms: 0.0, at: 1.49), 0.35, accuracy: 1e-9)
        // 靜音 1.51s → 恢復
        XCTAssertEqual(model.update(rms: 0.0, at: 1.51), 1.0, accuracy: 1e-9)
    }

    func testContinuedSpeechKeepsResettingTheClock() {
        var model = OverlayDimmingModel(speakingOpacity: 0.35)
        _ = model.update(rms: 0.5, at: 0.0)
        _ = model.update(rms: 0.5, at: 1.4)           // 又說了一聲 → 時鐘重置
        XCTAssertEqual(model.update(rms: 0.0, at: 2.8), 0.35, accuracy: 1e-9, "距最後說話 1.4s,未滿 1.5s")
        XCTAssertEqual(model.update(rms: 0.0, at: 3.0), 1.0, accuracy: 1e-9, "距最後說話 1.6s,恢復")
    }

    /// 低於門檻的環境噪音不觸發淡出。
    func testBelowThresholdNoiseDoesNotDim() {
        var model = OverlayDimmingModel(speakingOpacity: 0.35)
        XCTAssertEqual(model.update(rms: 0.005, at: 0.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(model.update(rms: 0.019, at: 1.0), 1.0, accuracy: 1e-9)
    }

    // MARK: - RMS 純函式

    func testRMSOfKnownSignal() {
        // 定值 0.5 的訊號 → RMS = 0.5
        let rms = OverlayDimmingModel.rms(channelBuffers: [[0.5, 0.5, 0.5, 0.5]], frameCount: 4)
        XCTAssertEqual(rms, 0.5, accuracy: 1e-5)
    }

    func testRMSOfSilenceAndEmptyInput() {
        XCTAssertEqual(OverlayDimmingModel.rms(channelBuffers: [[0, 0, 0]], frameCount: 3), 0.0, accuracy: 1e-9)
        XCTAssertEqual(OverlayDimmingModel.rms(channelBuffers: [], frameCount: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(OverlayDimmingModel.rms(channelBuffers: [[1]], frameCount: 4), 0.0, accuracy: 1e-9, "frameCount 超出樣本數 → 0,不越界")
    }
}
```
  Run: `-only-testing:VoiceInkTests/OverlayDimmingTests` — expect **FAIL**（型別不存在）

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/OverlayDimmingModel.swift
import Foundation

/// 「我說話時 overlay 淡出」的純狀態機(FR-25 / AC-17)。
///
/// 免 UI、免 timer:音訊 frame 在會議中持續抵達(靜音時 RMS≈0 也回報),
/// 所以每個樣本進來時**重新判定**當下不透明度即可,不需排程恢復。
/// 呼叫端(`CopilotOverlayWindowManager`)拿回傳值去設 `panel.alphaValue`。
///
/// ⚠️ 門檻已知限制(umbrella SRS Risks):喇叭外放(不戴耳機)時對方聲音會經
/// mic 誤觸發淡出。門檻最終值待實機調校;M4 先取 0.02(正規化 Float 樣本)。
struct OverlayDimmingModel {

    /// RMS 超過此值視為「我在說話」。
    var threshold: Float = 0.02
    /// 停止說話後多久恢復(秒)。
    var recoveryDelay: TimeInterval = 1.5
    /// 說話時的目標不透明度(來自 `MeetingCopilotConfigStore.speakingOpacity`)。
    var speakingOpacity: Double = 0.35

    private var lastVoiceAt: TimeInterval = -.infinity

    init(speakingOpacity: Double = 0.35) {
        self.speakingOpacity = speakingOpacity
    }

    /// 回傳此刻 overlay 該有的不透明度。
    mutating func update(rms: Float, at now: TimeInterval) -> Double {
        if rms >= threshold {
            lastVoiceAt = now
        }
        return (now - lastVoiceAt) < recoveryDelay ? speakingOpacity : 1.0
    }

    /// 多聲道 RMS(全聲道樣本平方均值開根)。純函式,樣不足回 0 不越界。
    static func rms(channelBuffers: [[Float]], frameCount: Int) -> Float {
        guard frameCount > 0, !channelBuffers.isEmpty,
              channelBuffers.allSatisfy({ $0.count >= frameCount }) else { return 0 }
        var sum: Float = 0
        for channel in channelBuffers {
            for i in 0..<frameCount {
                sum += channel[i] * channel[i]
            }
        }
        return (sum / Float(frameCount * channelBuffers.count)).squareRoot()
    }
}
```

- **MIRROR**: `PURE_FUNCTION_NAMESPACE` 精神（同 `MeetingAudioMixer` / `MeetingChannelSplitter`：可測核心與 UI 徹底分離）

- **VALIDATE**: `-only-testing:VoiceInkTests/OverlayDimmingTests` — **PASS**（6 測試全綠）

- **COMMIT**: `feat(meeting-copilot): OverlayDimmingModel — speak-to-dim state machine (AC-17 core)`

---

### Task 4: MeetingLiveTranscriber.onLocalLevel — RMS 接點（FR-25）

**Files:**
- Modify: `VoiceInk/Services/MeetingCopilot/MeetingLiveTranscriber.swift`
- Test:   `VoiceInkTests/MeetingLocalLevelTests.swift`

- **ACTION**: audio pump 每收到一個含 local 聲道的 frame，就回報一次 RMS。**零額外音訊成本**——frame 已在 pump 手上，只多一次純函式計算。與 `localStream`（ASR）**無關**：即使 `transcribeLocalMic` 關閉，只要 frame 有 local 聲道就回報，淡出照樣運作。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingLocalLevelTests.swift
import XCTest
import AVFoundation
@testable import VoiceInk

/// FR-25 接點:local 聲道的 RMS 經 onLocalLevel 回報(給 overlay 淡出用)。
/// 沿用 M1 replay harness——不開 Teams、不碰 CoreAudio。
@MainActor
final class MeetingLocalLevelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingLocalLevelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeSineWAV(named name: String, amplitude: Float, seconds: Double = 0.5) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let rate = 16_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = amplitude * Float(sin(2.0 * .pi * 440.0 * Double(i) / rate))
        }
        try file.write(from: buffer)
        return url
    }

    /// local 有聲音 → onLocalLevel 回報正能量(可觸發淡出)。
    func testOnLocalLevelReportsPositiveRMSWhileSpeaking() async throws {
        let remoteWAV = try writeSineWAV(named: "remote.wav", amplitude: 0.0)
        let localWAV  = try writeSineWAV(named: "local.wav",  amplitude: 0.5)

        let source = ReplayMeetingAudioSource(remoteURL: remoteWAV, localURL: localWAV, speed: 50.0, chunkFrames: 1600)
        let transcriber = MeetingLiveTranscriber(
            source: source,
            remoteStream: FakeMeetingTranscriptStream(),
            localStream: FakeMeetingTranscriptStream()
        )

        var levels: [Float] = []
        transcriber.onLocalLevel = { levels.append($0) }

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(800))
        await transcriber.stop()

        XCTAssertFalse(levels.isEmpty, "local 有聲道,必須有 RMS 回報")
        // 0.5 振幅正弦波的 RMS ≈ 0.354,遠超淡出門檻 0.02
        XCTAssertGreaterThan(levels.max() ?? 0, 0.1)
    }

    /// local 靜音 → 回報的 RMS 全部低於淡出門檻(不誤觸發)。
    func testSilentLocalReportsNearZeroRMS() async throws {
        let remoteWAV = try writeSineWAV(named: "remote2.wav", amplitude: 0.5)
        let localWAV  = try writeSineWAV(named: "silent.wav",  amplitude: 0.0)

        let source = ReplayMeetingAudioSource(remoteURL: remoteWAV, localURL: localWAV, speed: 50.0, chunkFrames: 1600)
        let transcriber = MeetingLiveTranscriber(
            source: source,
            remoteStream: FakeMeetingTranscriptStream(),
            localStream: nil          // ASR 關閉 —— RMS 回報必須照常
        )

        var levels: [Float] = []
        transcriber.onLocalLevel = { levels.append($0) }

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(800))
        await transcriber.stop()

        XCTAssertFalse(levels.isEmpty, "localStream=nil 時 RMS 回報必須照常(淡出與 ASR 解耦)")
        XCTAssertLessThan(levels.max() ?? 1, 0.02, "靜音不得超過淡出門檻")
    }
}
```
  Run: `-only-testing:VoiceInkTests/MeetingLocalLevelTests` — expect **FAIL**（`onLocalLevel` 不存在）

- **IMPLEMENT**（`MeetingLiveTranscriber.swift`）:
  1. 觀察狀態區（`onRemoteCommitted` 宣告之後）追加:
```swift
    /// 每個含 local 聲道的音訊 frame 的 RMS。**M4 overlay 說話淡出的接點**(FR-25)。
    ///
    /// - 在 `start()` **之前**設定(pump 啟動時拷貝一份 closure)。
    /// - 與 `localStream`(ASR)無關:`transcribeLocalMic` 關閉時照樣回報——
    ///   淡出保護不因省 ASR 而失效。
    /// - 於 MainActor 上呼叫。
    var onLocalLevel: ((Float) -> Void)?
```
  2. `startAudioPump()` 開頭的區域拷貝加一行 `let onLocalLevel = self.onLocalLevel`，並在 `for await frame` 迴圈內、既有 local ASR branch **之前**加:
```swift
                // 我在說話的能量 → overlay 淡出(M4)。與 local ASR 是否啟用無關。
                if let onLocalLevel, !frame.local.isEmpty {
                    let rms = OverlayDimmingModel.rms(
                        channelBuffers: frame.local,
                        frameCount: frame.frameCount
                    )
                    Task { @MainActor in onLocalLevel(rms) }
                }
```

- **MIRROR**: 既有 pump 的區域拷貝樣式（`let local = self.localStream`）+ `onRemoteCommitted` 的接點文檔風格

- **VALIDATE**:
  1. `-only-testing:VoiceInkTests/MeetingLocalLevelTests` — **PASS**
  2. `-only-testing:VoiceInkTests/MeetingCopilotReplayTests` — **PASS**（M1 replay 測試零回歸——pump 被動過）

- **GOTCHA**: pump 是 `Task.detached`；closure 用區域拷貝（在 pump 啟動時定格），所以 `onLocalLevel` 必須在 `start()` 前設好——`CopilotOverlayWindowManager.configure` 的接線時機要注意（Task 7）。每 frame 一個 `Task { @MainActor }` 的開銷：frame 為 0.1s 級 chunk（10/s），可忽略。

- **COMMIT**: `feat(meeting-copilot): onLocalLevel RMS hook on audio pump (FR-25 seam)`

---

### Task 5: CopilotOverlayPanel（FR-22 / FR-23）

**Files:**
- Create: `VoiceInk/Views/MeetingCopilot/CopilotOverlayPanel.swift`
- Test:   `VoiceInkTests/CopilotOverlayPanelTests.swift`

- **ACTION**: clone `MeetingIndicatorPanel` + 四項加料：`sharingType = .none`（全 repo 首次 Swift 使用）、`.screenSaver` level、NotchRecorder 的完整 collectionBehavior、`ignoresMouseEvents`（依參數）+ **不可拖曳**。

- **TEST FIRST**:
```swift
// VoiceInkTests/CopilotOverlayPanelTests.swift
import XCTest
@testable import VoiceInk

/// AC-16 自動化半部 + FR-22/FR-23 的視窗屬性。
/// host-app 測試在真 app 內跑,可以直接建 NSPanel。
@MainActor
final class CopilotOverlayPanelTests: XCTestCase {

    private func makePanel(clickThrough: Bool = false) -> CopilotOverlayPanel {
        CopilotOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            clickThrough: clickThrough
        )
    }

    /// AC-16:永不搶焦點的根基。
    func testCanBecomeKeyIsFalse() {
        let panel = makePanel()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    /// FR-22:盡力排除於螢幕分享(macOS 15.4+ 分享整螢幕除外——警告條負責誠實)。
    func testSharingTypeIsNone() {
        XCTAssertEqual(makePanel().sharingType, .none)
    }

    /// 蓋過所有既有 panel(census 最高 .statusBar+3 = 28;.screenSaver = 1000)。
    func testLevelIsScreenSaver() {
        XCTAssertEqual(makePanel().level, .screenSaver)
    }

    /// .fullScreenAuxiliary = 浮在全螢幕 Teams/Meet 上(必要);.stationary/.ignoresCycle 比照 Notch。
    func testCollectionBehaviorCoversFullScreenMeetings() {
        let behavior = makePanel().collectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.stationary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
    }

    /// FR-23:click-through 依參數;peek 可點時也不能被拖離近鏡頭錨點。
    func testClickThroughAndImmovability() {
        let solid = makePanel(clickThrough: false)
        XCTAssertFalse(solid.ignoresMouseEvents)
        XCTAssertFalse(solid.isMovable, "clone base 是 true——必須翻成 false,否則會被拖走")
        XCTAssertFalse(solid.isMovableByWindowBackground)

        let ghost = makePanel(clickThrough: true)
        XCTAssertTrue(ghost.ignoresMouseEvents)
    }

    /// 透明無邊框(視覺由 SwiftUI 卡片自理)。
    func testTransparentChrome() {
        let panel = makePanel()
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.hidesOnDeactivate)
    }
}
```
  Run: `-only-testing:VoiceInkTests/CopilotOverlayPanelTests` — expect **FAIL**（型別不存在）

- **IMPLEMENT**:
```swift
// VoiceInk/Views/MeetingCopilot/CopilotOverlayPanel.swift
import AppKit

/// 會議 copilot 的隱蔽浮動 panel。clone `MeetingIndicatorPanel`(絕不成為 key window)再加:
///
/// - `sharingType = .none` —— **盡力**排除於螢幕分享(legacy 擷取、Zoom 視窗過濾、
///   所有 per-window/tab 分享)。🔴 **macOS 15.4+ 的 ScreenCaptureKit 忽略此旗標**:
///   分享**整個螢幕**時本視窗**會被錄到**。安全模式 = 分享單一視窗/分頁。
///   `CopilotOverlayView` 頂部常駐警告條明示此邊界——不得宣稱無條件隱形。
///   (Apple DTS:目前無公開 API 可防螢幕擷取;memory voiceink-sharingtype-sck-limitation)
/// - `.screenSaver` level(1000)—— 蓋過全 repo 最高的 NotchRecorderPanel(.statusBar+3=28),
///   含浮在全螢幕 Teams/Meet 之上(配合 .fullScreenAuxiliary)。副作用:也蓋過 notch pill。
/// - `ignoresMouseEvents` 依設定(FR-23 點擊穿透);`isMovable` 兩項**必須 false**——
///   clone base 是 true,可點模式下使用者會把 overlay 拖離近鏡頭錨點。
///
/// 失敗路徑一律 log-only:**絕不**用 NotificationManager(無 sharingType 的可見 panel
/// + error 播聲音 + 搶焦點,對會議 copilot 三重失格)。
final class CopilotOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, clickThrough: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        ignoresMouseEvents = clickThrough
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
    }
}
```

- **MIRROR**: `OVERLAY_PANEL_BASE`（生命週期與透明 chrome）+ `WINDOW_LEVEL_COLLECTION`（level 與 collectionBehavior）

- **VALIDATE**: `-only-testing:VoiceInkTests/CopilotOverlayPanelTests` — **PASS**（6 測試全綠）

- **GOTCHA**: clone base 的 `standardWindowButton(.closeButton)?.isHidden = true` 是 no-op（styleMask 無 `.titled` → button 是 nil，recon-windows.md:32）——**刻意不抄**這行殭屍碼。

- **COMMIT**: `feat(meeting-copilot): CopilotOverlayPanel — sharingType=.none covert panel (FR-22/23)`

---

### Task 6: CopilotOverlayArranger + CopilotOverlayView（FR-26 + 警告條）

**Files:**
- Create: `VoiceInk/Views/MeetingCopilot/CopilotOverlayArranger.swift`
- Create: `VoiceInk/Views/MeetingCopilot/CopilotOverlayView.swift`
- Test:   `VoiceInkTests/CopilotOverlayArrangerTests.swift`

- **ACTION**: 排列邏輯（最新最上最大、舊的縮灰、已回答下沉、上限 `maxCuesShown`）做成 generic 純函式先測死；SwiftUI view 只負責渲染（繁中字面，不進 xcstrings）。

- **TEST FIRST**:
```swift
// VoiceInkTests/CopilotOverlayArrangerTests.swift
import XCTest
@testable import VoiceInk

/// FR-26:opener 最大字級的載體是「focus」emphasis——最新一則未回答 cue。
/// generic 純函式,用素 struct 測,不碰 SwiftData。
final class CopilotOverlayArrangerTests: XCTestCase {

    private struct StubCue {
        let name: String
        let askedAt: Date
        let answered: Bool
    }

    private func arrange(_ cues: [StubCue], maxCount: Int = 5) -> [(cue: StubCue, emphasis: CopilotOverlayEmphasis)] {
        CopilotOverlayArranger.arrange(
            cues,
            askedAt: { $0.askedAt },
            isAnswered: { $0.answered },
            maxCount: maxCount
        )
    }

    private func cue(_ name: String, secondsAgo: TimeInterval, answered: Bool = false) -> StubCue {
        StubCue(name: name, askedAt: Date(timeIntervalSinceNow: -secondsAgo), answered: answered)
    }

    /// 最新最上且是唯一 focus;較舊的縮為 recent。
    func testNewestUnansweredIsFocusAndFirst() {
        let out = arrange([cue("old", secondsAgo: 60), cue("new", secondsAgo: 5), cue("mid", secondsAgo: 30)])
        XCTAssertEqual(out.map(\.cue.name), ["new", "mid", "old"], "由新到舊")
        XCTAssertEqual(out.map(\.emphasis), [.focus, .recent, .recent])
    }

    /// 已回答的下沉為 answered(變灰);focus 落到最新「未回答」那則。
    func testAnsweredCueIsDimmedAndFocusSkipsIt() {
        let out = arrange([cue("answered", secondsAgo: 5, answered: true), cue("open", secondsAgo: 30)])
        XCTAssertEqual(out.map(\.cue.name), ["answered", "open"], "順序仍按時間,不重排")
        XCTAssertEqual(out[0].emphasis, .answered)
        XCTAssertEqual(out[1].emphasis, .focus, "最新未回答者才是 focus")
    }

    /// 超過 maxCount 截斷(保最新)。
    func testCapsAtMaxCount() {
        let cues = (0..<10).map { cue("c\($0)", secondsAgo: TimeInterval($0)) }
        let out = arrange(cues, maxCount: 3)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.cue.name), ["c0", "c1", "c2"])
    }

    /// 空清單 / maxCount 0 → 空,不崩。
    func testEmptyAndZeroMax() {
        XCTAssertTrue(arrange([]).isEmpty)
        XCTAssertTrue(arrange([cue("x", secondsAgo: 1)], maxCount: 0).isEmpty)
    }

    /// 全部已回答 → 沒有 focus。
    func testAllAnsweredYieldsNoFocus() {
        let out = arrange([cue("a", secondsAgo: 5, answered: true), cue("b", secondsAgo: 10, answered: true)])
        XCTAssertFalse(out.contains { $0.emphasis == .focus })
    }
}
```
  Run: `-only-testing:VoiceInkTests/CopilotOverlayArrangerTests` — expect **FAIL**

- **IMPLEMENT**:
```swift
// VoiceInk/Views/MeetingCopilot/CopilotOverlayArranger.swift
import Foundation

/// overlay 上一則 cue 的視覺強調層級(FR-26)。
enum CopilotOverlayEmphasis: Equatable {
    /// 最新未回答——opener 最大字級單獨呈現的那一則。
    case focus
    /// 較舊未回答——縮為單行、次要字級。
    case recent
    /// 已回答——下沉變灰。
    case answered
}

/// cue 排列純函式:由新到舊、focus 只給最新未回答者、截斷至 maxCount。
/// generic over C —— 測試用素 struct,view 用 `MeetingLiveCue`(SwiftData @Model)。
enum CopilotOverlayArranger {
    static func arrange<C>(
        _ cues: [C],
        askedAt: (C) -> Date,
        isAnswered: (C) -> Bool,
        maxCount: Int
    ) -> [(cue: C, emphasis: CopilotOverlayEmphasis)] {
        guard maxCount > 0 else { return [] }
        let newestFirst = cues.sorted { askedAt($0) > askedAt($1) }.prefix(maxCount)
        var focusAssigned = false
        return newestFirst.map { cue in
            if isAnswered(cue) {
                return (cue, .answered)
            }
            if !focusAssigned {
                focusAssigned = true
                return (cue, .focus)
            }
            return (cue, .recent)
        }
    }
}
```
```swift
// VoiceInk/Views/MeetingCopilot/CopilotOverlayView.swift
import SwiftUI

/// 隱蔽 overlay 的內容(FR-26)。繁中字面,不進 xcstrings(近期新頁面慣例)。
///
/// 三層漸進渲染(M3 回寫在 `MeetingLiveCue` 上的欄位;`…Raw` 欄位以換行分隔):
///   Tier 0 關鍵字(tier0Keywords,立即) → Tier 1 opener + 3 bullets(串流中逐步)
///   → Tier 2 analysis + followUps + uncertainties(點擊後)。
/// panel 是 oversized host(MiniRecorderPanel idiom)——可視大小由本 view 的卡片決定。
struct CopilotOverlayView: View {
    @ObservedObject var controller: MeetingCopilotController
    @ObservedObject private var config = MeetingCopilotConfigStore.shared
    /// 點一則 cue → 觸發 Tier 2(接 M3 AnswerCoordinator;click-through 開啟時自然不會觸發)。
    var onCueTapped: ((MeetingLiveCue) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sharingBoundaryBanner

            let arranged = CopilotOverlayArranger.arrange(
                controller.cues,
                askedAt: { $0.askedAt },
                isAnswered: { $0.status == .answered },
                maxCount: config.maxCuesShown
            )

            if arranged.isEmpty {
                Text("等待對方開口…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(arranged.enumerated()), id: \.element.cue.id) { _, item in
                    cueRow(item.cue, emphasis: item.emphasis)
                        .contentShape(Rectangle())
                        .onTapGesture { onCueTapped?(item.cue) }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxHeight: .infinity, alignment: .top)   // 內容貼齊 host 上緣 = 近鏡頭
        .colorScheme(.dark)
    }

    /// 🔴 FR-22 誠實註記的落地:常駐、不可關閉。文案不得軟化。
    private var sharingBoundaryBanner: some View {
        Label("分享「整個螢幕」時此視窗會被錄到（macOS 15.4+）。安全作法：只分享單一視窗/分頁。",
              systemImage: "eye.trianglebadge.exclamationmark")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.yellow)
            .lineLimit(2)
    }

    @ViewBuilder
    private func cueRow(_ cue: MeetingLiveCue, emphasis: CopilotOverlayEmphasis) -> some View {
        switch emphasis {
        case .focus:
            VStack(alignment: .leading, spacing: 6) {
                Text(cue.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                // Tier 1:opener 是唯一必讀項 → 最大字級單獨呈現(FR-26)
                if !cue.tier1Opener.isEmpty {
                    Text(cue.tier1Opener)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(lines(cue.tier1BulletsRaw), id: \.self) { bullet in
                        Text("• \(bullet)")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                } else if !cue.tier0Keywords.isEmpty {
                    // Tier 0:LLM 還沒回來之前,先給關鍵字撐場(<0.5s)
                    Text(cue.tier0Keywords)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                // Tier 2:點擊後才有(M3);有就顯示
                if !cue.tier2Analysis.isEmpty {
                    Divider()
                    Text(cue.tier2Analysis)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(lines(cue.tier2FollowUpsRaw), id: \.self) { q in
                        Text("↩︎ \(q)").font(.system(size: 12)).foregroundStyle(.cyan)
                    }
                    ForEach(lines(cue.tier2UncertaintiesRaw), id: \.self) { u in
                        Text("⚠ \(u)").font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
            }
            .padding(.vertical, 4)

        case .recent:
            Text(cue.text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)

        case .answered:
            Text(cue.text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
                .strikethrough()
                .lineLimit(1)
        }
    }

    private func lines(_ raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}
```

- **MIRROR**: `TEST_STRUCTURE`；oversized-host + SwiftUI 控可視大小 = `MiniRecorderPanel` idiom（recon-windows.md:191）

- **VALIDATE**:
  1. `-only-testing:VoiceInkTests/CopilotOverlayArrangerTests` — **PASS**（5 測試全綠）
  2. compile gate（view 引用 M2/M3 欄位——`cue.status`、tier 欄位型別若與 M2/M3 實作有出入，**以實作為準調整 view，不改 arranger**）

- **GOTCHA**: `MeetingLiveCue.status` 在 M2 是 raw-string 包 computed enum（`statusRaw`）——`$0.status == .answered` 的確切寫法以 M2 落地為準；若 M3 未引入 `answered` 狀態值，focus 判定退化為「最新一則」，arranger 不用改（`isAnswered` closure 回 false 即可）。

- **COMMIT**: `feat(meeting-copilot): CopilotOverlayView + arranger — tiered progressive rendering (FR-26)`

---

### Task 7: CopilotOverlayWindowManager — show/hide/toggle/peek + 近鏡頭定位（FR-21/24/25）

**Files:**
- Create: `VoiceInk/Views/MeetingCopilot/CopilotOverlayWindowManager.swift`
- Test:   `VoiceInkTests/CopilotOverlayWindowManagerTests.swift`

- **ACTION**: 生命週期照抄 `MeetingIndicatorWindowManager`（retain + `NSHostingController`），**但 `show()` 每次重算 + `setFrame`**（發現 3）；錨定螢幕上方中央（近鏡頭），優先會議 app 所在螢幕、退回 `NSScreen.main`；`didChangeScreenParametersNotification` 0.1s debounce 重算；`CopilotPeekGuard` 複製 push-to-talk 守衛；`onLocalLevel` → `OverlayDimmingModel` → `panel.alphaValue`。

- **TEST FIRST**:
```swift
// VoiceInkTests/CopilotOverlayWindowManagerTests.swift
import XCTest
@testable import VoiceInk

final class CopilotOverlayWindowManagerTests: XCTestCase {

    // MARK: - FR-24:近鏡頭錨定(純函式)

    /// 螢幕上方中央:水平置中、貼齊 visibleFrame 上緣(留 12pt)。
    func testAnchorRectIsTopCenter() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let size = NSSize(width: 560, height: 400)
        let rect = CopilotOverlayWindowManager.anchorRect(visibleFrame: visible, size: size)

        XCTAssertEqual(rect.midX, 960, accuracy: 0.5, "水平置中")
        XCTAssertEqual(rect.maxY, 1080 - 12, accuracy: 0.5, "貼齊上緣(近鏡頭),留 12pt")
        XCTAssertEqual(rect.size, size)
    }

    /// 非零原點螢幕(多螢幕排列的第二台)也正確。
    func testAnchorRectOnSecondaryScreenOrigin() {
        let visible = NSRect(x: 1920, y: 200, width: 1440, height: 900)
        let rect = CopilotOverlayWindowManager.anchorRect(
            visibleFrame: visible, size: NSSize(width: 560, height: 400))

        XCTAssertEqual(rect.midX, 1920 + 720, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, 200 + 900 - 12, accuracy: 0.5)
    }

    // MARK: - peek 守衛(複製 push-to-talk 的 isShortcutPressed + 0.5s cooldown 語意)

    /// 按住一鍵 → key-repeat 連發 keyDown,只有第一發生效。
    func testKeyRepeatDoesNotRetrigger() {
        var guard_ = CopilotPeekGuard()
        XCTAssertTrue(guard_.registerKeyDown(at: 0.0), "第一發:顯示")
        XCTAssertFalse(guard_.registerKeyDown(at: 0.05), "repeat:忽略")
        XCTAssertFalse(guard_.registerKeyDown(at: 0.10), "repeat:忽略")
        XCTAssertTrue(guard_.registerKeyUp(), "放開:隱藏")
    }

    /// 放開後 0.5s 內再按 → cooldown 擋掉(比照 shortcutPressCooldown)。
    func testCooldownBlocksRapidRepress() {
        var guard_ = CopilotPeekGuard()
        XCTAssertTrue(guard_.registerKeyDown(at: 0.0))
        XCTAssertTrue(guard_.registerKeyUp())
        XCTAssertFalse(guard_.registerKeyDown(at: 0.3), "0.3s < 0.5s cooldown")
        XCTAssertFalse(guard_.registerKeyUp(), "沒 show 過就不 hide")
        XCTAssertTrue(guard_.registerKeyDown(at: 0.6), "cooldown 過了")
    }

    /// 未按下時收到 keyUp(例如 cooldown 吃掉了 keyDown)→ 不觸發 hide。
    func testOrphanKeyUpIsIgnored() {
        var guard_ = CopilotPeekGuard()
        XCTAssertFalse(guard_.registerKeyUp())
    }
}
```
  Run: `-only-testing:VoiceInkTests/CopilotOverlayWindowManagerTests` — expect **FAIL**

- **IMPLEMENT**:
```swift
// VoiceInk/Views/MeetingCopilot/CopilotOverlayWindowManager.swift
import AppKit
import SwiftUI
import os

/// peek 熱鍵的 press-and-hold 守衛。**語意複製 push-to-talk**
/// (`RecordingShortcutModeHandler.handleKeyDown`,RecordingShortcutManager.swift:272-279):
/// `isShortcutPressed` 擋 key-repeat auto-fire、0.5s cooldown 擋短時間重觸。
/// 按住一鍵時 CGEvent tap 會連發 keyDown——沒有這兩個守衛,overlay 會被連續 show 轟炸。
struct CopilotPeekGuard {
    private var isPressed = false
    private var lastPressAt: TimeInterval = -.infinity
    let cooldown: TimeInterval = 0.5

    /// keyDown 抵達。回 true = 第一次按下,執行 show。
    mutating func registerKeyDown(at eventTime: TimeInterval) -> Bool {
        guard !isPressed else { return false }                     // key-repeat
        guard eventTime - lastPressAt >= cooldown else { return false }
        isPressed = true
        lastPressAt = eventTime
        return true
    }

    /// keyUp 抵達。回 true = 有對應的 show,執行 hide。
    mutating func registerKeyUp() -> Bool {
        guard isPressed else { return false }
        isPressed = false
        return true
    }
}

/// overlay 的 show/hide/toggle/peek 與定位(FR-21/24/25)。
///
/// 生命週期照抄 `MeetingIndicatorWindowManager`(strong panel + strong windowController
/// 純為 retain;hide 只 orderOut,panel 重用)——**但不抄它的 frozen-frame bug**:
/// `show()` 每次重算 metrics + `setFrame`(比照 `NotchRecorderPanel.show()`)。
///
/// 焦點契約:panel `canBecomeKey=false` + 只用 `orderFrontRegardless()`——從不搶焦點,
/// 因此**不需要也不得**套 DictionaryQuickAddPanel 的 previousApp save/restore。
@MainActor
final class CopilotOverlayWindowManager {

    static let shared = CopilotOverlayWindowManager()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private var windowController: NSWindowController?
    private var panel: CopilotOverlayPanel?
    private weak var controller: MeetingCopilotController?
    private var onCueTapped: ((MeetingLiveCue) -> Void)?

    private var dimming = OverlayDimmingModel()
    private var peekGuard = CopilotPeekGuard()

    /// toggle 熱鍵釘住的狀態。peek 放開時只在「未釘住」才隱藏。
    private(set) var isPinned = false

    /// 接線點:M2 建立 `MeetingCopilotController` 與 M1 `MeetingLiveTranscriber` 之處呼叫
    /// (以 M2/M3 report 記載的建構點為準)。`onLocalLevel` 必須在 transcriber.start() 前掛上
    /// (pump 啟動時定格 closure,見 MeetingLiveTranscriber.onLocalLevel 文檔)。
    func configure(
        controller: MeetingCopilotController,
        transcriber: MeetingLiveTranscriber?,
        onCueTapped: ((MeetingLiveCue) -> Void)? = nil
    ) {
        self.controller = controller
        self.onCueTapped = onCueTapped
        transcriber?.onLocalLevel = { [weak self] rms in
            self?.applyLocalLevel(rms)
        }
    }

    // MARK: - 熱鍵入口(RecordingShortcutManager 呼叫)

    /// `.toggleMeetingCopilotOverlay`(keyUp-only,比照 .toggleMeetingRecording)。
    func toggle() {
        if isPinned {
            isPinned = false
            hide()
        } else {
            isPinned = true
            show()
        }
    }

    /// `.peekMeetingCopilotOverlay` 的 keyDown(顯式 branch,見 Task 8)。
    func peekKeyDown(at eventTime: TimeInterval) {
        guard peekGuard.registerKeyDown(at: eventTime) else { return }
        show()
    }

    /// `.peekMeetingCopilotOverlay` 的 keyUp(handleGlobalShortcut 分派)。
    func peekKeyUp() {
        guard peekGuard.registerKeyUp() else { return }
        if !isPinned { hide() }
    }

    // MARK: - 視窗生命週期

    func show() {
        if panel == nil { initializeWindow() }
        guard let panel else { return }
        // 每次 show 重算(發現 3:不得繼承 MeetingIndicatorWindowManager 的 frozen-frame bug)
        panel.setFrame(Self.calculateWindowMetrics(), display: true)
        // click-through 設定可能在兩次 show 之間被改(M5 UI)——每次 show 套用
        panel.ignoresMouseEvents = MeetingCopilotConfigStore.shared.overlayClickThrough
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()          // 絕不 makeKeyAndOrderFront(不搶焦點)
    }

    func hide() {
        panel?.orderOut(nil)                  // panel 保留重用,不 close()
    }

    private func initializeWindow() {
        guard let controller else {
            // M2 尚未接線 → 靜默(log-only;NotificationManager 對本模組三重失格)
            logger.error("🫥 overlay show requested but MeetingCopilotController not configured")
            return
        }
        let metrics = Self.calculateWindowMetrics()
        let newPanel = CopilotOverlayPanel(
            contentRect: metrics,
            clickThrough: MeetingCopilotConfigStore.shared.overlayClickThrough
        )
        let hosting = NSHostingController(
            rootView: CopilotOverlayView(controller: controller, onCueTapped: onCueTapped)
        )
        newPanel.contentView = hosting.view
        newPanel.setFrame(metrics, display: true)
        panel = newPanel
        windowController = NSWindowController(window: newPanel)

        // 螢幕插拔/解析度變更 → 重算(照抄 NotchRecorderPanel:0.1s debounce,
        // 同步讀 NSScreen 會拿到 stale 幾何)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            panel.setFrame(Self.calculateWindowMetrics(), display: true)
        }
    }

    // MARK: - FR-25:說話淡出

    private func applyLocalLevel(_ rms: Float) {
        guard let panel, panel.isVisible else { return }
        dimming.speakingOpacity = MeetingCopilotConfigStore.shared.speakingOpacity
        let target = CGFloat(dimming.update(rms: rms, at: ProcessInfo.processInfo.systemUptime))
        guard abs(panel.alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = target
        }
    }

    // MARK: - FR-24:近鏡頭定位

    /// oversized host(MiniRecorderPanel idiom)——可視卡片大小由 SwiftUI 決定。
    static let overlaySize = NSSize(width: 560, height: 400)

    /// 螢幕上方中央 = 近鏡頭:讀 overlay 時視線最接近鏡頭,對方看起來仍在看鏡頭。
    static func anchorRect(visibleFrame: NSRect, size: NSSize = overlaySize) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 12,
            width: size.width,
            height: size.height
        )
    }

    static func calculateWindowMetrics() -> NSRect {
        let screen = meetingAppScreen() ?? NSScreen.main
        guard let screen else {
            return NSRect(origin: .zero, size: overlaySize)
        }
        return anchorRect(visibleFrame: screen.visibleFrame)
    }

    /// 優先會議 app 所在螢幕(FR-24)。用 CGWindowList 找已知會議 app 的 on-screen 視窗,
    /// 取其中點所在的 NSScreen。找不到(含 Meet-in-browser,無法與一般分頁區分)→ nil,
    /// 呼叫端退回 `NSScreen.main`——對 menu-bar app 而言那通常就是前景會議視窗的螢幕
    /// (recon-windows.md:460,incidental 但堪用)。
    private static let meetingAppOwnerNames: Set<String> = [
        "Microsoft Teams", "MSTeams", "zoom.us", "Zoom", "Webex", "FaceTime"
    ]

    static func meetingAppScreen() -> NSScreen? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for entry in info {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  meetingAppOwnerNames.contains(owner),
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 200, bounds.height > 200   // 略過縮圖/工具列碎視窗
            else { continue }

            // CGWindow 座標是 top-left 原點;NSScreen 是 bottom-left。以主螢幕高度翻轉 y。
            guard let primary = NSScreen.screens.first else { return nil }
            let flippedMidY = primary.frame.maxY - bounds.midY
            let midPoint = NSPoint(x: bounds.midX, y: flippedMidY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(midPoint) }) {
                return screen
            }
        }
        return nil
    }
}
```

- **MIRROR**: `WINDOW_MANAGER_LIFECYCLE`（retain / hide-orderOut / NSHostingController）+ `SHOW_RECOMPUTE_AND_SCREEN_CHANGE`（每次 show 重算 + 0.1s debounce）+ `PUSH_TO_TALK_GUARDS`（`CopilotPeekGuard` 語意）

- **VALIDATE**: `-only-testing:VoiceInkTests/CopilotOverlayWindowManagerTests` — **PASS**（5 測試全綠）+ compile gate

- **GOTCHA**:
  - `CGWindowListCopyWindowInfo` 讀他 app 視窗**名稱/幾何**不需要 Screen Recording 權限（讀 `kCGWindowName` 內容才要）——這裡只用 owner name + bounds，安全。
  - Meet 跑在瀏覽器裡，無法從 owner name 區分「開會的 Chrome」與「查資料的 Chrome」——**刻意不猜**，退回 `NSScreen.main`。
  - `configure` 的呼叫點在 M2 建構 `MeetingCopilotController` 之處——實作時以 M2 report 的接線位置為準補一行；`controller` 為 nil 時 show() log-only 靜默（不彈任何可見 UI）。

- **COMMIT**: `feat(meeting-copilot): CopilotOverlayWindowManager — near-camera anchoring + peek guard (FR-21/24/25)`

---

### Task 8: 熱鍵 dispatch 接線 — peek 的 keyDown branch + toggle 的 keyUp case

**Files:**
- Modify: `VoiceInk/Shortcuts/RecordingShortcutManager.swift`

> 守衛邏輯已在 Task 7 測死（`CopilotPeekGuard`）；本 task 是純接線，gate 是 compile + 既有熱鍵測試零回歸 + 人工實鍵驗證（Task 9）。

- **TEST FIRST**: 無新自動化測試（CGEvent tap 需 Input Monitoring 權限與真實鍵盤事件，headless 不可測——與既有熱鍵系統一致，repo 對此層本無單元測試）。gate＝compile + `MeetingShortcutTests` 迴歸 + Task 9 人工驗證。

- **IMPLEMENT**:
  1. `refreshShortcutMonitor` 的 `onKeyDown` 閉包（`RecordingShortcutManager.swift:213-223`）——在 `guard let mode` **之前**加顯式 branch（發現 4：`recordingMode(for:)` 對兩新 action 回 nil，keyDown 會被既有 swallow 丟掉，peek 必須搶在前面）:
```swift
        onKeyDown: { [weak self] action, eventTime in
            Task { @MainActor in
                guard let self else { return }
                // peek:按下顯示(keyUp 隱藏走 handleGlobalShortcut)。
                // ⚠️ 不得改用 recordingMode(for:) 路由——那會把事件送進
                // RecordingShortcutModeHandler(迷你錄音面板的聽寫 push-to-talk),目標錯誤。
                if action == .peekMeetingCopilotOverlay {
                    CopilotOverlayWindowManager.shared.peekKeyDown(at: eventTime)
                    return
                }
                guard let mode = self.recordingMode(for: action) else { return }
                await self.shortcutModeHandler.handleKeyDown(
                    action: action,
                    eventTime: eventTime,
                    mode: mode
                )
            }
        },
```
  2. `handleGlobalShortcut`（`:314-366`，有 `default: break`）——`.toggleMeetingRecording` case 之後加兩個 case（樣式照抄 `GLOBAL_KEYUP_DISPATCH`）:
```swift
    case .toggleMeetingCopilotOverlay:
        // overlay 與聽寫/會議錄製狀態機解耦——keyUp-only,樣式比照 .toggleMeetingRecording。
        CopilotOverlayWindowManager.shared.toggle()
    case .peekMeetingCopilotOverlay:
        // press-and-hold 的放開端(keyDown 端在 refreshShortcutMonitor 的顯式 branch)。
        CopilotOverlayWindowManager.shared.peekKeyUp()
```

- **MIRROR**: `KEYDOWN_SWALLOW`（插點）+ `GLOBAL_KEYUP_DISPATCH`（case 樣式）

- **VALIDATE**:
  1. compile gate（零錯誤零新警告）
  2. `-only-testing:VoiceInkTests/MeetingShortcutTests` — **PASS**（熱鍵資料層零回歸）
  3. 快速人工煙測（實鍵驗證在 Task 9 全套做）：`make deploy`（**人工執行**）→ 用 DEBUG 或 `defaults` 先寫入兩鍵（或待 M5 的 UI）→ 按 toggle 鍵 overlay 出現、再按消失

- **GOTCHA**: `onKeyUp` 閉包**不用改**——else-path 本來就把 `recordingMode == nil` 的 action 全送進 `handleGlobalShortcut`。`toggleMeetingCopilotOverlay` 的 keyDown 則被既有 `guard let mode` swallow，正是要的 keyUp-only 行為——**不要**為它加 keyDown branch。

- **COMMIT**: `feat(meeting-copilot): wire overlay toggle + press-and-hold peek hotkeys (FR-21)`

---

### Task 9: Bump build 251 + 全套迴歸 + 人工 gate（含 AC-15 三情境）

**Files:**
- Modify: `VoiceInk.xcodeproj/project.pbxproj`（`CURRENT_PROJECT_VERSION` 250 → **251**，**Debug + Release 兩處都要**——:508 與 :542 那兩個 target；:571/:589 的 `= 1` 是別的 target 不要動）

- **ACTION**: 收尾 + 本 milestone 的人工驗證（overlay 是視覺/焦點/擷取行為，自動化只能鎖屬性，行為要實機）。

- **VALIDATE**:
  1. **全套測試**（不只新的——確認零回歸，特別是 M1 `MeetingCopilotReplayTests`、M2/M3 的 controller/coordinator 測試、既有 `Recorder*` 測試）:
     ```bash
     xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
       -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
       -xcconfig LocalBuild.xcconfig \
       CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
       CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
       SWIFT_ENABLE_EXPLICIT_MODULES=NO
     ```
     EXPECT: **全綠**
  2. `grep -c "CURRENT_PROJECT_VERSION = 251" VoiceInk.xcodeproj/project.pbxproj` → **2**
  3. **回報 build 號給使用者**（專案記憶 `voiceink-report-build-number`），提醒 `make deploy` 由使用者自己跑（**不要自動 deploy、不要 build 進 /tmp**），Settings → About 確認 build 251
  4. **人工 gate**（`make deploy` 後，按下方手動驗證清單逐項執行；**AC-15 三情境必做**）

- **COMMIT**: `chore: bump build to 251 (meeting-copilot M4)`

---

## Testing Strategy

### Unit Tests

| Test | Input | Expected | Edge? |
|---|---|---|---|
| `MeetingShortcutTests::testMeetingRecordingShortcutParticipatesInConflictDetection` | 設鍵給 meeting-recording 再驗同鍵 | `.alreadyUsedBy` | 🔴 FR-32 / AC-19 |
| `MeetingShortcutTests::testNewActionsAreGlobalUtilityActions` | — | tap 監看清單含兩新 action | — |
| `CopilotOverlayConfigTests::testOverlayDefaults` | 清空 defaults | false / 0.35 / 5 | — |
| `CopilotOverlayConfigTests::testSpeakingOpacityIsClamped` | 0.0 / 2.0 | 0.05 / 1.0 | ✅ |
| `OverlayDimmingTests::testDimsWhileLocalStreamActive` | RMS 0.5 | 0.35 | 🔴 AC-17 |
| `OverlayDimmingTests::testRecoversAfterOnePointFiveSecondsOfSilence` | 靜音 1.49s / 1.51s | 0.35 / 1.0 | 🔴 AC-17 |
| `OverlayDimmingTests::testBelowThresholdNoiseDoesNotDim` | RMS 0.019 | 1.0 | ✅ |
| `MeetingLocalLevelTests::testOnLocalLevelReportsPositiveRMSWhileSpeaking` | replay 正弦 WAV | RMS > 0.1 回報 | 🔴 FR-25 |
| `MeetingLocalLevelTests::testSilentLocalReportsNearZeroRMS` | 靜音 WAV + `localStream=nil` | RMS < 0.02，照常回報 | ✅ |
| `CopilotOverlayPanelTests::testCanBecomeKeyIsFalse` | — | key/main 皆 false | 🔴 AC-16 |
| `CopilotOverlayPanelTests::testSharingTypeIsNone` | — | `.none` | 🔴 FR-22 |
| `CopilotOverlayPanelTests::testClickThroughAndImmovability` | 兩種參數 | 穿透依參數；不可拖 | ✅ |
| `CopilotOverlayArrangerTests::testNewestUnansweredIsFocusAndFirst` | 3 則亂序 | 由新到舊、單一 focus | 🔴 FR-26 |
| `CopilotOverlayArrangerTests::testAnsweredCueIsDimmedAndFocusSkipsIt` | 最新已回答 | focus 給次新未回答 | ✅ |
| `CopilotOverlayWindowManagerTests::testAnchorRectIsTopCenter` | 1920×1080 | 上方置中留 12pt | 🔴 FR-24 |
| `CopilotOverlayWindowManagerTests::testKeyRepeatDoesNotRetrigger` | 連發 keyDown | 只第一發 show | 🔴 AC-16 守衛 |
| `CopilotOverlayWindowManagerTests::testCooldownBlocksRapidRepress` | 0.3s 內重按 | 擋下 | ✅ |

### Edge Cases Checklist
- [x] 空 cue 清單 / maxCount 0（arranger）
- [x] 全部 cue 已回答 → 無 focus
- [x] speakingOpacity / maxCuesShown 超界 clamp
- [x] 靜音 local 不誤觸發淡出；`localStream=nil` 淡出照常
- [x] key-repeat 連發 keyDown；cooldown 內重按；孤兒 keyUp
- [x] 非零原點的第二螢幕 anchorRect
- [ ] **Input Monitoring 未授權 → tap 靜默未裝**（發現 8）——只有人工可驗
- [ ] **macOS 15.4+ 分享整螢幕 → overlay 被錄到**——AC-15 人工 gate，預期行為

---

## Validation Commands

### 編譯（快速 gate，不啟動 host）
```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  CODE_SIGNING_ALLOWED=NO SWIFT_ENABLE_EXPLICIT_MODULES=NO build
```
EXPECT: 零錯誤。（Task 1 加 enum case 後，此 gate 會揪出所有漏掉的 exhaustive switch arm。）

### 單元測試（**必須用這個完整形式**，見專案記憶 `voiceink-running-unit-tests`）
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

> 🔴 **為什麼不能用普通 `xcodebuild test`**：`VoiceInkTests` 是 **host-app** bundle，runner 會啟動 `VoiceInk.app`。未簽章時 SwiftData 的 CloudKit store 令 host **開機即 crash**（`_os_crash`）。上面的完整形式鏡射 `make local`。`SWIFT_ENABLE_EXPLICIT_MODULES=NO` 亦必要（Xcode 16+ `@testable import`）。**`-only-testing` 仍會編譯所有測試檔**——任一檔編譯錯誤 = 整輪失敗。

### 部署（**人工執行，不要自動跑**）
```bash
make deploy
```
> 專案記憶 `voiceink-build-no-ghost-apps`：**不要 build 進 /tmp**。不自動 deploy——使用者自己跑，Settings → About 確認 build 251。

### 手動驗證（人工 gate — deploy 後逐項）

**AC-15：螢幕分享排除，三情境實機 🔴（本 milestone 的 go/no-go 誠實檢查，需第二台裝置或錄下接收端畫面存證）**
- [ ] 情境 (c) **Chrome/Meet 分享單一視窗**：overlay 顯示中 → 對方畫面**不含** overlay，且 overlay **不出現在**分享視窗選擇器
- [ ] 情境 (a) **Teams 原生 app 分享整個螢幕**：macOS 15.4+ **預期 overlay 被錄到**——確認警告條有呈現且文案誠實，**不視為 bug**
- [ ] 情境 (b) **Chrome/Meet `getDisplayMedia` 分享整個螢幕**：同上，預期被錄到，警告條誠實
- [ ] 任何結果與上述預期不符（例如情境 c 也被錄到）→ **停下來回報**，功能前提需重新評估

**AC-16：peek + 不搶焦點**
- [ ] Teams 前景、游標在輸入框 → **按住** peek 鍵：overlay 顯示、Teams 仍前景、輸入框游標還在、繼續打字不中斷
- [ ] 放開 → overlay 立即隱藏；按住期間 key-repeat 不造成閃爍/重複 show
- [ ] toggle 鍵：按一下顯示（釘住）、再按隱藏；釘住時按住又放開 peek → overlay **不**消失（pinned 優先）

**AC-17：說話淡出（實機半部；自動化半部在 `OverlayDimmingTests`）**
- [ ] overlay 顯示中對麥克風說話 → 淡至約 35% 不透明；停止說話約 1.5s 後恢復
- [ ] 喇叭外放（不戴耳機）時對方聲音可能誤觸發淡出——已知限制（umbrella SRS Risks），記錄實測感受供門檻調校

**其他**
- [ ] overlay 錨在會議 app 所在螢幕的上方中央；拔/插外接螢幕後位置重算正確
- [ ] 全螢幕 Teams/Meet 之上 overlay 仍可見（`.fullScreenAuxiliary`）
- [ ] `overlayClickThrough = false` 時點一則 cue 可觸發 Tier 2；`= true` 時滑鼠事件穿透到下層
- [ ] overlay 顯示時聽寫 → notch pill 被 overlay 蓋住（已接受取捨，發現 6）——記錄實際體感，若不可接受回報改 `.statusBar + 4`
- [ ] **Input Monitoring 檢查**（發現 8）：若兩熱鍵完全無反應，System Settings → Privacy → Input Monitoring 確認 VoiceInk 已授權
- [ ] 衝突偵測：把 meeting-recording 已用的鍵錄給其他動作 → 被拒且顯示「already used by」

---

## Acceptance Criteria

- [ ] **AC-16**（不搶焦點 + peek）：`CopilotOverlayPanelTests` + `CopilotOverlayWindowManagerTests`（守衛）綠；人工按住/放開與焦點驗證通過
- [ ] **AC-17**（說話淡出）：`OverlayDimmingTests` + `MeetingLocalLevelTests` 綠；實機淡出/恢復可感
- [ ] **AC-15**（螢幕分享排除）：**人工 gate** 三情境完成並存證——情境 (c) 排除成功；情境 (a)(b) 被錄到屬預期，警告條誠實呈現
- [ ] **AC-19（資料層半部）**：`MeetingShortcutTests` 綠——三個會議熱鍵皆參與衝突偵測（FR-32）；UI row 留 M5
- [ ] FR-21~FR-26、FR-32 全數落地（見各 task 的 FR 標註）
- [ ] 全套測試零回歸（M1/M2/M3 的 Meeting* 測試全綠）
- [ ] 編譯零錯誤、零新警告
- [ ] Build 251，已回報給使用者

## Completion Checklist
- [ ] panel 屬性照 clone base + 四項加料，**不含** `makeKeyAndOrderFront` / focus save/restore / `NotificationManager` 任何呼叫
- [ ] `show()` 每次重算 + `setFrame`（frozen-frame bug 未被繼承）
- [ ] peek **不在** `recordingMode(for:)` 內（發現 4 陷阱未踩）
- [ ] 警告條常駐且文案未軟化（「分享整個螢幕會被錄到」字樣在）
- [ ] 三個 exhaustive switch 都有新 arm；`legacyKeyboardShortcutActions` 含三個會議 action
- [ ] 失敗路徑全部 log-only（grep 新檔無 `NotificationManager`）
- [ ] 沒有超出 M4 範圍的新增（無 ShortcutRecorder row / 無設定頁 / 無 ViewType case / 無 SSE / 無 cue 邏輯）

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **macOS 15.4+ 分享整螢幕時 overlay 被錄到** | **確定發生**（OS 行為） | **H** — 對方看到 copilot 存在 | 無技術解（Apple DTS 明言）。警告條常駐 + M5 設定頁明示 + AC-15 人工驗證警告條誠實；使用者教育:分享單一視窗/分頁 |
| `sharingType=.none` 首次 Swift 使用,三條擷取路徑行為未經 repo 驗證 | M | H | AC-15 三情境實機 gate;任何情境與預期不符即停下回報 |
| Input Monitoring 未授權 → 熱鍵靜默不觸發（發現 8） | M | M | 手動驗證清單含權限檢查;列入已知缺口,提示改造屬後續（不在 M4） |
| M2/M3 實際落地的型別面與本 plan 引用有出入（plan 先於實作寫成） | M | M | Task 0 精神:開工先讀 M2/M3 report 對齊;差異只調 view/接線,不動已測純函式 |
| `.screenSaver` 蓋住 notch pill（發現 6） | 確定 | L | 已接受取捨;體感差時單行改 `.statusBar + 4`（手動驗證有記錄項） |
| 會議 app 螢幕偵測誤判（多螢幕 + 多會議視窗） | L | M | 找不到/不確定一律退 `NSScreen.main`（對 menu-bar app 通常=會議螢幕）;不做即時跟隨 |
| 喇叭外放時對方聲音誤觸發淡出 | M | L | 已知限制（umbrella SRS）;門檻 0.02 為初值,實測記錄供調校;overlay 只是變淡非消失 |
| host-app 測試在 CI/headless 掛掉 | H | M | 完整 `xcodebuild test` 形式（記憶）;所有新測試不碰 CoreAudio/CGEvent tap |

## Notes

- **本 milestone 依賴 M2（cue 偵測引擎，build 249）與 M3（三層回應引擎，build 250）先行實作完成**——M4 的 view 直接讀 M2 的 `MeetingCopilotController.@Published cues` 與 M3 回寫在 `MeetingLiveCue` 上的 tier 欄位，`configure(...)` 的接線點也在 M2 的建構位置。依賴鏈：M1（已完成，build 248）→ M2 → M3 → **M4** → M5（管理頁 + 設定 UI，含兩熱鍵與 `.toggleMeetingRecording` 的 `ShortcutRecorder` row、三項 overlay 設定的 UI）。
- **誠實邊界是交付的一部分**：警告條、AC-15 的「(a)(b) 被錄到＝預期」、以及所有文件不宣稱無條件隱形——這些與程式碼同等重要，review 時逐字檢查文案。
- `OverlayDimmingModel` 的門檻 0.02 與 `CopilotPeekGuard` 的 0.5s cooldown 都是初值——前者待實機調校（喇叭情境），後者鏡射既有 `shortcutPressCooldown`。
