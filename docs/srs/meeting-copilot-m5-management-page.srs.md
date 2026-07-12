---
linear_issue: null
---
# SRS: 會議即時輔助 M5 — 管理頁面 + 完整設定（meeting-copilot）

> **本文件是 umbrella SRS `docs/srs/meeting-copilot-live-assist.srs.md` 的 M5 切片。**
> 里程碑切分見 umbrella SRS 與 `docs/spec/meeting-copilot.spec.md`。M5 只負責
> **會議錄音管理側欄頁**與**完整設定 UI**；它是依賴鏈 M2 → M3 → M4 → **M5（設定驅動全部）** 的最後一環。
> M5 假定 M2 已建好 `meeting.store` 與 `MeetingLiveSession` / `MeetingLiveCue` `@Model`、M3 已擴充
> `MeetingCopilotConfigStore` 的 fast/deep/grounding 欄位、M4 已定義兩個 overlay 熱鍵的 `ShortcutAction` case。
> 凡本文引用 M2–M4 尚未落地的符號，均在「Explicitly Out of Scope / 依賴」明列為前置條件。

## Metadata
- **Module**: `meeting-copilot`（新模組；M1 音訊骨幹已實作並 commit，build 248）
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Umbrella SRS**: `docs/srs/meeting-copilot-live-assist.srs.md`（34 FR / 19 AC；本文覆蓋其中 FR-29/30/31 + AC-18/19）
- **Source PRD**: N/A（2026-07-12 使用者需求）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-12
- **Grill level**: 1 (standard)
- **Build number**: 252（M5；`CURRENT_PROJECT_VERSION` Debug + Release 兩處同步 bump）

## Feature Summary

給 meeting-copilot 一個**可回顧、可設定的家**。

1. **新側欄頁「會議錄音管理」**（`ViewType.meetingCopilot`）：以 `@Query` 列出歷史 `MeetingLiveSession`，
   點一列以 `centeredModal` 開詳情，呈現**雙軌逐字稿**（remote / local）與每則 `MeetingLiveCue` 的
   **三層回應**（Tier 0 關鍵字 / Tier 1 開口稿 / Tier 2 分析 + follow-ups）。整頁**clone `VoiceLibraryView`**
   的表格 / 搜尋 / 排序 / `centeredModal` 結構。
2. **完整設定 UI**：`MeetingCopilotSettingsView` 收攏兩個 overlay 熱鍵 + `.toggleMeetingRecording` 的
   `ShortcutRecorder` row、ASR 模型 picker、**fast / deep 雙模型 picker**（clone `RecorderModeSettingsView`
   的 `Picker` + `Binding<RecorderModelChoice?>` 形態）、會前 brief 輸入、prefetch / RAG / 螢幕 / 本機麥克風開關，
   以及**本機 ASR 無術語偏置的明示說明**。
3. **修補全域快捷鍵 UI**：`SettingsView` 補上三個會議熱鍵
   （`.toggleMeetingRecording` + `.toggleMeetingCopilotOverlay` + `.peekMeetingCopilotOverlay`）的
   `ShortcutRecorder` row，三者**全部納入重複快捷鍵偵測**。

M5 不新增任何即時路徑邏輯、不碰 realtime thread、不發 LLM 請求；它是純 SwiftUI / UserDefaults 的**呈現與組態層**。

---

## Delta from Current Module State

> 這是新模組的第 5 個里程碑。M5 對**既有導覽 / 設定程式碼**的侵入面刻意壓到最小：一個新 `ViewType` case、
> 三個新 View 檔、`SettingsView` 補三 row。所有新頁面**硬寫繁體中文字面**（近期新頁面慣例；`AppScreenHeader`
> 的 `title` / `infoMessage` 是 `LocalizedStringKey`，只吃字面）。

### New Data Models

**無。** M5 不新增 `@Model`。它**唯讀消費** M2 建立的 `MeetingLiveSession` / `MeetingLiveCue`
（umbrella SRS「New Data Models」；存於 M2 於 `VoiceInk.swift` 三處註冊的 `meeting.store`，`cloudKitDatabase: .none`）。
`meeting.store` 的建立、三處 schema 註冊（master `Schema([...])` `VoiceInk.swift:48`、`createPersistentContainer`
`VoiceInk.swift:245`、`createInMemoryContainer` `VoiceInk.swift:302`）**是 M2 的職責，不在 M5**——
M5 僅以 `@Query`（透過 `container.mainContext` 跨 store 透明存取）讀取。

> 依賴前置：若執行 M5 時 `meeting.store` 尚未註冊，`@Query<MeetingLiveSession>` 會在 runtime 取不到資料
> （非 compile error）。M5 的 replay / 頁面測試需先確保 M2 的三處註冊到位。

### Changed Business Logic

- **導覽**：`ViewType` 新增 `case meetingCopilot`（`ContentView.swift:4`，rawValue 例 `"Meeting Copilot"`）。
  必須同步改動 **五處**（`recon-nav-persist.md` GOTCHAS）：
  - `ContentView.detailView(for:)`（`ContentView.swift:69`，**exhaustive → 漏＝compile error**）→ `MeetingCopilotPageView()`（零參數）。
  - `AppSidebar` `private extension ViewType` 的 `icon`（`AppSidebar.swift:157`，**exhaustive → compile error**）。
  - 同上 `sidebarIconStyle`（`AppSidebar.swift:181`，**exhaustive → compile error**；只能用 `AppTheme.Sidebar` 既有調色盤
    `AppTheme.swift:63`，否則新增一個 `static let`）。
  - `title`（`AppSidebar.swift:120`，**有 `default:` → 漏不報錯**，會靜默 fallback 成 rawValue；仍要補繁中字面 `"會議錄音管理"`）。
  - `sidebarSections` 陣列（`AppSidebar.swift:142`，**漏＝DEBUG `assert` crash** on `assertSidebarItemsCoverAllCases()`
    `AppSidebar.swift:150`；RELEASE 下頁面靜默無法從側欄抵達）。放入哪個 section 見 Architecture。
- **管理頁**：`MeetingCopilotPageView`（新檔 `Views/MeetingCopilot/MeetingCopilotPageView.swift`）clone
  `VoiceLibraryView`（`VoiceLibraryView.swift:6`）：`@Query` + `AppScreenHeader` + 表頭/列 + `.centeredModal(item:)`
  詳情。查詢 `MeetingLiveSession`（依 `startedAt` 反序），搜尋/排序**在記憶體內**跑（比照 `filteredItems`/`sortedItems`），
  詳情 sheet 呈現雙軌逐字稿與 cue 三層。
- **設定頁**：`MeetingCopilotSettingsView`（新檔 `Views/Settings/MeetingCopilotSettingsView.swift`）clone
  `RecorderModeSettingsView`（`RecorderModeSettingsView.swift:5`）的 scaffold：`@StateObject store = MeetingCopilotConfigStore.shared`
  + `@EnvironmentObject aiService: AIService` + 每個控制項一個 `Binding(get:set:)`。**fast / deep 兩個模型 picker**
  結構性複製 `RecorderModeSettingsView.swift:69` 的兩個 `Picker`（差別只在 placeholder 文案與所綁 Binding），
  資料源同為 `recorderModelChoices(aiService)`（`CategoriesSettingsView.swift:4`）。
- **全域快捷鍵**：`SettingsView` 的「Additional Shortcuts」section（`SettingsView.swift:78`）**補三個
  `LabeledContent` + `ShortcutRecorder` row**（比照既有 paste/retry row 樣式，`ShortcutRecorder.swift:14`），
  `onShortcutChanged` 一律呼叫 `recordingShortcutManager.updateShortcutStatus()` 讓 live event tap 重新武裝。
  三個 action 皆須落入 `ShortcutValidator.allStoredActions`（`ShortcutValidator.swift:25`）以參與衝突偵測。

### New / Changed API

- **NEW** `Views/MeetingCopilot/MeetingCopilotPageView.swift`：`struct MeetingCopilotPageView: View`（零參數，供
  `detailView(for:)` 直接建構）。內部 private 子 view（表頭 / 列 / 詳情 sheet）比照 `VoiceLibraryView` 檔內私有型別。
- **NEW** `Views/Settings/MeetingCopilotSettingsView.swift`：`struct MeetingCopilotSettingsView: View`。
- **CHANGED** `ContentView.swift`：`ViewType` enum + `detailView(for:)`。
- **CHANGED** `AppSidebar.swift`：`private extension ViewType` 的 `title` / `sidebarSections` / `icon` / `sidebarIconStyle`
  四處（此 extension 為 `AppSidebar.swift` file-private，**只能在該檔內改**）。
- **CHANGED** `SettingsView.swift`：三個 `ShortcutRecorder` row。
- **CONSUMED（唯讀，不改）**：
  - `MeetingCopilotConfigStore`（`Services/MeetingCopilot/MeetingCopilotConfigStore.swift`）——M1 有
    `copilotEnabled` / `asrModelName` / `transcribeLocalMic`；M3 擴充 fast/deep provider+model、`prefetchEnabled`、
    `useHistoryRAG`、`useScreenContext`、`domainPersona` 等。其 `@Published` 屬性為 **`private(set)`**
    （比照 `RecorderConfigStore` `RecorderConfigStore.swift:19`），故 M5 每個控制項都要用 `Binding(get:set:)` 包
    （見 `RecorderModeSettingsView.swift:938` 的 12 個 Binding 屬性樣式），並透過 store 的 `set…()` mutator 寫入。
  - `recorderModelChoices(_:)` / `RecorderModelChoice`（`CategoriesSettingsView.swift:4`）。
  - `AIService.connectedProviders` / `availableModels(for:)` / `selectedModel(for:)`（`AIService.swift:234-294`）。
  - `AppScreenHeader`（`AppControls.swift:77`）、`.centeredModal(item:)`（`CenteredModal.swift:57`）、`VoiceRowDisplay`（`VoiceLibraryView.swift:207`）。
  - `ShortcutRecorder`（`ShortcutRecorder.swift:14`）、`ShortcutAction`（`ShortcutAction.swift:3`）。

### Explicitly Out of Scope（含前置依賴）

- **`meeting.store` 與 `@Model` 定義（M2）**——M5 唯讀 `@Query`，不新增/不註冊 store。
- **`ResponseCueExtractor` / 三層回應 / SSE / grounding（M2、M3）**——M5 只**呈現**已落 SwiftData 的結果，不產生它們。
- **`MeetingCopilotConfigStore` 的 fast/deep/grounding 欄位定義（M3）**——M5 綁定它們，不新增欄位。
  （若 M3 未落地，M5 的 fast/deep picker 無可綁之 setter；此時 M5 需與 M3 合併。）
- **兩個 overlay `ShortcutAction` case 定義 + `legacyKeyboardShortcutActions` 納入（M4）**——
  `.toggleMeetingCopilotOverlay` / `.peekMeetingCopilotOverlay` 的 enum arm（`ShortcutAction.swift` `storageName`/`displayName`
  exhaustive switch、`ShortcutMigration.legacyKeyboardShortcutsNames` `ShortcutMigration.swift:251` exhaustive switch）
  與其在衝突清單的登錄，屬 M4。M5 的職責是**設定 UI 的 `ShortcutRecorder` row + 驗證 AC-19**。
  若 M4 尚未把三個 action 放進 `allStoredActions`（`ShortcutValidator.swift`），M5 必須補上，否則 AC-19 的衝突偵測不成立。
- **overlay 面板本身、`sharingType = .none`、peek 的 keyDown/keyUp 分派（M4）**——M5 不含任何 `NSPanel` 或 event-tap 改動。
- **會前 brief 若選 Obsidian 筆記的檔案選取流程**——M5 先做**純文字 brief 輸入**；檔案挑選（security-scoped bookmark）列 Open Questions。
- xcstrings / 本地化——新頁面硬寫繁中字面。

---

## ViewType 新增的爆炸半徑（§3 findings 之一，直接落在 M5）

`recon-nav-persist.md` 指出新 `ViewType` case 的四種失敗模式**嚴重度不一**，M5 必須四處都補齊：

| 位置 | 檔案:行 | 是否 exhaustive | 漏掉的後果 |
|---|---|---|---|
| `detailView(for:)` | `ContentView.swift:69` | ✅ exhaustive | **compile error**（好：擋得住） |
| `icon` | `AppSidebar.swift:157` | ✅ exhaustive | **compile error**（好） |
| `sidebarIconStyle` | `AppSidebar.swift:181` | ✅ exhaustive | **compile error**（好；且顏色僅限 `AppTheme.Sidebar` 既有集） |
| `title` | `AppSidebar.swift:120` | ❌ 有 `default:` | 靜默 fallback 成 rawValue（英文），**不報錯** |
| `sidebarSections` | `AppSidebar.swift:142`（陣列） | ❌ 陣列 | **DEBUG `assert` crash**（`assertSidebarItemsCoverAllCases()` `AppSidebar.swift:150`）；RELEASE 下側欄無此項、頁面無法抵達 |

→ compile gate 只能保證前三處；`title` 與 `sidebarSections` 需**人工/測試**確認。這是 M5 最容易踩的坑。

---

## 本機 ASR 無術語偏置的明示（§3 finding #8，M5 設定 UI 的誠實義務）

`recon` 與 umbrella SRS 確認：`VocabularyWord` 術語表只在**雲端串流 provider**（Deepgram / Speechmatics / Soniox
的 `getCustomVocabularyTerms()`）生效；**本機 FluidAudio（預設 ASR）不支援術語偏置**。這是一個**不能兩全的取捨**：

| ASR 選擇 | 免 API key | 隱私（不出本機） | 術語偏置 |
|---|---|---|---|
| FluidAudio Parakeet（**預設**） | ✅ | ✅ | ❌ |
| Deepgram / Speechmatics / Soniox | ❌ | ❌ | ✅ |

`MeetingCopilotSettingsView` 的 ASR 模型 picker **旁必須有明示文案**（`.font(.caption).foregroundStyle(.secondary)`，
比照 `RecorderModeSettingsView.swift:69` 各 Section 的說明行）：專案代號 / 服務名（如「Kafka」）易被本機 ASR 轉錯，
而轉錯會直接害到 cue 抽取；需要術語準確度者請選雲端 ASR。**不得**在 UI 暗示本機模型能吃術語表。

---

## Functional Requirements（僅 M5 涵蓋）

### 頁面
- [ ] **FR-29** 新側欄頁「會議錄音管理」（`ViewType.meetingCopilot`）：以 `@Query` 列出 `MeetingLiveSession`（依 `startedAt` 反序），
  搜尋 / 依欄位排序（記憶體內，比照 `VoiceLibraryView`），點一列以 `.centeredModal(item:)` 開詳情，呈現**雙軌逐字稿**
  （remote / local）與每則 `MeetingLiveCue` 的三層回應（Tier 0 關鍵字、Tier 1 `opener`+bullets、Tier 2 `analysis`+`followUps`+`uncertainties`）。

### 設定
- [ ] **FR-30** `MeetingCopilotSettingsView` 可設定：
  - 三個熱鍵中屬會議 overlay 的兩個（`.toggleMeetingCopilotOverlay` / `.peekMeetingCopilotOverlay`）+ `.toggleMeetingRecording` 的 `ShortcutRecorder`；
  - ASR 模型 picker（含本機無術語偏置的明示說明）；
  - **fast / deep 兩組 provider+model picker**（clone `RecorderModeSettingsView` 的 `Picker`+`Binding<RecorderModelChoice?>`，資料源 `recorderModelChoices(aiService)`）；
  - 會前 brief 純文字輸入；
  - `prefetchEnabled` / `useHistoryRAG` / `useScreenContext` / `transcribeLocalMic` 開關。
  - 每個控制項透過 `MeetingCopilotConfigStore` 的 `set…()` mutator 寫入（`@Published` 為 `private(set)`，故用 `Binding(get:set:)` 包）。

### 模型解析回退
- [ ] **FR-31** 設定所選的 fast / deep provider+model 以純函式解析時，**必須重新驗證 stored provider 仍在
  `aiService.connectedProviders`（`AIService.swift:234`）內**；若已斷線（如移除該 provider 的 API key），
  **回退預設 provider**，不 crash、不用失效 provider 發請求。鏡射 `AskAIAnswerModel.resolve`
  （umbrella SRS 引用 `Services/AskAI/AskAIConfig.swift:31-38`）與 `RecorderPostProcessor.resolvedAnalysisModel` 的邏輯。

> **FR-31 / 純函式 `MeetingCopilotModels.resolve` 的歸屬**：umbrella 把 `MeetingCopilotModels.resolve()` 的**函式本體**
> 列在 M3 範圍；FR-31 / AC-18 的**行為驗收**指派給 M5（因 M5 是設定 UI，是「選了斷線的 provider 會怎樣」被使用者感知之處）。
> M5 擁有此 AC 的測試；若 M3 已提供 `resolve()`，M5 直接測它，否則 M5 一併引入該純函式（見 Open Questions）。

---

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 一致性（頁面） | 管理頁與 `VoiceLibraryView` 觀感一致 | clone 其 `AppScreenHeader` + 表頭/列 + `.centeredModal` 結構（`VoiceLibraryView.swift:6/225`） |
| 一致性（設定） | 模型 picker 與錄音設定同形 | clone `RecorderModeSettingsView` 的 `Picker`+`Binding<RecorderModelChoice?>`（`RecorderModeSettingsView.swift:69/938`） |
| 正確性（導覽） | 新 case 不致 DEBUG crash / 靜默失聯 | 四處（含非 exhaustive 的 `title`/`sidebarSections`）皆補；`assertSidebarItemsCoverAllCases` 綠 |
| 正確性（設定寫入） | 控制項不可直接寫 `private(set)` @Published | 每控制項 `Binding(get: { store.x }, set: { store.setX($0) })` |
| 韌性（模型解析） | provider 斷線不 crash | FR-31 純函式回退；不對失效 provider 發請求 |
| 誠實性（ASR） | 不誤導使用者以為本機吃術語表 | ASR picker 旁明示取捨文案 |
| 誠實性（overlay 隱蔽） | 不宣稱無條件隱形 | 設定文案須反映 §3 finding #1（見 Risks） |
| 隱私 | 逐字稿 / 答案僅本機呈現 | 唯讀 `meeting.store`（`cloudKitDatabase: .none`）；M5 不外送任何資料 |
| 零回歸 | 既有 19 個 `ViewType` 頁面與快捷鍵行為不變 | 僅新增 case / row；不改既有 arm；compile gate + 既有測試把關 |

---

## Architecture Notes

### 管理頁（clone `VoiceLibraryView`）

- 資料：`@Query(sort: \MeetingLiveSession.startedAt, order: .reverse) private var sessions: [MeetingLiveSession]`
  （`container.mainContext` 跨 store 透明，`recon-nav-persist.md` GOTCHAS；`#Predicate` 只能引用同 store 的型別）。
- 版面：`AppScreenHeader(title: "會議錄音管理", infoMessage: "…", infoURL: nil) { EmptyView() }`（`AppControls.swift:77`；
  `title`/`infoMessage` 是 `LocalizedStringKey`，**只吃字面繁中**）。搜尋列 + 自製表頭/列（欄寬 header 與 row 需手動對齊，
  `VoiceLibraryView.swift:225` 的 `Color.clear.frame(width: 37)` 前導 + `HStack(spacing: 10)` + `.padding(.horizontal, 24)`）。
- 詳情：`.centeredModal(item: $detailTarget) { session in … }`（`CenteredModal.swift:57`）；modal 的 frame / 背景 / 圓角 / 陰影
  由**呼叫端**供給（比照 `VoiceLibraryView.swift:695`），sheet 內用 `AppPanelHeader(title:onClose:)`。詳情內容分三塊：
  雙軌逐字稿（remote / local，讀 `MeetingLiveSession.remoteTranscriptRaw` / `localTranscriptRaw`）、cue 清單（讀 `session.cues`）、
  每則 cue 的三層（Tier 0/1/2 欄位，陣列欄位經 JSON-in-raw + `@Transient` 快取存取器，比照 `Transcription.swift:76`）。
- 側欄互動：純新頁**不需**改 `sidebarSection`（`AppSidebar.swift:274`）——落入 generic `SidebarItemButton` 分支即可；
  除非要可展開子清單（比照 `expandableRecorderLog` / `expandableVoiceLibrary`），本 M5 不做。

### 側欄 section 歸屬

`sidebarSections`（`AppSidebar.swift:142`）目前五組：`(nil,[dashboard])` / `語音輸入` / `錄音輸入` / `Ask AI` / `共用與系統`。
會議 copilot 的定位與「錄音輸入」相鄰但職責不同（即時輔助 vs 事後匯入）。建議放入「錄音輸入」組末，或新增獨立組
（見 Open Questions）。無論放哪，**該 case 必須出現在某組的 `items` 陣列**，否則 `assertSidebarItemsCoverAllCases()` 崩。

### 設定頁（clone `RecorderModeSettingsView`）

- Scaffold：`@StateObject private var store = MeetingCopilotConfigStore.shared`（singleton 上加 `@StateObject`，house style）
  + `@EnvironmentObject private var aiService: AIService`。`Form { … }.formStyle(.grouped)`，頂部 `AppScreenHeader`（繁中字面）。
- fast / deep picker：兩個結構相同的 `Picker`（`RecorderModeSettingsView.swift:69`），placeholder row 用
  `Text("自動（第一個可用）").tag(RecorderModelChoice?.none)`，ForEach `recorderModelChoices(aiService)`
  以 `.tag(RecorderModelChoice?.some(c))`（**Optional tag 型別必須精確**，寫 `.tag(c)` 會 runtime 靜默壞掉，
  `recon-nav-persist.md` GOTCHAS）。
- Binding：每個 store 欄位一個 `private var xBinding: Binding<T>`，`get` 讀 `store.x`、`set` 呼 `store.setX($0)`；
  fast/deep 的 `Binding<RecorderModelChoice?>` 直接比照 `RecorderModeSettingsView.swift:938` 的 `analysisBinding` / `classifierBinding`
  （nil ⇄「自動」的映射寫在 Binding 裡，不在 store）。
- ASR picker 旁明示本機無術語偏置（見上節）。

### 全域快捷鍵三 row（`SettingsView`）

於「Additional Shortcuts」section（`SettingsView.swift:78`）加三個：
```
LabeledContent("切換會議錄製") { ShortcutRecorder(action: .toggleMeetingRecording) { recordingShortcutManager.updateShortcutStatus() }.controlSize(.small) }
LabeledContent("切換會議輔助浮窗") { ShortcutRecorder(action: .toggleMeetingCopilotOverlay) { recordingShortcutManager.updateShortcutStatus() }.controlSize(.small) }
LabeledContent("按住預覽會議輔助浮窗") { ShortcutRecorder(action: .peekMeetingCopilotOverlay) { recordingShortcutManager.updateShortcutStatus() }.controlSize(.small) }
```
`onShortcutChanged` 呼 `updateShortcutStatus()` 讓 live event tap 重新武裝（`recon-hotkeys.md`）。
`.toggleMeetingRecording` 已在 `globalUtilityActions`（`ShortcutAction.swift:100`）故已被 tap 監看且已在 keyUp 觸發
（`handleGlobalShortcut` 有 `.toggleMeetingRecording` case，`RecordingShortcutManager.swift:314`）——它的 bug 純粹是
**沒有 UI row + 不在衝突偵測清單**，M5 補 row，衝突清單登錄由 M4 完成（見下）。

### 衝突偵測（AC-19）

`ShortcutValidator.allStoredActions`（`ShortcutValidator.swift:436`）= `legacyKeyboardShortcutActions + modes`。
`.toggleMeetingRecording` 在 `globalUtilityActions` 但**不在** `legacyKeyboardShortcutActions`（`ShortcutAction.swift:113`），
故對衝突偵測隱形——這是既有缺陷。修法（M4 職責，M5 驗收）：把三個會議 action 加入 `legacyKeyboardShortcutActions`
（安全：它們的 `legacyKeyboardShortcutsNames` 回 `[]`，migration no-op，`ShortcutMigration.swift:251`），
或改寫 `allStoredActions` 併入 `globalUtilityActions`。**三者只要落入 `allStoredActions`，其鍵即參與雙向衝突偵測。**
AC-19 的測試由 M5 擁有並把關。

### 模型解析回退（FR-31 / AC-18）

純函式，鏡射 `AskAIAnswerModel.resolve`（umbrella 引 `Services/AskAI/AskAIConfig.swift:31-38`）與
`RecorderPostProcessor.resolvedAnalysisModel`：讀 stored `(provider, model)` → 若 `AIProvider(rawValue: provider)`
不在 `aiService.connectedProviders`（`AIService.swift:234`）→ 回退預設 provider 的 `defaultModel`（或 `selectedModel(for:)`）。
picker 選項本就來自 `recorderModelChoices`（只列 connected provider），但**已存的舊選擇**可能指向後來斷線的 provider——
這正是回退要擋的情境。

---

## Acceptance Criteria

### AC-18: 模型解析回退（provider 斷線回退預設）
- **Given**: `MeetingCopilotConfigStore` 的 `fastProvider` 已存為 Groq，隨後使用者移除 Groq 的 API key（Groq 不再在 `aiService.connectedProviders`）
- **When**: 解析 fast model（`MeetingCopilotModels.resolve` / FR-31 純函式）
- **Then**: 回退至預設 provider 的模型；**不 crash、不對失效的 Groq 發任何請求**；deep model 亦同此邏輯
- **Test**: `MeetingCopilotModelsTests::fallsBackWhenProviderDisconnected`（以 fake `AIService`／注入 `connectedProviders` 集合斷言回退，並斷言未對斷線 provider 發請求）

### AC-19: 三個會議熱鍵皆可設定且納入衝突偵測（既有缺陷修復）
- **Given**: 設定頁（`SettingsView` 的 Additional Shortcuts / `MeetingCopilotSettingsView`）
- **When**: 檢視快捷鍵區，並嘗試把一個已被其他 action 佔用的鍵指派給 `.toggleMeetingCopilotOverlay`（反向亦然）
- **Then**: `.toggleMeetingRecording`、`.toggleMeetingCopilotOverlay`、`.peekMeetingCopilotOverlay` **三者**皆有可操作的 `ShortcutRecorder`；
  三者皆出現在 `ShortcutValidator.allStoredActions`，指派衝突鍵時被 `validationError` 以 `.alreadyUsedBy` 擋下（雙向）
- **Test**: `MeetingShortcutTests::allMeetingShortcutsAreConfigurableAndValidated`（斷言三 action ∈ `allStoredActions`，且 `ShortcutValidator.validationError` 對衝突鍵回非 nil）+ 人工檢視三 row 存在

> 頁面（FR-29）與設定控制項存在性（FR-30）以**開發期肉眼 + snapshot/構建通過**驗收；SwiftUI View 本身無穩定單元測試 seam，
> 其資料正確性靠 M2/M4 的 replay 落 SwiftData 後在此頁呈現來間接覆蓋。

---

## Risks & Trade-offs

| 風險 | 可能性 | 影響 | 緩解 |
|---|---|---|---|
| **`sharingType = .none` 在 macOS 15.4+ 被 ScreenCaptureKit 忽略**（§3 finding #1；Apple DTS 明言「目前無公開 API 可防螢幕擷取」，Chrome/Meet `getDisplayMedia` 走 SCK） | **H**（分享整個螢幕時） | **H** — 若 M5 設定/頁面文案宣稱 overlay「無條件隱形」，會誤導使用者在分享整個螢幕時暴露私人筆記 | M5 涉及 overlay 的任何設定說明文案**必須誠實**：安全模式是「分享單一視窗/分頁」，分享整個螢幕會被錄到；overlay 面板與 `sharingType` 屬 M4，M5 只需在文案上不越界宣稱 |
| **`title` / `sidebarSections` 非 exhaustive**：漏補 `title` 靜默 fallback、漏補 `sidebarSections` DEBUG assert crash / RELEASE 頁面失聯（§3 finding #7） | M | M–H | compile gate 只擋 `detailView`/`icon`/`sidebarIconStyle`；`title`+`sidebarSections` 需人工 + `assertSidebarItemsCoverAllCases` 綠燈確認 |
| **本機 ASR 無術語偏置**（§3 finding #8）→ 使用者誤以為選了本機也能吃術語表 | H（若不明示） | M | ASR picker 旁明示取捨；文案不得暗示本機可偏置 |
| `MeetingCopilotConfigStore` @Published 為 `private(set)`，控制項若直接綁定會 compile error / 寫不進 | L | L | 每控制項一律 `Binding(get:set:)` 過 setter（比照 `RecorderModeSettingsView`） |
| Optional Picker tag 型別寫錯（`.tag(c)` 而非 `.tag(RecorderModelChoice?.some(c))`）→ 選取**runtime 靜默失效**、無 compile error | M | M | 嚴格照 `RecorderModeSettingsView.swift:69` 的 tag 寫法；code review 把關 |
| 三個會議 action 未落入 `allStoredActions`（M4 未登錄）→ AC-19 衝突偵測不成立 | M | M | M5 測試斷言三 action ∈ `allStoredActions`；缺則 M5 補登錄 |
| `meeting.store` 未由 M2 註冊 → 管理頁 `@Query` runtime 無資料（非 compile error） | L（依賴鏈保證 M2 先行） | M | M5 頁面測試前確認三處 schema 註冊到位；否則與 M2 合併執行 |

---

## Open Questions

- [ ] 會議 copilot 側欄項放入「錄音輸入」組，還是新增獨立組（如「會議輔助」）？獨立組更清楚但多一個 section header。
- [ ] 新 `ViewType.meetingCopilot` 的 `sidebarIconStyle` 用 `AppTheme.Sidebar` 哪個既有色（`audio`/`fallback`…），還是在 `AppTheme.swift:63` 新增一個 `static let`？
- [ ] 純函式 `MeetingCopilotModels.resolve` 究竟由 M3 提供、還是 M5 引入？（umbrella 把本體列 M3、行為驗收列 M5。）需在排程 M3/M5 時定案，避免兩份實作。
- [ ] 會前 brief 是否在 M5 就支援選 Obsidian 筆記 / 文字檔（security-scoped bookmark，`VaultExportService` 有先例），還是 M5 先做純文字、檔案挑選另案？
- [ ] 管理頁詳情的雙軌逐字稿呈現：是否需要時間軸交錯合併（remote/local interleave by timestamp），還是分兩欄各自捲動？後者較省工。
- [ ] 管理頁是否需要批次刪除 / 星號保護（比照 `VoiceLibraryView` 的 `TranscriptionStore.delete` + `LibraryFilter.deletionSet`），還是 v1 只讀不刪？
- [ ] `MeetingCopilotSettingsView` 的熱鍵 row 與 `SettingsView` 的三 row 是否重複呈現（兩處都放）會否讓使用者困惑？或設定頁只放會議專屬、全域頁只放三熱鍵。
