---
linear_issue: null
---
# SRS: Meeting Copilot M11 — 會議開始偵測（開會了卻沒在錄音 → 提示）

## Metadata
- **Module**: `meeting-copilot`（會議錄製入口的守望者；與 live pipeline 零耦合，見範圍界線）
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source PRD**: N/A（2026-07-16 使用者需求；可行性討論同日定案：A+B 雙訊號整合）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-16
- **Grill level**: 1（標準）
- **實作交接**: 本文件寫給**新的實作 session**（使用者指定換 Opus 模型實作）。文末
  「Implementation Handoff」一節是給實作者的入場須知，實作前先讀。

## Feature Summary

偵測「會議已經開始，但 VoiceInk 沒在錄會議」，跳一則帶動作按鈕的 app 內通知
（「開始會議錄製」），一鍵補救。動機：使用者常忘了按會議錄製熱鍵，等想起來已經錄丟半場。

整合兩個訊號（2026-07-16 討論定案，A+B 一起做）：

- **訊號 A（主訊號）— CoreAudio process 麥克風偵測**：macOS 14+ 的 CoreAudio process-object
  API 可列出正在使用音訊的行程、查 bundle id、以及**該行程是否正在收麥克風**
  （`kAudioProcessPropertyIsRunningInput`）。「允許清單內的 app 開著麥克風」是「你在會議中」
  的最強訊號——Meet/Teams 的 app 內靜音是軟體靜音，mic stream 通常仍開著，按了靜音照樣偵測得到。
  選 mic 不選喇叭：放 YouTube 也有輸出，只有 mic 能區分「在開會」與「在看影片」。
- **訊號 B（瀏覽器的第二把鑰匙）— 視窗標題確認**：對原生會議 app（Teams/Zoom），訊號 A 單獨
  就夠準；對瀏覽器（Google Meet 都在瀏覽器裡跑），A 只能說「某分頁在用麥克風」——可能是 Meet，
  也可能是網頁語音輸入。所以瀏覽器路徑必須再命中一個會議視窗標題（`CGWindowListCopyWindowInfo`
  讀 `kCGWindowName`，如「Meet – abc-defg-hij」「… | Microsoft Teams」）才觸發。

## 整合決策規則（本 SRS 的核心，實作不得偏離）

| 音訊來源 | 觸發條件 | 理由 |
|---|---|---|
| 原生會議 app（Teams / Zoom…允許清單） | mic 持續收音 ≥ debounce（預設 3s） | app 本身就是會議軟體，mic 開 = 在會議（含等候室/預覽，此時提示正是最佳時機） |
| 瀏覽器（Chrome / Edge / Arc / Brave / Firefox / Safari / Vivaldi 家族） | mic 持續收音 ≥ debounce **且** 同家族瀏覽器存在命中會議標題 pattern 的視窗（≥200×200pt） | 單靠 mic 會把網頁語音輸入誤判成會議；單靠標題會把「開著 Meet 分頁沒入會」誤判 |
| 其他任何行程 | 永不觸發 | Discord 這類常駐開 mic 的 app 不在允許清單，天然排除 |

抑制與一次性（防騷擾，優先權由上到下）：

1. `MeetingCaptureController.isRecording == true` → 全程靜默；錄音開始時把**當下所有**偵測
   session 標記 consumed（使用者中途手動停錄不會被馬上追著提示）。
2. 每個「mic session」（同 bundle id 連續收音期間）**最多提示一次**；mic 停 ≥ rearm（預設 30s）
   才視為新 session、可再提示。
3. 全域冷卻 60s：Teams app 與瀏覽器同時開會（幾乎必是同一場）只提示一次，冷卻窗內其他觸發
   直接標 consumed（不是延後——延後等於變相提示兩次）。
4. 偵測到但被抑制的每一步都留 log（見 FR-92），調校誤報/漏報時才有線索。

**只提示、永不自動開錄**：誤觸自動開錄=錄到非會議內容的隱私事故＋copilot token 白燒。
按下通知的「開始會議錄製」才真的 `MeetingCaptureController.start()`。此界線不得放寬。

## 範圍界線

- **不接 live pipeline**：偵測器不建立/不引用 `MeetingCopilotController` / `MeetingLiveTranscriber` /
  `AnswerCoordinator`，唯一的動作出口是通知按鈕呼叫 `MeetingCaptureController.shared.start()`。
- **不讀任何音訊內容**：訊號 A 只讀 process 的中繼資料（bundle id、是否收音），**不建 tap、
  不碰 PCM**——`AudioHardwareCreateProcessTap` 需要 TCC，但本功能完全不呼叫它。
- **不持久化視窗標題**：標題只在記憶體內做 pattern 比對，log 只記「命中/未命中＋app 名」，
  不記標題內容（標題可能含會議名等敏感資訊）。
- **偵測是 best-effort 提醒，不是保證**：標題 pattern 綁 Meet/Teams 現行格式（產品改版會失效）；
  設定頁與文件不得宣稱「所有會議都會被偵測到」。

## Delta from Current Module State

> 現況見 `docs/spec/meeting-copilot.spec.md` 與 `docs/srs/recorder-automation-meeting-capture.srs.md`
> （會議錄製本體）。本功能是**新增的獨立守望者**，不改動既有錄製/copilot 行為。

### New / Changed API Endpoints

N/A — 本機 app。

### New / Changed Data Models

新增（UserDefaults，非 SwiftData → 免 schema 註冊）：`MeetingDetectionConfigStore`
（`@MainActor ObservableObject`，鏡射 `MeetingCopilotConfigStore` 的 `…V1` key +
`@Published private(set)` + `set…()` mutator + 可注入 `UserDefaults` 供測試）：

| Key | 型別 | 預設 | 說明 |
|---|---|---|---|
| `meetingDetectEnabledV1` | Bool | true | 總開關（關 = watcher 不輪詢、零 effects） |
| `meetingDetectNativeBundleIdsV1` | [String] | `["com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos"]` | 啟用的原生會議 app（UI 是固定目錄的 toggle，非自由輸入；Webex/FaceTime 在目錄中但預設關） |
| `meetingDetectBrowsersEnabledV1` | Bool | true | 瀏覽器路徑總開關（含標題確認） |
| `meetingDetectDebounceSecondsV1` | Double | 3（夾 1…15） | mic 持續多久才算候選 |
| `meetingDetectRearmSecondsV1` | Double | 30（夾 10…300） | mic 停多久後同 app 可再提示 |

瀏覽器家族與標題 pattern 是**程式內常數**（v1 不做使用者自訂）：

```swift
/// 瀏覽器家族:音訊行程的 bundle id 用「前綴」比對(Chrome 的音訊常來自
/// com.google.Chrome.helper*;PWA 是 com.google.Chrome.app.*),視窗 owner 用名稱比對
/// (CGWindowList 拿不到 bundle id,而 helper 行程的 pid 也對不上 UI 視窗的 ownerPID)。
struct BrowserFamily { let bundleIdPrefixes: [String]; let windowOwnerNames: [String] }
// Chrome: ["com.google.Chrome"] / ["Google Chrome"];Edge: ["com.microsoft.edgemac"] / ["Microsoft Edge"];
// Arc: ["company.thebrowser.Browser"] / ["Arc"];Brave: ["com.brave.Browser"] / ["Brave Browser"];
// Firefox: ["org.mozilla.firefox"] / ["Firefox"];Safari: ["com.apple.Safari"] / ["Safari"];
// Vivaldi: ["com.vivaldi.Vivaldi"] / ["Vivaldi"]

/// 會議標題 pattern(contains 比對,大小寫敏感;任一命中即可):
/// Google Meet 分頁標題「Meet – <code>」(en dash)/「Meet - 」(hyphen 保險)/「Google Meet」;
/// Teams 網頁版標題恆含產品名「Microsoft Teams」(中文介面亦同)。
static let meetingTitlePatterns = ["Meet – ", "Meet - ", "Google Meet", "Microsoft Teams"]
```

### Changed Business Logic

新增元件（全部新檔，建議放 `VoiceInk/Services/Meeting/`）：

- `AudioProcessMicWatcher` — 訊號 A。每 3s 輪詢 `kAudioHardwarePropertyProcessObjectList`
  （`AudioObjectGetPropertyData` on `kAudioObjectSystemObject`），對每個 process object 讀
  `kAudioProcessPropertyBundleID`（CFString）與 `kAudioProcessPropertyIsRunningInput`（UInt32），
  產出 `Set<String>`（正在收音的 bundle id），**排除自身 pid**（翻譯法照抄
  `MeetingCaptureService.translatePIDToProcessObject`，`MeetingCaptureService.swift:817-830`）。
  讀取這些屬性**不觸發任何 TCC**（沒有權限彈窗）。選輪詢不選 property listener：process object
  生滅頻繁、對每個 object 掛 `isRunningInput` listener 的生命週期管理繁瑣易漏，而 3s 輪詢是
  幾十次 `AudioObjectGetPropertyData` 的中繼資料讀取，成本可忽略；偵測本來就不需要秒級即時。
- `MeetingWindowTitleScanner` — 訊號 B。`CGWindowListCopyWindowInfo([.optionOnScreenOnly,
  .excludeDesktopElements], kCGNullWindowID)`，讀 `kCGWindowOwnerName` + `kCGWindowName` +
  `kCGWindowBounds`；命中 = owner ∈ 指定家族的 `windowOwnerNames` 且標題 contains 任一 pattern
  且 bounds ≥ 200×200（尺寸過濾照抄 `CopilotOverlayWindowManager.meetingAppScreen`，
  `CopilotOverlayWindowManager.swift:257-283`——注意：該前例只讀 OwnerName **不需要**權限；
  **`kCGWindowName` 需要「螢幕錄製」權限**，未授權時該 key 直接缺席、不會丟錯）。
  以 `CGPreflightScreenCaptureAccess()` 判斷可用性；**只在有瀏覽器候選 session 時**才掃描
  （on-demand，每 tick 至多一次），不常駐輪詢。
- `MeetingStartDetector` — glue（@MainActor singleton）。持 watcher/scanner/config，每 tick 把
  「現在時間、收音 bundle id 集合、標題掃描能力與結果」餵進**純函式決策核心**，執行回傳的 effects
  （發通知/記 log）。通知走 `NotificationManager.shared.showNotification(title:type:duration:onTap:actionButton:)`
  （`NotificationManager.swift:13-19`，單一 action 按鈕）：標題
  `「偵測到會議（<app 顯示名>）— 要開始會議錄製嗎？」`、type `.info`、duration 10s、
  actionButton `("開始會議錄製", { Task { await MeetingCaptureController.shared.start() } })`。
- `MeetingStartDetectorCore` — **純狀態機（本功能的可測核心）**。輸入
  `tick(now: Date, micBundleIds: Set<String>, titleCheck: (BrowserFamily) -> TitleCheckResult)`
  （`TitleCheckResult = .unavailable | .miss | .hit`），內部維護 per-bundle-id session
  （firstSeen / lastSeen / notified/consumed）與全域冷卻，輸出 `[Effect]`
  （`.prompt(bundleId:displayName:)` / `.suppressed(reason:)`）。所有 FR-87～FR-90 的規則都在
  這裡，不碰 CoreAudio/CGWindowList/UI——AC 測試全打這一層。

接線與 UI（既有檔案，加法）：

- `VoiceInk.swift` init：`MeetingStartDetector.shared.start()`（跟在其他 `configure` 之後；
  observe config 變更以啟停輪詢）。
- `MeetingCopilotSettingsView`：新分頁「會議偵測」（分頁 enum 加 case，分頁化理由同 M8 Task 19
  ——這是獨立子系統，堆進「一般」只會更難掃）。內容見 FR-91。
- `MeetingCaptureController`：不改邏輯；偵測器讀 `isRecording`、通知按鈕呼叫 `start()`。
  （若 `start()` 需要在無前景 app 情境下取 sourceLabel，本來就以 frontmost app 命名，行為不變。）

### Explicitly Out of Scope

- **行事曆路線（EventKit）**：性質是「應該有會」的行前提醒，非「真的在會中」偵測；需要新權限。
  之後要做另開 SRS。
- **自動開始錄音**（見整合決策規則的硬界線）。
- 標題 pattern / 瀏覽器家族的使用者自訂 UI（v1 常數；調整=改碼）。
- 偵測 Slack huddle、Discord、FaceTime 網頁版等其他會議形態（目錄裡有 Webex/FaceTime toggle
  但預設關，且不在驗收範圍）。
- 網路流量/私有 API 偵測。

## Functional Requirements

- [x] **FR-85 設定與儲存**：`MeetingDetectionConfigStore` 依上表的 key/預設/夾取實作；
      可注入 `UserDefaults`；所有 mutator 立即持久化並發布。
- [x] **FR-86 麥克風使用觀測**：`AudioProcessMicWatcher` 依上述輪詢設計產出收音 bundle id 集合；
      排除自身行程；總開關關閉或（可選優化）錄音中可暫停輪詢；讀取全程零 TCC 彈窗。
- [x] **FR-87 原生 app 觸發**：允許清單內 bundle id 收音持續 ≥ debounce → 產生 `.prompt` effect
      （經 FR-90 抑制規則）。等候室/裝置預覽（入會前 mic 已開）視為會議開始——這正是提示的最佳時機。
- [x] **FR-88 瀏覽器＋標題確認觸發**：瀏覽器家族（bundle id 前綴比對）收音持續 ≥ debounce 後，
      每 tick 對該家族做標題掃描；`.hit` → `.prompt`；`.miss` → 維持 pending 繼續等（mic session
      結束自然清掉）；`.unavailable`（無螢幕錄製權限）→ 該 session 直接 consumed 並記 log
      （**一個 session 只記一次**），原生路徑不受影響。
- [x] **FR-89 提示與動作**：`NotificationManager` 通知（文案/型別/時長/按鈕如上）；按鈕呼叫
      `MeetingCaptureController.shared.start()`；通知自然消失=忽略，無其他副作用。
- [x] **FR-90 抑制與一次性**：整合決策規則第 1–3 條（isRecording 靜默＋錄音開始 consume 全部
      session、per-session 一次＋rearm、全域冷卻 60s 內其他觸發 consumed）。
- [x] **FR-91 設定 UI**：「會議偵測」新分頁——總開關；原生 app 目錄 toggles（Teams/Zoom 預設開，
      Webex/FaceTime 預設關）；瀏覽器路徑開關＋**螢幕錄製權限狀態列**（`CGPreflightScreenCaptureAccess()`
      ✓/✗；✗ 時顯示「瀏覽器偵測需要螢幕錄製權限（讀視窗標題用，不擷取畫面）」＋「開啟系統設定」
      按鈕，**不主動觸發權限彈窗**）；debounce slider（1–15s）；隱私說明（只讀「哪個 app 在用
      麥克風」與視窗標題比對，不讀音訊內容、不儲存標題）。
- [x] **FR-92 觀測性**：unified log 用 **📡** 前綴（延續 emoji 字典：🎚️🎼🧠🥡🫆🎧🎬 已用）——
      候選出現/觸發/每種抑制原因（recording/consumed/cooldown/no-title/no-permission）各一行
      notice；**不記標題內容**，只記 app 名與 pattern 命中與否。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 資源 | 常態 CPU ≈ 0（3s 輪詢中繼資料）；標題掃描僅瀏覽器候選期間每 tick 一次 | 輪詢設計＋on-demand 掃描；無 tap、無音訊 IO |
| 隱私 | 不讀音訊內容；不持久化/不記錄視窗標題；不新增 TCC 彈窗 | 只讀 process 中繼資料；`kCGWindowName` 僅記憶體內比對；權限只顯示狀態不主動要 |
| 解耦 | 與 live pipeline 零編譯期依賴；唯一出口 = `MeetingCaptureController.start()` | 獨立 watcher/scanner/detector/core；型別隔離 |
| 可測性 | 全部觸發/抑制規則在純狀態機，注入時鐘與訊號 | `MeetingStartDetectorCore` 無系統 API 依賴 |
| 誠實 | 不宣稱偵測所有會議；標題 pattern 註明綁現行產品格式 | 設定頁說明＋本 SRS 範圍界線 |
| 防騷擾 | 同場會議至多 1 則提示 | per-session 一次＋全域冷卻＋isRecording 靜默 |
| 零回歸 | 既有錄製/copilot 行為不變 | 全新檔案；既有檔僅加法（wiring、設定分頁） |

## Architecture Notes

### 為什麼是「mic 為主、標題為輔」而不是反過來

標題單獨不可靠的方向是**誤報靜態存在**：開著 Meet 分頁不代表在開會、Teams 網頁任何分頁標題都含
「Microsoft Teams」。mic 單獨不可靠的方向只在瀏覽器（原生會議 app 開 mic 幾乎等價於在會議）。
兩者的可靠方向剛好互補：**mic 提供「正在發生」的時間性，標題提供「是會議」的語意**。因此原生
app 走 mic-only、瀏覽器走 mic AND title，而不是任一 OR 任一。

### 為什麼輪詢、不用 CoreAudio property listener

process object 隨行程生滅，對每個 object 掛/拆 `isRunningInput` listener 的簿記繁瑣且易漏
（漏拆=殭屍 listener）。輪詢一次 = 讀 process 清單＋每行程兩個屬性，微秒級；3s 粒度對「提醒開錄」
綽綽有餘（debounce 本來就 3s）。簡單勝過即時。

### 既有可重用錨點（實作先讀這些）

- pid → process object：`MeetingCaptureService.swift:817-830`（`kAudioHardwarePropertyTranslatePIDToProcessObject`）。
- CGWindowList 讀視窗＋尺寸過濾＋座標翻轉：`CopilotOverlayWindowManager.swift:257-283`
  （`meetingAppScreen()`；注意它只讀 OwnerName，本功能additionally 讀 `kCGWindowName` 需權限）。
- 通知＋action 按鈕：`NotificationManager.swift:13-19`；先例文案見 `MeetingCaptureController.start()`
  失敗通知（`MeetingCaptureController.swift:63-66`）。
- config store 樣板：`MeetingCopilotConfigStore` / `PresenterScriptStore`（注入 defaults、`…V1` key）。
- 設定分頁樣板：`MeetingCopilotSettingsView` 的 `SettingsTab`（M8 Task 19）。

### 權限現況與風險

截圖深答已要求螢幕錄製權限（`ScreenCaptureService`），此機器大概率已授權 → 訊號 B 開箱可用。
風險備忘：macOS 15 對螢幕擷取類 API 有週期性重確認機制；`CGWindowListCopyWindowInfo` 讀標題
屬於中繼資料、實測是否被納入 nag 待部署後觀察。若未授權或被撤：瀏覽器路徑按 FR-88 靜默降級，
原生路徑完全不受影響——這是 A+B 分層的另一個好處。

## Acceptance Criteria

> 全部打 `MeetingStartDetectorCore` 純狀態機（注入時鐘/訊號）＋ config store round-trip。
> **不得碰 `UserDefaults.standard`**（用注入 suite；平行測試共用 domain 的教訓）。
> 不碰 CoreAudio、不碰 CGWindowList、不發真通知。

### AC-70: 原生 app 觸發（debounce 滿）
- **Given**: 空狀態機，Teams（`com.microsoft.teams2`）在允許清單
- **When**: t=0/3/6s 三個 tick 都回報 Teams 收音
- **Then**: t=3s 起（≥ debounce 3s 的第一個 tick）恰好一個 `.prompt`；後續 tick 零 effects
- **Test**: `MeetingStartDetectorCoreTests::nativeAppPromptsOnceAfterDebounce`

### AC-71: debounce 未滿不觸發
- **Given**: 同上
- **When**: t=0 收音、t=3 已停（session 消失）
- **Then**: 全程零 `.prompt`
- **Test**: `MeetingStartDetectorCoreTests::shortBlipNeverPrompts`

### AC-72: 瀏覽器要標題命中才觸發（晚到也算）
- **Given**: Chrome 收音持續
- **When**: 前兩個 tick titleCheck 回 `.miss`，第三個 tick 回 `.hit`
- **Then**: 前兩 tick 零 prompt；`.hit` 的 tick 恰好一個 `.prompt`
- **Test**: `MeetingStartDetectorCoreTests::browserWaitsForTitleHit`

### AC-73: 無螢幕錄製權限 → 瀏覽器降級、原生照常
- **Given**: titleCheck 恆回 `.unavailable`；Chrome 與 Teams 同時收音（Teams 較晚，避開冷卻）
- **When**: tick 推進
- **Then**: Chrome session 被 consumed（含一則 `.suppressed(no-permission)`、只一次）；
  Teams 照常 `.prompt`
- **Test**: `MeetingStartDetectorCoreTests::noPermissionDegradesBrowserOnly`

### AC-74: 錄音中靜默＋consume
- **Given**: `isRecording == true` 期間 Teams 開始收音且超過 debounce
- **When**: 錄音中 tick 數次；之後 `isRecording == false`（mic session 未斷）
- **Then**: 全程零 `.prompt`（session 已 consumed，停止錄音後也不補提示）
- **Test**: `MeetingStartDetectorCoreTests::recordingSuppressesAndConsumes`

### AC-75: per-session 一次＋rearm
- **Given**: Teams 已提示過一次
- **When**: mic 停 10s 又開（< rearm 30s）繼續滿 debounce；之後 mic 停 35s 再開滿 debounce
- **Then**: 前者不提示（同 session 延續）；後者提示（新 session）
- **Test**: `MeetingStartDetectorCoreTests::rearmWindowGatesReprompt`

### AC-76: 全域冷卻吞掉並發第二觸發
- **Given**: Teams 於 t=3s 提示
- **When**: Chrome（含 title hit）於 t=20s 滿足全部條件
- **Then**: Chrome 觸發被 consumed（`.suppressed(cooldown)`），且冷卻過後**不補發**
- **Test**: `MeetingStartDetectorCoreTests::globalCooldownConsumesConcurrentTrigger`

### AC-77: 總開關與設定 round-trip
- **Given**: `meetingDetectEnabledV1 == false`
- **When**: 任何訊號進來；另測 config store 以注入 suite 寫入→重建載回、debounce 夾取(0→1, 99→15)
- **Then**: 零 effects；config 值/夾取正確
- **Test**: `MeetingDetectionConfigStoreTests::persistsAndClamps` + `CoreTests::disabledMeansInert`

### AC-78: 非允許清單與自身行程忽略
- **Given**: micBundleIds 含 `com.discord.something`、VoiceInk 自身 bundle id、未啟用的 Webex
- **When**: tick 推進超過 debounce
- **Then**: 零 effects（watcher 層另以 pid 排除自身；core 層以清單再擋一次）
- **Test**: `MeetingStartDetectorCoreTests::ignoresNonAllowlistedProcesses`

## Open Questions

- [ ] 瀏覽器「mic-only 低信度提示」要不要做成選項（無螢幕錄製權限時的替代）？v1 不做——
      寧可漏報也不騷擾；等實測漏報率再議。
- [ ] Teams 桌面 app 若使用者裝的是 classic（`com.microsoft.teams`）與 new（`teams2`）並存，
      目錄同時涵蓋兩者是否造成雙 session？（同一場會只會有一個行程開 mic，理論上不會；
      實測確認。）
- [ ] 行事曆路線（EventKit）作為互補的行前提醒，是否值得一個 M12？

## Implementation Handoff（給實作 session 的入場須知）

1. **先讀**：本 SRS 全文（尤其整合決策規則與 FR-90 的抑制語意）＋「既有可重用錨點」列的四段碼。
   背景記憶見 memory `ai-usage-dashboard-and-ui-batch`（本批未 commit 的工作區狀態）與
   `meeting-copilot-debug-workflow`（部署/測試習慣）。
2. **工作區現況**：repo 目前有一批**未 commit** 的已完成功能（AI 用量 dashboard、cheat sheet、
   pill 講稿下拉、中文模板）。實作本 SRS 前先與使用者確認 commit 策略，避免混包。
3. **測試紀律**：測試不得碰 `UserDefaults.standard`（注入 suite）；host-app 單元測試在未簽章
   headless 會 crash——只做 compile check（skill: `voiceink-build-verify`，build 進 `./.local-build`），
   實測由使用者 `! make deploy`。
4. **完工動作**：FR 逐條打勾、AC 對測試名；`docs/spec/SPEC_ROADMAP.md` 的 Recent Feature Changes
   標 implemented；unified log 驗證用
   `/usr/bin/log show --predicate 'process == "VoiceInk"' --info --last 30m | grep 📡`。
5. **實機驗證腳本**（使用者配合）：Firefox 開 Google Meet 等候室（mic 預覽開）→ 應提示；
   網頁語音輸入（無 Meet 分頁）→ 不應提示；Teams app 入會 → 應提示；錄音中入會 → 靜默。
