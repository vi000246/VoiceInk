---
linear_issue: null
---
# Plan: Meeting Copilot M5 — 會議錄音管理頁 + 完整設定 UI

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type`。**Mode B（任務先測）**：每個 task 先寫一個鎖行為的測試 → 實作 → 通過 → commit。**Rigor: strict** — 測試 gate 全強制。
>
> **⚠️ M5 是依賴鏈的最後一環（M2 → M3 → M4 → M5）。** 開工前先確認：M2 的 `meeting.store` + `MeetingLiveSession`/`MeetingLiveCue` 已落地、M3 的 `MeetingCopilotConfigStore` fast/deep/grounding 欄位已擴充、M4 的 `.toggleMeetingCopilotOverlay`/`.peekMeetingCopilotOverlay` 兩個 `ShortcutAction` case 已存在。缺任何一個，對應 task 會 compile error——那不是本 plan 的 bug，是前置未完成。
>
> **⚠️ M5 最陰的坑不在 compile error，在「不報錯的失敗」**：`ViewType` 的 `title`（有 `default:`，漏了靜默 fallback 英文）與 `sidebarSections`（陣列，漏了 DEBUG assert crash / RELEASE 頁面失聯），以及 Optional Picker 的 `.tag()` 型別寫錯（runtime 靜默失效）。見「規劃期發現」。
>
> **Checkbox states:** `- [ ]` todo · `- [~]` in-progress · `- [x]` done。`[~]` 不是完成。

## Summary

給 meeting-copilot 一個可回顧、可設定的家：

1. **新側欄頁「會議錄音管理」**（`ViewType.meetingCopilot`）：`@Query` 列出歷史 `MeetingLiveSession`，搜尋/排序在記憶體內跑，點一列以 `.centeredModal(item:)` 開詳情——雙軌逐字稿（remote/local 兩欄各自捲動）+ 每則 cue 的三層回應。整頁 clone `VoiceLibraryView`。
2. **完整設定 UI**（`MeetingCopilotSettingsView`，從管理頁 header 的「設定」按鈕以 centeredModal 開啟）：三個會議熱鍵的 `ShortcutRecorder`、ASR 模型 picker（含**本機無術語偏置的明示**）、fast/deep 雙模型 picker（clone `RecorderModeSettingsView`）、會前 brief 純文字輸入、prefetch/RAG/螢幕/本機麥克風開關。
3. **修補全域快捷鍵 UI**：`SettingsView` 補三個會議熱鍵 row，並以測試把關三者**全部**參與雙向衝突偵測（AC-19，既有缺陷修復的驗收）。
4. **模型解析回退**（FR-31/AC-18）：fast/deep 的 stored provider 斷線時回退預設，純函式測試鎖行為。

M5 不新增 `@Model`、不註冊 store、不碰 realtime 路徑、不發 LLM 請求——純 SwiftUI/UserDefaults 的呈現與組態層。

## User Story

As a 用會議輔助開會的使用者, I want 會後能回顧每場會議的雙軌逐字稿與 AI 建議、並在一處設定好模型/熱鍵/接地開關, so that 這個功能是可信、可調、可回顧的工具而不是黑盒。

## Problem → Solution

M2–M4 建好了引擎（cue 偵測、三層回應、overlay），但狀態只活在當下：會議結束就看不到了，設定散落（`.toggleMeetingRecording` 自 build 227 起**無法設定熱鍵且逃過衝突偵測**），fast/deep 模型只能吃預設。
→ 一個 clone `VoiceLibraryView` 的管理頁讀 `meeting.store`、一個 clone `RecorderModeSettingsView` 的設定頁寫 `MeetingCopilotConfigStore`、三個 `ShortcutRecorder` row + 衝突偵測測試補完熱鍵系統。

## Metadata
- **Module**: meeting-copilot
- **Parent Plan**: N/A（依賴 M1–M4 已完成）
- **Source PRD**: N/A
- **Source Feature SRS**: `docs/srs/meeting-copilot-m5-management-page.srs.md`（umbrella `docs/srs/meeting-copilot-live-assist.srs.md` 的 M5 切片）
- **Source Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source Linear Issue**: N/A（`docs/prp.config.yml` → `skip: true`）
- **Type**: feature ｜ **Size**: L ｜ **Complexity**: Medium（面積大、深度淺）
- **Rigor**: strict ｜ **Mode**: B — 任務先測 ｜ **TDD**: on（task-level）｜ **Commit cadence**: per-task
- **Estimated Files**: ~11（3 created + 5 modified + 3 test files）
- **Build**: 251 → **252**
- **FR 覆蓋**: FR-29（頁面）、FR-30（設定）、FR-31（模型解析回退）
- **AC 覆蓋**: AC-18（模型解析回退）、AC-19（三熱鍵可設定 + 衝突偵測）

---

## ⚠️ 規劃期發現

實作前必讀。以下是寫 plan 時交叉驗證 codebase / 跨里程碑 canon 發現的：

### 發現 1 — `ViewType` 新 case 的五處改動，只有三處有 compile 防護

| 位置 | 檔案:行 | 防護 | 漏掉的後果 |
|---|---|---|---|
| `detailView(for:)` | `ContentView.swift:69` | ✅ exhaustive | compile error（好） |
| `icon` | `AppSidebar.swift:157` | ✅ exhaustive | compile error（好） |
| `sidebarIconStyle` | `AppSidebar.swift:181` | ✅ exhaustive | compile error（好；顏色僅限 `AppTheme.Sidebar` 既有集，`AppTheme.swift:63`） |
| `title` | `AppSidebar.swift:120` | ❌ 有 `default:` | **靜默** fallback 成 rawValue 英文 |
| `sidebarSections` | `AppSidebar.swift:142` | ❌ 陣列 | **DEBUG assert crash**（`assertSidebarItemsCoverAllCases()`，`AppSidebar.swift:150`）；RELEASE 下側欄無此項、頁面失聯 |

且整個 `private extension ViewType` 是 **AppSidebar.swift file-private** —— 五處中四處只能在該檔內改，不能從新檔 extend。Task 7 一次補齊五處，手動驗證 gate 專門盯後兩處。

### 發現 2 — `ShortcutValidator.allStoredActions` 是 `private`，AC-19 測試只能行為式驗證

SRS 建議的測試「斷言三 action ∈ `allStoredActions`」**寫不出來**——`allStoredActions` 是 `private static var`（`ShortcutValidator.swift:436`）。改為行為式：先存一個鍵給會議 action，再問 `ShortcutValidator.validationError(for:action:)` 是否對其他 action 回 `.alreadyUsedBy`（雙向各測一次）。這其實是**更好**的測試——鎖的是使用者可感知的行為，不是私有實作。

### 發現 3 — 衝突偵測缺陷的修復歸屬：M4 修、M5 驗收（task 冪等）

根因：`allStoredActions = legacyKeyboardShortcutActions + modes`，而 `.toggleMeetingRecording` 只在 `globalUtilityActions`（`ShortcutAction.swift:100`）不在 `legacyKeyboardShortcutActions`（`ShortcutAction.swift:113`）→ 對衝突偵測隱形。M4 的 plan 應已把三個會議 action 加入 `legacyKeyboardShortcutActions`（安全：其 `legacyKeyboardShortcutsNames` 回 `[]`，migration no-op，`ShortcutMigration.swift:251`）。**Task 1 的測試先跑**：若 M4 已修，測試直接綠、IMPLEMENT 是 no-op；若沒修，M5 補上。這就是 SRS「若 M4 尚未登錄，M5 必須補上」的執行形。

### 發現 4 — `MeetingCopilotModels.resolve` 歸屬 M3，M5 條件式引入（task 冪等）

umbrella 把 `resolve()` 本體列 M3、行為驗收（FR-31/AC-18）列 M5。Task 3 先寫測試：若 M3 已提供該純函式，測試直接編過並綠；若沒有，M5 引入（完整實作在 Task 3 內，鏡射 `AskAIAnswerModel.resolve`，`AskAIConfig.swift:31-38`——已讀實檔確認簽章）。**兩份實作絕不並存**——動手前先 grep `MeetingCopilotModels`。

### 發現 5 — `sharingType = .none` 在 macOS 15.4+ 被 ScreenCaptureKit 忽略 → M5 文案的誠實義務

Apple DTS 明言「目前沒有公開 API 可防螢幕擷取」；Chrome/Meet 的 `getDisplayMedia` 走 SCK。overlay 面板屬 M4，但 M5 的頁面 infoMessage 與設定說明**不得宣稱 overlay 無條件隱形**——文案必須寫：安全模式是「分享單一視窗/分頁」，分享整個螢幕會被錄到。本 plan 的 UI 文案已照此寫死，實作時不要「潤飾」掉。

### 發現 6 — 本機 FluidAudio ASR 不支援術語偏置 → ASR picker 旁必須明示取捨

`VocabularyWord` 術語表只接到雲端串流 provider（Deepgram/Speechmatics/Soniox 的 `getCustomVocabularyTerms()`）；本機 Parakeet 完全沒有這條路徑。M1 已把這件事寫進 `MeetingCopilotConfigStore.asrModelName` 的 doc comment（實檔可查）。M5 的義務是把它**放到使用者眼前**：ASR picker 旁的 caption 文案（Task 5），不得暗示本機模型能吃術語表。

### 發現 7 — 三處 schema 註冊是 M2 的事，M5 絕不碰

master `Schema([...])`（`VoiceInk.swift:48`）+ `createPersistentContainer`（`:245`）+ `createInMemoryContainer`（`:302`）由 M2 完成。M5 只以 `@Query` 讀——`container.mainContext` 跨 store 透明，**不需要**separate context。若 M5 開工時 `meeting.store` 未註冊，`@Query<MeetingLiveSession>` 是 runtime 無資料（非 compile error）——回頭先完成 M2。

### 發現 8 — M2/M3 落地欄位名以實作為準（本 plan 用 SRS 命名書寫）

本 plan 的頁面程式碼引用 `MeetingLiveSession.startedAt / endedAt / remoteTranscriptRaw / localTranscriptRaw / cues` 與 `MeetingLiveCue.text / detectedAt / tier0Keywords / tier1Opener / tier1Bullets / tier2Analysis / tier2FollowUps / tier2Uncertainties`（SRS/umbrella 命名；陣列欄位是 JSON-in-raw + `@Transient` 快取存取器，比照 `Transcription.swift:73-610`）。**Task 4/6 動手前先 Read `VoiceInk/Models/MeetingLiveModels.swift`**，若 M2/M3 實際命名不同，以實作為準改 view 程式碼——顯示層跟著資料層走，不是反過來。

### 發現 9 — Optional Picker 的 `.tag()` 型別寫錯 = runtime 靜默失效

對 `Binding<RecorderModelChoice?>`，placeholder 必須 `.tag(RecorderModelChoice?.none)`、項目必須 `.tag(RecorderModelChoice?.some(c))`。寫 `.tag(c)`（非 optional）**不會 compile error**，但選取在 runtime 靜默壞掉。嚴格照 `RecorderModeSettingsView.swift:69` 的寫法。

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/meeting-copilot-m5-management-page.srs.md` | all | 需求 + AC + Open Questions 的定案（見本 plan 決策） |
| P0 | `VoiceInk/Models/MeetingLiveModels.swift`（M2 交付） | all | **欄位名校正**（發現 8）——頁面程式碼引用的每個欄位先對過 |
| P0 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift`（M3 擴充後） | all | 設定頁綁定的欄位/setter 名以此為準；M1 版只有三項 |
| P0 | `VoiceInk/Views/Library/VoiceLibraryView.swift` | 6-120（body/@Query/centeredModal）、207-300（VoiceRowDisplay/表頭/列） | **Task 6 clone 的對象**，欄寬對齊規則在此 |
| P0 | `VoiceInk/Views/Settings/RecorderModeSettingsView.swift` | 5-30（scaffold）、69-95（雙 Picker）、938-967（Binding 屬性） | **Task 5 clone 的對象** |
| P0 | `VoiceInk/Views/Sidebar/AppSidebar.swift` | 120-231（`private extension ViewType` 全部） | Task 7 的五處中四處都在這裡；file-private，只能改此檔 |
| P0 | `VoiceInk/Views/ContentView.swift` | 4-111（enum + `detailView(for:)`） | Task 7 的另一處；新頁 view 必須零參數 |
| P0 | 專案記憶 `voiceink-running-unit-tests` | all | **測試指令必須照它寫**，否則 host crash（CloudKit `_os_crash`） |
| P1 | `VoiceInk/Shortcuts/ShortcutAction.swift` | 100-123（`globalUtilityActions` / `legacyKeyboardShortcutActions`） | Task 1 的修補點與冪等判斷 |
| P1 | `VoiceInk/Shortcuts/ShortcutValidator.swift` | 25-97、436-442 | 衝突偵測入口 `validationError`；`allStoredActions` 是 private（發現 2） |
| P1 | `VoiceInk/Views/Settings/SettingsView.swift` | 78-125（Additional Shortcuts section）、349-352 | Task 2 的三 row 插入處與既有 row 樣式 |
| P1 | `VoiceInk/Services/AskAI/AskAIConfig.swift` | 24-40（`AskAIAnswerModel.resolve`） | Task 3 鏡射的純函式（已讀實檔，簽章確認） |
| P1 | `VoiceInk/Views/Settings/CategoriesSettingsView.swift` | 3-22（`RecorderModelChoice` + `recorderModelChoices(_:)`） | 兩個模型 picker 的資料源 |
| P1 | `VoiceInk/Views/Common/AppControls.swift` | 48-75（`AppPanelHeader`）、77-116（`AppScreenHeader`） | header 元件；title/infoMessage 是 `LocalizedStringKey` 只吃字面 |
| P2 | `VoiceInk/Views/Components/CenteredModal.swift` | 57-77 | modal chrome 由呼叫端供給 |
| P2 | `VoiceInk/Views/Common/AppTheme.swift` | 63+ | `AppTheme.Sidebar` 調色盤是封閉集；M5 重用 `.audio` |
| P2 | `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | 29-42（`resolvedAnalysisModel`） | resolve 回退的第二個先例（AIProvider 層） |
| P2 | 專案記憶 `voiceink-report-build-number`、`voiceink-build-no-ghost-apps` | all | bump build 並回報；不 build 進 /tmp；不自動 deploy |

## External Documentation

無需外部研究——全部使用既有內部 pattern。

---

## Patterns to Mirror

### VIEWTYPE_WIRING — detailView(for:) exhaustive switch（Task 7）
```swift
// SOURCE: VoiceInk/Views/ContentView.swift:68-110（節錄）
    @ViewBuilder
    private func detailView(for viewType: ViewType) -> some View {
        switch viewType {
        case .dashboard:
            DashboardView()
        case .models:
            ModelManagementView()
        // …
        case .history:
            VoiceLibraryView()
        // …
        case .license:
            LicenseManagementView()
        }
    }
```
> 所有 case 的 view **零參數**建構。新增 `case .meetingCopilot: MeetingCopilotPageView()`。

### SIDEBAR_PRIVATE_EXTENSION — title / sidebarSections / icon / sidebarIconStyle（Task 7，四處都在 AppSidebar.swift 這個 file-private extension 內）
```swift
// SOURCE: VoiceInk/Views/Sidebar/AppSidebar.swift:120-231（節錄）
private extension ViewType {
    var title: LocalizedStringKey {
        switch self {
        case .modes: return "Voice Modes"
        case .history: return "語音管理"
        // …
        default: return LocalizedStringKey(rawValue)   // ← 漏補不報錯，靜默英文
        }
    }

    static let sidebarSections: [(title: LocalizedStringKey?, items: [ViewType])] = [
        (nil, [.dashboard]),
        ("語音輸入", [.modes, .history, .voiceSettings]),
        ("錄音輸入", [.recorders, .recorderMode, .categories, .recorderLog, .transcribeAudio]),
        ("Ask AI", [.askAI, .askAITemplates]),
        ("共用與系統", [.prompts, .models, .systemTemplate, .templateGuide, .dictionary, .audio, .settings, .license]),
    ]

    static func assertSidebarItemsCoverAllCases() {
        #if DEBUG
        let sidebarItems = sidebarSections.flatMap { $0.items }
        assert(Set(sidebarItems) == Set(allCases) && sidebarItems.count == allCases.count)
        #endif
    }

    var icon: String {
        switch self {
        case .history: return "doc.text.fill"
        case .recorderLog: return "list.bullet.rectangle.fill"
        // …exhaustive，漏 = compile error
        }
    }

    var sidebarIconStyle: SidebarIconStyle {
        switch self {
        case .history:
            return .init(background: AppTheme.Sidebar.audio)
        case .recorderLog:
            return .init(background: AppTheme.Sidebar.audio)
        // …exhaustive，漏 = compile error；顏色僅限 AppTheme.Sidebar 既有集
        }
    }
}
```
> 純新頁**不需**改 `sidebarSection(_ items:)` 的 body——落入 generic `SidebarItemButton` 分支即可（`AppSidebar.swift:274-292`）。

### LIBRARY_PAGE — @Query + AppScreenHeader + centeredModal（Task 6 clone 的骨架）
```swift
// SOURCE: VoiceInk/Views/Library/VoiceLibraryView.swift:6-44, 695-703（節錄）
struct VoiceLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Transcription> { $0.importFingerprint == nil },
           sort: \Transcription.timestamp, order: .reverse)
    private var items: [Transcription]

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var sortField: VoiceSortField = .date
    @State private var sortAscending = false
    @State private var detailTarget: Transcription?

    enum VoiceSortField { case date, title, duration }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "語音管理",
                infoMessage: "語音輸入／聽寫的逐字稿。…",
                infoURL: nil
            ) { EmptyView() }

            searchBar
            Divider()
            // …表頭 + LazyVStack rows…
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            let q = newValue.trimmingCharacters(in: .whitespaces)
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                debouncedQuery = q
            }
        }
        .centeredModal(item: $detailTarget) { t in
            VoiceDetailSheet(transcription: t, onClose: { detailTarget = nil })
                .environmentObject(enhancementService)
                .frame(maxWidth: 900, maxHeight: 820)
                .background(AppTheme.Surface.window, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.Border.control, lineWidth: 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
    }
```
> 搜尋 debounce 250ms 進 `debouncedQuery`；filter/sort **在記憶體內**（computed props），不塞進 `#Predicate`。modal chrome（frame/background/圓角/陰影）由**呼叫端**供給；sheet 內用 `AppPanelHeader(title:onClose:)`。注意 `.environmentObject(...)` 要**顯式重注入** modal 內容。

### TABLE_HEADER — 欄寬手動對齊（Task 6）
```swift
// SOURCE: VoiceInk/Views/Library/VoiceLibraryView.swift:225-745（VoiceTableHeader 節錄）
    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 37, height: 1)   // 對齊：勾選(15)+星號(12)欄
            sortLabel("標題", field: .title).frame(maxWidth: .infinity, alignment: .leading)
            sortLabel("日期", field: .date).frame(width: 150, alignment: .leading)
            Text("Tag").frame(width: 110, alignment: .leading)
            sortLabel("時長", field: .duration).frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(height: 20)
        .padding(.horizontal, 24).padding(.vertical, 6)
    }

    private func toggle(_ field: VoiceLibraryView.VoiceSortField) {
        if sort == field { ascending.toggle() } else { sort = field; ascending = false }
    }
```
> 表頭與列都是 `HStack(spacing: 10)` + `.padding(.horizontal, 24)`，固定欄寬兩邊要一致。M5 沒有勾選/星號欄，不需要 `Color.clear` 前導。

### MODEL_PICKER — 兩個結構相同的 Picker（Task 5 抄兩次：fast/deep）
```swift
// SOURCE: VoiceInk/Views/Settings/RecorderModeSettingsView.swift:69-95（verbatim）
                Section("分析") {
                    Picker("預設分析模型", selection: analysisBinding) {
                        Text("自動（第一個可用）").tag(RecorderModelChoice?.none)
                        ForEach(recorderModelChoices(aiService), id: \.self) { c in
                            Text(c.label).tag(RecorderModelChoice?.some(c))
                        }
                    }
                    Text("套範本分析用的模型;個別類別可在「錄音筆範本」各自覆寫。")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

### BINDING_WRAPPER — private(set) @Published 的 Binding(get:set:)（Task 5 每個控制項一個）
```swift
// SOURCE: VoiceInk/Views/Settings/RecorderModeSettingsView.swift:938-958（verbatim）
    private var analysisBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.defaultAIProviderName, let m = store.defaultAIModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setDefaultModel(provider: $0?.provider, model: $0?.model) })
    }
    private var meetingMicBinding: Binding<Bool> {
        Binding(get: { store.meetingMicEnabled }, set: { store.setMeetingMicEnabled($0) })
    }
```
> scaffold：`@StateObject private var store = …ConfigStore.shared`（singleton 上加 @StateObject，house style）+ `@EnvironmentObject private var aiService: AIService`。nil ⇄「自動」的映射寫在 Binding 裡，不在 store。

### MODEL_CHOICES — picker 資料源（Task 5 直接呼叫，不重寫）
```swift
// SOURCE: VoiceInk/Views/Settings/CategoriesSettingsView.swift:4-22（verbatim）
struct RecorderModelChoice: Hashable {
    let provider: String
    let model: String
    var label: String { "\(provider) · \(model)" }
}

/// Flat list of selectable analysis models across the user's connected providers.
@MainActor func recorderModelChoices(_ aiService: AIService) -> [RecorderModelChoice] {
    var out: [RecorderModelChoice] = []
    for p in aiService.connectedProviders {
        let models = aiService.availableModels(for: p)
        if models.isEmpty {
            out.append(RecorderModelChoice(provider: p.rawValue, model: p.defaultModel))
        } else {
            for m in models { out.append(RecorderModelChoice(provider: p.rawValue, model: m)) }
        }
    }
    return out
}
```

### SHORTCUT_ROW — SettingsView 的 ShortcutRecorder row（Task 2/5 照抄三次）
```swift
// SOURCE: VoiceInk/Views/Settings/SettingsView.swift:78-92（verbatim）
Section("Additional Shortcuts") {
    LabeledContent("Paste Last Transcription (Original)") {
        ShortcutRecorder(action: .pasteLastTranscription) {
            recordingShortcutManager.updateShortcutStatus()
        }
            .controlSize(.small)
    }
// SOURCE: VoiceInk/Shortcuts/ShortcutRecorder.swift:14-23 — init 簽章
init(
    action: ShortcutAction,
    defaultShortcut: Shortcut? = nil,
    onShortcutChanged: @escaping () -> Void = {}
)
```
> `onShortcutChanged` **必須**呼叫 `recordingShortcutManager.updateShortcutStatus()` 讓 live event tap 重新武裝。plain toggle/peek row 不需要 `defaultShortcut`（它只影響顯示，不 seed）。

### CONFLICT_VALIDATION — 衝突偵測入口與清單（Task 1 的測試對象與修補點）
```swift
// SOURCE: VoiceInk/Shortcuts/ShortcutValidator.swift:25-45, 436-442（verbatim）
static func validationError(for shortcut: Shortcut, action: ShortcutAction) -> ShortcutValidationError? {
    if let error = userRecordingShortcutError(for: shortcut) {
        return error
    }
    if let reservedAction = reservedActionConflicting(with: shortcut) {
        return .alreadyUsedBy(reservedAction.displayName)
    }
    if systemReservedShortcuts.contains(where: { $0.conflicts(with: shortcut) }) {
        return .reservedBySystem
    }
    if let existingAction = storedActionConflicting(with: shortcut, excluding: action) {
        return .alreadyUsedBy(existingAction.displayName)
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

### RESOLVE_FALLBACK — 模型解析回退純函式（Task 3 鏡射，讀自實檔）
```swift
// SOURCE: VoiceInk/Services/AskAI/AskAIConfig.swift:25-40（verbatim）
/// Ask AI 專用「回答模型」設定與解析（與 embedding 模型、enhancement 預設分離，可單獨選更強的模型）。
enum AskAIAnswerModel {
    static let providerKey = "askAIAnswerProvider"
    static let modelKey = "askAIAnswerModel"

    /// 解析用哪個 provider/model 回答：曾設定且仍在可用清單內 → 用設定值;否則跟隨預設 provider（回 nil model）。
    /// 純函式（不碰 UserDefaults/AIService）以便測試。
    static func resolve(storedProvider: String?, storedModel: String?,
                        defaultProvider: String, available: [String]) -> (provider: String, model: String?) {
        if let sp = storedProvider, !sp.isEmpty, available.contains(sp) {
            let m = (storedModel?.isEmpty == false) ? storedModel : nil
            return (sp, m)
        }
        return (defaultProvider, nil)
    }
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
| `VoiceInk/Views/MeetingCopilot/MeetingCopilotPageView.swift` | CREATE | FR-29 管理頁（含 `MeetingRowDisplay` 純顯示 helper、表頭/列/詳情 sheet 私有子 view） |
| `VoiceInk/Views/Settings/MeetingCopilotSettingsView.swift` | CREATE | FR-30 完整設定 UI（SRS 指定路徑） |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotModels.swift` | CREATE（**條件式**：M3 未提供時才建） | FR-31 純函式 resolve；先 grep 確認不並存 |
| `VoiceInk/Views/ContentView.swift` | UPDATE | `ViewType` enum + `detailView(for:)` |
| `VoiceInk/Views/Sidebar/AppSidebar.swift` | UPDATE | `title` / `sidebarSections` / `icon` / `sidebarIconStyle` 四處（file-private extension） |
| `VoiceInk/Views/Settings/SettingsView.swift` | UPDATE | Additional Shortcuts 補三個會議熱鍵 row |
| `VoiceInk/Shortcuts/ShortcutAction.swift` | UPDATE（**條件式**：M4 未登錄時才改） | 三個會議 action 進 `legacyKeyboardShortcutActions`（AC-19） |
| `VoiceInk.xcodeproj/project.pbxproj` | UPDATE | `CURRENT_PROJECT_VERSION` 251 → 252（Debug + Release **兩處**） |
| `VoiceInkTests/MeetingShortcutTests.swift` | CREATE | AC-19（行為式衝突偵測） |
| `VoiceInkTests/MeetingCopilotModelsTests.swift` | CREATE | AC-18（resolve 回退） |
| `VoiceInkTests/MeetingCopilotPageTests.swift` | CREATE | `MeetingRowDisplay` 純 helper + `ViewType` case 存在鎖定 |

> **pbxproj**：專案用 `PBXFileSystemSynchronizedRootGroup`，新 `.swift` 檔自動入 target，不需手動註冊。唯一要改 pbxproj 的是 build number。

## NOT Building（M5 明確不做）

- **`meeting.store` / `@Model` 定義 / 三處 schema 註冊** → M2 的事（發現 7）
- **cue 偵測、三層回應、SSE、grounding** → M2/M3；M5 只呈現已落 SwiftData 的結果
- **overlay 面板、`sharingType`、event tap、peek keyDown/keyUp 分派** → M4；M5 零 `NSPanel` 改動
- 管理頁的**刪除 / 星號保護 / 批次操作** → v1 唯讀（SRS Open Question 定案：先讀不刪）
- 雙軌逐字稿**時間軸交錯合併** → 兩欄各自捲動（SRS Open Question 定案：省工方案）
- 會前 brief 的**檔案挑選**（Obsidian 筆記 / security-scoped bookmark）→ 純文字輸入 only，檔案挑選另案
- **可展開側欄子清單**（expandable 比照 recorderLog）→ 純 `SidebarItemButton`
- xcstrings 本地化 → 新頁面硬寫繁中字面（近期新頁面慣例）
- 新 `AppTheme.Sidebar` 顏色 → 重用 `.audio`（SRS Open Question 定案）
- 第二個 `ViewType` case 給設定頁 → 設定以 centeredModal 從管理頁開啟（SRS Open Question 7 定案：canon 只給一個 case；會議專屬設定集中在模組頁，`SettingsView` 只放三熱鍵 row）

---

## Step-by-Step Tasks

### Task 1: AC-19 — 三個會議熱鍵的衝突偵測（測試先行，實作冪等）

**Files:**
- Create: `VoiceInkTests/MeetingShortcutTests.swift`
- Modify（條件式）: `VoiceInk/Shortcuts/ShortcutAction.swift:113`

> M4 的 plan 應已把三個會議 action 加進 `legacyKeyboardShortcutActions`。**先跑測試**：綠了就代表 M4 修完，IMPLEMENT 跳過；紅了才動 `ShortcutAction.swift`。

- **ACTION**: 行為式驗證 `.toggleMeetingRecording` / `.toggleMeetingCopilotOverlay` / `.peekMeetingCopilotOverlay` 三者的鍵參與**雙向**衝突偵測（發現 2：`allStoredActions` 是 private，不能斷言清單成員，改測 `validationError` 行為）。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingShortcutTests.swift
import XCTest
import Carbon.HIToolbox
@testable import VoiceInk

/// AC-19:三個會議熱鍵皆可儲存且參與雙向衝突偵測（既有缺陷修復的驗收）。
/// `ShortcutValidator.allStoredActions` 是 private —— 只能行為式測:
/// 存一個鍵給 A,再問把同一個鍵給 B 是否被 .alreadyUsedBy 擋下。
@MainActor
final class MeetingShortcutTests: XCTestCase {

    private let meetingActions: [ShortcutAction] = [
        .toggleMeetingRecording, .toggleMeetingCopilotOverlay, .peekMeetingCopilotOverlay
    ]
    private let touchedActions: [ShortcutAction] = [
        .toggleMeetingRecording, .toggleMeetingCopilotOverlay,
        .peekMeetingCopilotOverlay, .pasteLastTranscription
    ]

    /// 冷門組合鍵,避開 systemReservedShortcuts 與使用者實際設定。
    private let probe = Shortcut.key(keyCode: UInt16(kVK_F18), modifierFlags: [.command, .option])

    private var savedDefaults: [String: Data] = [:]

    override func setUp() {
        super.setUp()
        for a in touchedActions {
            if let d = UserDefaults.standard.data(forKey: a.userDefaultsKey) {
                savedDefaults[a.userDefaultsKey] = d
            }
            UserDefaults.standard.removeObject(forKey: a.userDefaultsKey)
        }
    }

    override func tearDown() {
        for a in touchedActions {
            UserDefaults.standard.removeObject(forKey: a.userDefaultsKey)
            if let d = savedDefaults[a.userDefaultsKey] {
                UserDefaults.standard.set(d, forKey: a.userDefaultsKey)
            }
        }
        savedDefaults = [:]
        super.tearDown()
    }

    /// 三個 action 都必須是可儲存的（isStored default true;鎖住避免未來誤加排除 arm）。
    func testAllMeetingActionsAreStored() {
        for a in meetingActions {
            XCTAssertTrue(a.isStored, "\(a.storageName) 必須 isStored,否則 ShortcutRecorder 存不進去")
        }
    }

    /// 正向:會議 action 已佔用的鍵,指派給其他 action 必須被 .alreadyUsedBy 擋下。
    func testMeetingShortcutBlocksOtherActions() {
        ShortcutStore.setShortcut(probe, for: .toggleMeetingRecording)
        XCTAssertNotNil(ShortcutStore.shortcut(for: .toggleMeetingRecording), "seed 失敗——probe 鍵本身被 validator 拒絕?")

        let err = ShortcutValidator.validationError(for: probe, action: .pasteLastTranscription)
        guard case .alreadyUsedBy = err else {
            return XCTFail(".toggleMeetingRecording 的鍵對衝突偵測隱形（不在 allStoredActions）— got \(String(describing: err))")
        }
    }

    /// 反向:其他 action 已佔用的鍵,指派給每個會議 action 也要被擋（雙向）。
    func testOtherShortcutBlocksMeetingActions() {
        ShortcutStore.setShortcut(probe, for: .pasteLastTranscription)
        XCTAssertNotNil(ShortcutStore.shortcut(for: .pasteLastTranscription))

        for a in meetingActions {
            let err = ShortcutValidator.validationError(for: probe, action: a)
            XCTAssertNotNil(err, "\(a.storageName) 指派已被佔用的鍵必須報衝突")
        }
    }

    /// 兩個 overlay 熱鍵互撞也要被偵測（toggle 佔用 → peek 被擋）。
    func testOverlayHotkeysConflictWithEachOther() {
        ShortcutStore.setShortcut(probe, for: .toggleMeetingCopilotOverlay)
        XCTAssertNotNil(ShortcutStore.shortcut(for: .toggleMeetingCopilotOverlay))

        let err = ShortcutValidator.validationError(for: probe, action: .peekMeetingCopilotOverlay)
        guard case .alreadyUsedBy = err else {
            return XCTFail("overlay toggle/peek 互撞未被偵測 — got \(String(describing: err))")
        }
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
  Expected: 若 M4 已把三 action 加入 `legacyKeyboardShortcutActions` → **PASS**（本 task 完成，IMPLEMENT 跳過）；否則 `testMeetingShortcutBlocksOtherActions` / `testOverlayHotkeysConflictWithEachOther` **FAIL**（衝突未被偵測）。若 `.toggleMeetingCopilotOverlay`/`.peekMeetingCopilotOverlay` case 不存在 → **compile error** = M4 未完成，停下回頭做 M4。

- **IMPLEMENT**（僅在測試紅時）：把三個會議 action 追加到 `legacyKeyboardShortcutActions`（`ShortcutAction.swift:113`）：
```swift
    static let legacyKeyboardShortcutActions: [Self] = [
        .primaryRecording,
        .secondaryRecording,
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .cancelRecorder,
        .openHistoryWindow,
        .quickAddToDictionary,
        // 會議熱鍵納入衝突偵測（allStoredActions 由此清單構成）。
        // migration 安全:三者的 legacyKeyboardShortcutsNames 回 [] → migrateLegacyKeyboardShortcut no-op。
        .toggleMeetingRecording,
        .toggleMeetingCopilotOverlay,
        .peekMeetingCopilotOverlay
    ]
```

- **MIRROR**: `CONFLICT_VALIDATION`（修法 (a)：進 `legacyKeyboardShortcutActions`，不重寫 `allStoredActions`——侵入面最小）

- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingShortcutTests` — **PASS**（4 測試全綠）

- **GOTCHA**:
  - `ShortcutStore.setShortcut` 內部先跑 `validationError` 才存（`ShortcutStore.swift:34-38`）——所以 seed 用它（而不是裸寫 UserDefaults）順便清掉 cleared 標記；seed 後**必須**斷言 `shortcut(for:) != nil`，否則 probe 鍵被拒時測試會假綠。
  - `Shortcut.key(keyCode:modifierFlags:)` 的 flags 型別是 `NSEvent.ModifierFlags`（`Shortcut.swift:53`）。
  - `setShortcut` 會 post `shortcutDidChange` → `RecordingShortcutManager` 重新武裝 tap——host-app 測試內無害，但 tearDown 務必還原原值，別把使用者真實熱鍵洗掉。

- **COMMIT**: `test(meeting-copilot): lock bidirectional conflict detection for all three meeting hotkeys (AC-19)`（若有動 `ShortcutAction.swift` 則 `fix(shortcuts): include meeting actions in conflict detection (AC-19)`）

---

### Task 2: SettingsView 補三個會議熱鍵 row

**Files:**
- Modify: `VoiceInk/Views/Settings/SettingsView.swift:78+`（Additional Shortcuts section 內）

- **ACTION**: 修復「`.toggleMeetingRecording` 自 build 227 起沒有 UI 可設定」的缺陷，並讓 M4 的兩個 overlay 熱鍵在全域設定頁可設定（AC-19 的 UI 半部）。

- **TEST FIRST**: 無單元 seam（純 SwiftUI 宣告）。gate = 編譯 + Task 1 測試不退（衝突偵測已由 Task 1 鎖住）+ 手動驗證（見 VALIDATE）。這是 M1 Task 13 的既有先例（人工驗證工具類 task）。

- **IMPLEMENT**（插在既有 `LabeledContent("Retry Last Transcription")` row 之後、Cancel Recording row 之前；樣式逐字比照既有 row）：
```swift
                LabeledContent("切換會議錄製") {
                    ShortcutRecorder(action: .toggleMeetingRecording) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                        .controlSize(.small)
                }

                LabeledContent("切換會議輔助浮窗") {
                    ShortcutRecorder(action: .toggleMeetingCopilotOverlay) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                        .controlSize(.small)
                }

                LabeledContent("按住預覽會議輔助浮窗") {
                    ShortcutRecorder(action: .peekMeetingCopilotOverlay) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                        .controlSize(.small)
                }
```

- **MIRROR**: `SHORTCUT_ROW`（`SettingsView.swift:78-92`）——同一個 section、同縮排、同 `.controlSize(.small)`；`onShortcutChanged` 一律呼叫 `recordingShortcutManager.updateShortcutStatus()` 讓 live event tap 重新武裝

- **VALIDATE**:
  1. Compile gate（見 Validation Commands）— 零錯誤
  2. `-only-testing:VoiceInkTests/MeetingShortcutTests` — 仍 **PASS**
  3. 手動（deploy 後）：Settings → Additional Shortcuts 看得到三個新 row；錄一個鍵給「切換會議錄製」→ 按該鍵可啟停會議錄製；試把同一個鍵錄給「切換會議輔助浮窗」→ 被拒並顯示 already-used 通知

- **GOTCHA**: 不要給這三個 row 加 `defaultShortcut:` ——它只影響顯示、不 seed 儲存，且需要配套 reset Button + `shortcutDidChange` onReceive（`.cancelRecorder` row 那套），plain row 不需要。`recordingShortcutManager` 已是 `SettingsView` 的 `@EnvironmentObject`（`SettingsView.swift:10`），不需新注入。

- **COMMIT**: `feat(meeting-copilot): ShortcutRecorder rows for all three meeting hotkeys in SettingsView`

---

### Task 3: FR-31/AC-18 — MeetingCopilotModels.resolve（測試先行，實作冪等）

**Files:**
- Create: `VoiceInkTests/MeetingCopilotModelsTests.swift`
- Create（**條件式**）: `VoiceInk/Services/MeetingCopilot/MeetingCopilotModels.swift`

> **先 `grep -rn "MeetingCopilotModels" VoiceInk/`**：umbrella 把 `resolve()` 本體列 M3。若 M3 已建，本 task 只補測試；若沒有，M5 引入。兩份實作絕不並存（發現 4）。

- **ACTION**: fast/deep 的 stored provider 斷線（API key 被移除）時回退預設 provider——純函式、不 crash、不對失效 provider 發請求。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingCopilotModelsTests.swift
import XCTest
@testable import VoiceInk

/// AC-18:模型解析回退。純函式測試——available 直接注入,不碰 AIService/Keychain。
/// 呼叫端契約:available = aiService.connectedProviders.map(\.rawValue)。
final class MeetingCopilotModelsTests: XCTestCase {

    /// AC-18 主案例:stored provider（Groq）已斷線 → 回退預設 provider,model 歸 nil。
    /// 「不對失效 provider 發請求」由回傳值保證——resolve 是唯一的 provider 決策點,
    /// 回傳裡沒有 Groq,下游就不可能對 Groq 發任何請求。
    func testFallsBackWhenProviderDisconnected() {
        let r = MeetingCopilotModels.resolve(
            storedProvider: "Groq", storedModel: "llama-3.3-70b-versatile",
            defaultProvider: "Anthropic", available: ["Anthropic", "OpenAI"]
        )
        XCTAssertEqual(r.provider, "Anthropic")
        XCTAssertNil(r.model, "回退時不得沿用斷線 provider 的 model 名")
        XCTAssertNotEqual(r.provider, "Groq")
    }

    /// stored provider 仍連線 → 沿用設定值。
    func testUsesStoredWhenStillConnected() {
        let r = MeetingCopilotModels.resolve(
            storedProvider: "Groq", storedModel: "llama-3.3-70b-versatile",
            defaultProvider: "Anthropic", available: ["Anthropic", "Groq"]
        )
        XCTAssertEqual(r.provider, "Groq")
        XCTAssertEqual(r.model, "llama-3.3-70b-versatile")
    }

    /// 從未設定（nil/nil）→ 預設 provider + nil model（下游用 selectedModel(for:)/defaultModel）。
    func testNilStoredFallsBackToDefault() {
        let r = MeetingCopilotModels.resolve(
            storedProvider: nil, storedModel: nil,
            defaultProvider: "Anthropic", available: ["Anthropic"]
        )
        XCTAssertEqual(r.provider, "Anthropic")
        XCTAssertNil(r.model)
    }

    /// 空字串防守:provider 空字串視同未設定;連線 provider 存了空 model → model 歸 nil。
    func testEmptyStringsAreTreatedAsUnset() {
        let r1 = MeetingCopilotModels.resolve(
            storedProvider: "", storedModel: "x",
            defaultProvider: "Anthropic", available: ["Anthropic"]
        )
        XCTAssertEqual(r1.provider, "Anthropic")
        XCTAssertNil(r1.model)

        let r2 = MeetingCopilotModels.resolve(
            storedProvider: "OpenAI", storedModel: "",
            defaultProvider: "Anthropic", available: ["OpenAI", "Anthropic"]
        )
        XCTAssertEqual(r2.provider, "OpenAI")
        XCTAssertNil(r2.model)
    }
}
```
  Run: 完整指令 + `-only-testing:VoiceInkTests/MeetingCopilotModelsTests` — expect：M3 已提供 `resolve` → **PASS**（task 完成，只 commit 測試）；型別不存在 → **compile error**（往下實作）。

- **IMPLEMENT**（僅在 M3 未提供時）：
```swift
// VoiceInk/Services/MeetingCopilot/MeetingCopilotModels.swift
import Foundation

/// meeting-copilot fast / deep 回應模型的解析。
///
/// 鏡射 `AskAIAnswerModel.resolve`（AskAIConfig.swift:31-38）:純函式、不碰
/// UserDefaults / AIService,由呼叫端注入 `available = aiService.connectedProviders.map(\.rawValue)`。
/// picker 選項本就只列 connected provider（recorderModelChoices）,但**已存的舊選擇**可能
/// 指向後來斷線的 provider（API key 被移除）——這正是回退要擋的情境（FR-31 / AC-18）。
enum MeetingCopilotModels {

    /// 曾設定且 provider 仍連線 → 用設定值;否則回退預設 provider（model 回 nil,
    /// 下游以 `aiService.selectedModel(for:)` / `provider.defaultModel` 解析）。
    static func resolve(storedProvider: String?, storedModel: String?,
                        defaultProvider: String, available: [String]) -> (provider: String, model: String?) {
        if let sp = storedProvider, !sp.isEmpty, available.contains(sp) {
            let m = (storedModel?.isEmpty == false) ? storedModel : nil
            return (sp, m)
        }
        return (defaultProvider, nil)
    }
}
```

- **MIRROR**: `RESOLVE_FALLBACK`（`AskAIAnswerModel.resolve` 逐字同形）；AIProvider 層的先例是 `RecorderPostProcessor.resolvedAnalysisModel`（`RecorderPostProcessor.swift:29-42`：`aiService.connectedProviders.contains(p)` 檢查 + fallback）

- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingCopilotModelsTests` — **PASS**（4 測試全綠）

- **GOTCHA**: 若 M3 已提供但簽章不同（例如吃 `AIProvider` 而非 `String`），**改測試遷就 M3 實作**，不要動 M3 的函式——AC-18 驗的是「斷線回退、不 crash、不用失效 provider」這個行為，不是簽章。

- **COMMIT**: `test(meeting-copilot): lock model-resolution fallback on disconnected provider (AC-18)`

---

### Task 4: MeetingRowDisplay — 管理頁列顯示的純 helper

**Files:**
- Create: `VoiceInkTests/MeetingCopilotPageTests.swift`
- Create: `VoiceInk/Views/MeetingCopilot/MeetingCopilotPageView.swift`（本 task 先只放 `MeetingRowDisplay`；view 本體 Task 6）

> SwiftUI view 沒有穩定單元測試 seam，但**顯示邏輯**可以抽成純函式測——鏡射 `VoiceRowDisplay`（`VoiceLibraryView.swift:207`，檔內非 private enum）。helper 刻意**吃原始值不吃 @Model**，測試零 SwiftData 依賴。

- **ACTION**: 列標題（從開始時間組繁中標題）、時長文字（含進行中）、cue 數徽章。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingCopilotPageTests.swift
import XCTest
@testable import VoiceInk

final class MeetingCopilotPageTests: XCTestCase {

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        c.timeZone = TimeZone(identifier: "Asia/Taipei")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testTitleFromStartDate() {
        XCTAssertEqual(
            MeetingRowDisplay.title(startedAt: date(2026, 7, 12, 14, 30)),
            "7月12日 14:30 會議"
        )
    }

    func testDurationTextForFinishedMeeting() {
        let start = date(2026, 7, 12, 14, 0)
        XCTAssertEqual(
            MeetingRowDisplay.durationText(startedAt: start, endedAt: start.addingTimeInterval(47 * 60)),
            "47 分"
        )
    }

    func testDurationTextUnderOneMinute() {
        let start = date(2026, 7, 12, 14, 0)
        XCTAssertEqual(
            MeetingRowDisplay.durationText(startedAt: start, endedAt: start.addingTimeInterval(30)),
            "<1 分"
        )
    }

    /// endedAt nil = 會議進行中（session 已建、尚未 stop）。
    func testDurationTextForOngoingMeeting() {
        XCTAssertEqual(MeetingRowDisplay.durationText(startedAt: Date(), endedAt: nil), "進行中")
    }

    func testCueCountText() {
        XCTAssertEqual(MeetingRowDisplay.cueCountText(0), "—")
        XCTAssertEqual(MeetingRowDisplay.cueCountText(3), "3 則")
    }
}
```
  Run: `-only-testing:VoiceInkTests/MeetingCopilotPageTests` — expect **FAIL**（型別不存在）

- **IMPLEMENT**:
```swift
// VoiceInk/Views/MeetingCopilot/MeetingCopilotPageView.swift（本 task 先建檔放 helper;view 本體 Task 6 補）
import SwiftUI
import SwiftData

// MARK: - Row display helpers

/// 管理頁列的顯示邏輯。非 private、吃原始值不吃 @Model —— 供單元測試
/// （鏡射 `VoiceRowDisplay`,VoiceLibraryView.swift:207 的檔內非 private enum 慣例）。
enum MeetingRowDisplay {

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    /// 列標題:會議沒有使用者命名,一律從開始時間組(例:「7月12日 14:30 會議」)。
    static func title(startedAt: Date) -> String {
        titleFormatter.string(from: startedAt) + " 會議"
    }

    /// 時長:「47 分」;不足 1 分「<1 分」;endedAt nil = 進行中。
    static func durationText(startedAt: Date, endedAt: Date?) -> String {
        guard let end = endedAt else { return "進行中" }
        let minutes = Int(end.timeIntervalSince(startedAt) / 60)
        return minutes < 1 ? "<1 分" : "\(minutes) 分"
    }

    /// cue 數徽章:0 顯示「—」。
    static func cueCountText(_ count: Int) -> String {
        count == 0 ? "—" : "\(count) 則"
    }
}
```

- **MIRROR**: `VoiceRowDisplay`（`VoiceLibraryView.swift:207`——同檔、非 private、static 顯示 helper）+ `TEST_STRUCTURE`

- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingCopilotPageTests` — **PASS**（5 測試全綠）

- **GOTCHA**: formatter 固定 `zh_TW` + `Asia/Taipei`——新頁面硬寫繁中的慣例延伸；固定 timeZone 讓測試在任何機器上確定性通過。

- **COMMIT**: `feat(meeting-copilot): MeetingRowDisplay pure display helpers for management page`

---

### Task 5: MeetingCopilotSettingsView — 完整設定 UI（FR-30）

**Files:**
- Create: `VoiceInk/Views/Settings/MeetingCopilotSettingsView.swift`

> **開工前先 Read `MeetingCopilotConfigStore.swift`（M3 擴充後的版本）**。M1 已確認的欄位/setter：`copilotEnabled`/`setCopilotEnabled`、`asrModelName`/`setASRModelName`、`transcribeLocalMic`/`setTranscribeLocalMic`（實檔已讀）。M3 欄位本 plan 以 canon 命名書寫：`fastProviderName`/`fastModelName`/`setFastModel(provider:model:)`、`deepProviderName`/`deepModelName`/`setDeepModel(provider:model:)`、`prefetchEnabled`/`setPrefetchEnabled`、`domainPersona`/`setDomainPersona`、`useHistoryRAG`/`setUseHistoryRAG`、`useScreenContext`/`setUseScreenContext`——**若 M3 實際命名不同，以實作為準改本檔**。

- **ACTION**: 一頁收攏：啟用開關、三熱鍵 `ShortcutRecorder`、ASR picker（含無術語偏置明示）、fast/deep 雙模型 picker、會前 brief、四個 grounding/音源開關。以 sheet 形式存在（`AppPanelHeader` + onClose），由 Task 6 的管理頁開啟。

- **TEST FIRST**: 無單元 seam（每個控制項都是 `Binding(get:set:)` 直通 store 的 `set…()` mutator，而 store 的持久化已由 M1/M3 各自的測試鎖住；view 宣告本身無行為可鎖）。gate = 編譯（`private(set)` 保證：若有任何控制項直接綁 `store.x`，**compile error**——這正是本 task 的型別級測試）+ 手動驗證。

- **IMPLEMENT**:
```swift
// VoiceInk/Views/Settings/MeetingCopilotSettingsView.swift
import SwiftUI

/// 會議輔助完整設定。以 centeredModal 從 MeetingCopilotPageView 的「設定」按鈕開啟
/// （M5 決策:canon 只給一個 ViewType case,設定不另開側欄頁;SettingsView 只放三熱鍵 row）。
///
/// scaffold clone `RecorderModeSettingsView`（RecorderModeSettingsView.swift:5）:
/// `@StateObject` singleton + `@EnvironmentObject aiService` + 每個控制項一個 `Binding(get:set:)`
/// —— store 的 @Published 是 `private(set)`,直接綁定是 compile error,必須走 `set…()` mutator。
struct MeetingCopilotSettingsView: View {
    @StateObject private var store = MeetingCopilotConfigStore.shared
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager

    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "會議輔助設定", onClose: onClose)

            Form {
                Section("啟用") {
                    Toggle("啟用會議即時輔助", isOn: copilotEnabledBinding)
                    Text("開啟後,會議錄製時即時轉錄雙軌音訊並偵測需要回應的 cue。關閉時對既有錄音流程零影響、零成本。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("熱鍵") {
                    LabeledContent("切換會議錄製") {
                        ShortcutRecorder(action: .toggleMeetingRecording) {
                            recordingShortcutManager.updateShortcutStatus()
                        }
                            .controlSize(.small)
                    }
                    LabeledContent("切換會議輔助浮窗") {
                        ShortcutRecorder(action: .toggleMeetingCopilotOverlay) {
                            recordingShortcutManager.updateShortcutStatus()
                        }
                            .controlSize(.small)
                    }
                    LabeledContent("按住預覽會議輔助浮窗") {
                        ShortcutRecorder(action: .peekMeetingCopilotOverlay) {
                            recordingShortcutManager.updateShortcutStatus()
                        }
                            .controlSize(.small)
                    }
                    Text("與「設定 → Additional Shortcuts」是同一份儲存,兩處改任一處都生效,並互相參與衝突偵測。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("即時轉錄（ASR）") {
                    Picker("轉錄模型", selection: asrModelBinding) {
                        ForEach(streamingModelNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    // 規劃期發現 6:本機 ASR 無術語偏置的明示——不得暗示本機模型能吃術語表。
                    Text("本機模型（Parakeet）免 API key、音訊不出本機,但不支援術語偏置——專案代號、服務名（如「Kafka」）容易轉錯,轉錯會直接影響 cue 偵測。需要術語準確度請改用雲端串流模型（Deepgram / Speechmatics / Soniox,支援字典術語）。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("快速回應模型（fast）") {
                    Picker("fast 模型", selection: fastBinding) {
                        Text("自動（第一個可用）").tag(RecorderModelChoice?.none)
                        ForEach(recorderModelChoices(aiService), id: \.self) { c in
                            Text(c.label).tag(RecorderModelChoice?.some(c))
                        }
                    }
                    Text("cue 抽取與 Tier 1 開口稿用的模型;選延遲低的小模型。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("深度回應模型（deep）") {
                    Picker("deep 模型", selection: deepBinding) {
                        Text("自動（第一個可用）").tag(RecorderModelChoice?.none)
                        ForEach(recorderModelChoices(aiService), id: \.self) { c in
                            Text(c.label).tag(RecorderModelChoice?.some(c))
                        }
                    }
                    Text("Tier 2 深度分析用的模型。已存的選擇若 provider 斷線（移除 API key）,會自動回退預設,不會用失效的 key 發請求。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("會前 brief") {
                    TextEditor(text: briefBinding)
                        .frame(minHeight: 88)
                        .font(.system(size: 12))
                    Text("這場會議的背景:目的、我的立場、關鍵數字。所有回應都會參考。純文字;檔案匯入另案。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("接地與音源") {
                    Toggle("預先起跑最新 cue（prefetch）", isOn: prefetchBinding)
                    Toggle("檢索歷史逐字稿（RAG）", isOn: ragBinding)
                    Toggle("擷取螢幕內容（僅深度分析）", isOn: screenBinding)
                    Toggle("同時轉錄我的麥克風", isOn: localMicBinding)
                    // 規劃期發現 5:誠實文案——不宣稱 overlay 無條件隱形。
                    Text("接地來源取用失敗一律靜默降級,不中斷回應。提醒:分享「整個螢幕」時,輔助浮窗仍可能被錄進會議畫面（macOS 15.4+ 無法對 ScreenCaptureKit 隱藏）——安全模式是分享單一視窗或瀏覽器分頁。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Bindings（store 的 @Published 是 private(set),必須走 set…() mutator）

    private var copilotEnabledBinding: Binding<Bool> {
        Binding(get: { store.copilotEnabled }, set: { store.setCopilotEnabled($0) })
    }
    private var asrModelBinding: Binding<String> {
        Binding(get: { store.asrModelName }, set: { store.setASRModelName($0) })
    }
    private var fastBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.fastProviderName, let m = store.fastModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setFastModel(provider: $0?.provider, model: $0?.model) })
    }
    private var deepBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.deepProviderName, let m = store.deepModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setDeepModel(provider: $0?.provider, model: $0?.model) })
    }
    private var briefBinding: Binding<String> {
        Binding(get: { store.domainPersona }, set: { store.setDomainPersona($0) })
    }
    private var prefetchBinding: Binding<Bool> {
        Binding(get: { store.prefetchEnabled }, set: { store.setPrefetchEnabled($0) })
    }
    private var ragBinding: Binding<Bool> {
        Binding(get: { store.useHistoryRAG }, set: { store.setUseHistoryRAG($0) })
    }
    private var screenBinding: Binding<Bool> {
        Binding(get: { store.useScreenContext }, set: { store.setUseScreenContext($0) })
    }
    private var localMicBinding: Binding<Bool> {
        Binding(get: { store.transcribeLocalMic }, set: { store.setTranscribeLocalMic($0) })
    }

    /// 串流 ASR 模型清單（M1 的 MeetingReplayDebugRunner.swift:55 同款取法）。
    private var streamingModelNames: [String] {
        TranscriptionModelRegistry.models.filter { $0.supportsStreaming }.map { $0.name }
    }
}
```

- **MIRROR**: `BINDING_WRAPPER` + `MODEL_PICKER` + `MODEL_CHOICES` + `SHORTCUT_ROW`

- **VALIDATE**:
  1. Compile gate — 零錯誤（`private(set)` 型別級把關：直接綁定會在這裡爆）
  2. `-only-testing:VoiceInkTests/MeetingShortcutTests` — 仍 PASS
  3. 手動（Task 6 接上後）：每個控制項改一下 → 重啟 app → 值保留（走了 `set…()` + UserDefaults）

- **GOTCHA**:
  - **Optional tag 型別必須精確**（發現 9）：`.tag(RecorderModelChoice?.none)` / `.tag(RecorderModelChoice?.some(c))`，寫 `.tag(c)` 是 runtime 靜默失效。
  - ASR picker 綁 `Binding<String>`（非 optional），tag 直接用 `name`——只有 optional selection 才有上述陷阱。
  - `TranscriptionModelRegistry` 的公開存取子是 `models`（`TranscriptionModelRegistry.swift:5`，實檔已確認），不是 M1 plan 草稿寫的 `allModels`。
  - M3 欄位名若不同以實作為準（見 task 開頭）；`domainPersona` 若 M3 存成 `String?`，briefBinding 比照 `languageBinding`（`RecorderModeSettingsView.swift:963`）做 `?? ""` + trim-to-nil。

- **COMMIT**: `feat(meeting-copilot): MeetingCopilotSettingsView — hotkeys, ASR/fast/deep pickers, brief, grounding toggles (FR-30)`

---

### Task 6: MeetingCopilotPageView — 會議列表 + 詳情 modal（FR-29）

**Files:**
- Modify: `VoiceInk/Views/MeetingCopilot/MeetingCopilotPageView.swift`（Task 4 建的檔，補 view 本體）

> **開工前先 Read `VoiceInk/Models/MeetingLiveModels.swift`** 校正欄位名（發現 8）。以下程式碼用 SRS 命名：session 的 `startedAt / endedAt / remoteTranscriptRaw / localTranscriptRaw / cues`；cue 的 `text / detectedAt / tier0Keywords / tier1Opener / tier1Bullets / tier2Analysis / tier2FollowUps / tier2Uncertainties`（陣列欄位 = JSON-in-raw + `@Transient` 快取存取器，M2/M3 交付）。命名不同 → view 遷就模型。

- **ACTION**: clone `VoiceLibraryView` 的骨架：`@Query` 反序 + `AppScreenHeader`（trailing 放「設定」按鈕）+ 250ms debounce 搜尋 + 記憶體內排序 + 表頭/列 + `.centeredModal(item:)` 詳情 + `.centeredModal(isPresented:)` 設定。

- **TEST FIRST**: 顯示邏輯已由 Task 4 的 `MeetingCopilotPageTests` 鎖住（列標題/時長/cue 數）。view 組裝本身無單元 seam——gate = 編譯（`@Query`/`centeredModal`/`AppScreenHeader` 的型別檢查）+ Task 7 之後的手動驗證（列表顯示、搜尋、排序、詳情內容）。

- **IMPLEMENT**（追加到 Task 4 的檔案；`MeetingRowDisplay` 保持不動）：
```swift
// MARK: - Page

/// 會議錄音管理頁——clone VoiceLibraryView 的表格/搜尋/排序/centeredModal 結構
/// （VoiceLibraryView.swift:6）。唯讀消費 M2 的 meeting.store;v1 不做刪除/星號/批次。
struct MeetingCopilotPageView: View {
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager

    @Query(sort: \MeetingLiveSession.startedAt, order: .reverse)
    private var sessions: [MeetingLiveSession]

    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var sortField: MeetingSortField = .date
    @State private var sortAscending = false
    @State private var detailTarget: MeetingLiveSession?
    @State private var showSettings = false

    enum MeetingSortField { case date, duration, cueCount }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "會議錄音管理",
                infoMessage: "會議即時輔助的歷史紀錄:每場會議的雙軌逐字稿（對方／我）、偵測到的 cue 與三層回應。點一列看詳情。提醒:分享「整個螢幕」時輔助浮窗可能被錄進會議畫面,安全模式是分享單一視窗或分頁。",
                infoURL: nil
            ) {
                Button {
                    showSettings = true
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
            }

            searchBar
            Divider()

            if filteredSessions.isEmpty {
                emptyState
            } else {
                MeetingTableHeader(sort: $sortField, ascending: $sortAscending)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedSessions) { s in
                            MeetingSessionRow(session: s, onOpen: { detailTarget = s })
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            let q = newValue.trimmingCharacters(in: .whitespaces)
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                debouncedQuery = q
            }
        }
        .centeredModal(item: $detailTarget) { session in
            MeetingDetailSheet(session: session, onClose: { detailTarget = nil })
                .frame(maxWidth: 900, maxHeight: 820)
                .background(AppTheme.Surface.window, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.Border.control, lineWidth: 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
        .centeredModal(isPresented: $showSettings) {
            MeetingCopilotSettingsView(onClose: { showSettings = false })
                // centeredModal 內容不繼承外層 environment,顯式重注入
                //（比照 VoiceLibraryView.swift:695 的 .environmentObject(enhancementService)）。
                .environmentObject(aiService)
                .environmentObject(recordingShortcutManager)
                .frame(maxWidth: 640, maxHeight: 760)
                .background(AppTheme.Surface.window, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.Border.control, lineWidth: 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
    }

    // MARK: - Search / sort（記憶體內,比照 VoiceLibraryView 的 filteredItems/sortedItems）

    private var filteredSessions: [MeetingLiveSession] {
        guard !debouncedQuery.isEmpty else { return Array(sessions) }
        let q = debouncedQuery.localizedLowercase
        return sessions.filter { s in
            MeetingRowDisplay.title(startedAt: s.startedAt).localizedLowercase.contains(q)
                || s.remoteTranscriptRaw.localizedLowercase.contains(q)
                || s.localTranscriptRaw.localizedLowercase.contains(q)
        }
    }

    private var sortedSessions: [MeetingLiveSession] {
        let base = filteredSessions
        let sorted: [MeetingLiveSession]
        switch sortField {
        case .date:
            sorted = base.sorted { $0.startedAt < $1.startedAt }
        case .duration:
            sorted = base.sorted {
                ($0.endedAt?.timeIntervalSince($0.startedAt) ?? 0) < ($1.endedAt?.timeIntervalSince($1.startedAt) ?? 0)
            }
        case .cueCount:
            sorted = base.sorted { ($0.cues?.count ?? 0) < ($1.cues?.count ?? 0) }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜尋逐字稿內容…", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.2.wave.2").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(debouncedQuery.isEmpty ? "還沒有會議紀錄——開啟會議輔助後,錄製的會議會出現在這裡。" : "沒有符合搜尋的會議。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Table header（欄寬與 MeetingSessionRow 手動對齊,改一邊要改另一邊）

private struct MeetingTableHeader: View {
    @Binding var sort: MeetingCopilotPageView.MeetingSortField
    @Binding var ascending: Bool

    var body: some View {
        HStack(spacing: 10) {
            sortLabel("會議", field: .date).frame(maxWidth: .infinity, alignment: .leading)
            sortLabel("時長", field: .duration).frame(width: 80, alignment: .leading)
            sortLabel("Cue", field: .cueCount).frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(height: 20)
        .padding(.horizontal, 24).padding(.vertical, 6)
    }

    private func sortLabel(_ label: String, field: MeetingCopilotPageView.MeetingSortField) -> some View {
        Button { toggle(field) } label: {
            HStack(spacing: 3) {
                Text(label)
                if sort == field {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
        }.buttonStyle(.plain)
    }

    private func toggle(_ field: MeetingCopilotPageView.MeetingSortField) {
        if sort == field { ascending.toggle() } else { sort = field; ascending = false }
    }
}

// MARK: - Row

private struct MeetingSessionRow: View {
    let session: MeetingLiveSession
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(MeetingRowDisplay.title(startedAt: session.startedAt))
                .font(.system(size: 13, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(MeetingRowDisplay.durationText(startedAt: session.startedAt, endedAt: session.endedAt))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            Text(MeetingRowDisplay.cueCountText(session.cues?.count ?? 0))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

// MARK: - Detail sheet（雙軌逐字稿兩欄各自捲動 + cue 三層;chrome 由呼叫端供給）

private struct MeetingDetailSheet: View {
    let session: MeetingLiveSession
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "會議詳情", onClose: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    transcripts
                    cueSection
                }
                .padding(20)
            }
        }
    }

    /// 雙軌逐字稿:兩欄各自捲動（SRS Open Question 定案:不做時間軸交錯合併）。
    private var transcripts: some View {
        HStack(alignment: .top, spacing: 12) {
            transcriptColumn(title: "對方（remote）", text: session.remoteTranscriptRaw)
            transcriptColumn(title: "我（local）", text: session.localTranscriptRaw)
        }
        .frame(height: 260)
    }

    private func transcriptColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(text.isEmpty ? "（無內容）" : text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(AppTheme.Surface.window.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity)
    }

    private var cueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("偵測到的 cue（\(sortedCues.count)）")
                .font(.system(size: 13, weight: .semibold))
            if sortedCues.isEmpty {
                Text("這場會議沒有偵測到需要回應的 cue。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(sortedCues) { cue in
                    MeetingCueCard(cue: cue)
                }
            }
        }
    }

    private var sortedCues: [MeetingLiveCue] {
        (session.cues ?? []).sorted { $0.detectedAt < $1.detectedAt }
    }
}

/// 一則 cue 的三層回應。已產生的層才顯示（Tier 1/2 可能因會議提前結束而缺）。
private struct MeetingCueCard: View {
    let cue: MeetingLiveCue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(cue.text)
                .font(.system(size: 12, weight: .semibold))
                .textSelection(.enabled)

            if !cue.tier0Keywords.isEmpty {
                tierRow(label: "Tier 0 關鍵字", body: cue.tier0Keywords.joined(separator: "、"))
            }

            if !cue.tier1Opener.isEmpty {
                tierRow(label: "Tier 1 開口稿", body: cue.tier1Opener)
                ForEach(cue.tier1Bullets, id: \.self) { b in
                    Text("• \(b)").font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.leading, 8)
                }
            }

            if !cue.tier2Analysis.isEmpty {
                tierRow(label: "Tier 2 分析", body: cue.tier2Analysis)
                if !cue.tier2FollowUps.isEmpty {
                    tierRow(label: "追問", body: cue.tier2FollowUps.joined(separator: "\n"))
                }
                if !cue.tier2Uncertainties.isEmpty {
                    tierRow(label: "不確定之處", body: cue.tier2Uncertainties.joined(separator: "\n"))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Surface.window.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func tierRow(label: String, body text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 11)).textSelection(.enabled)
        }
    }
}
```

- **MIRROR**: `LIBRARY_PAGE`（body 骨架 + debounce + centeredModal chrome）+ `TABLE_HEADER`（欄寬手動對齊 + sortLabel/toggle）+ `CENTERED_MODAL`

- **VALIDATE**:
  1. Compile gate — 零錯誤
  2. `-only-testing:VoiceInkTests/MeetingCopilotPageTests` — 仍 PASS
  3. 手動驗證留到 Task 7（頁面接上側欄後才能開）

- **GOTCHA**:
  - `@Query` 跨 store 透明（`container.mainContext`），**不要**為 meeting.store 建 separate context；但 `#Predicate` 只能引用同 store 型別——所以搜尋全部走記憶體，這也與 `VoiceLibraryView` 一致。
  - cue 陣列欄位（`tier0Keywords` 等）是 M2/M3 的 `@Transient` 快取存取器——在 `ForEach` 裡重複讀是 O(1)（cache keyed on raw），不需要自己再包。
  - `session.cues` 是 optional 陣列（cascade relationship 的 house pattern，`AskAIModels.swift:41`）——一律 `?? []`。
  - centeredModal 內容**不繼承外層 environment**——`.environmentObject` 顯式重注入（`VoiceLibraryView.swift:695` 先例），漏了會在開 modal 時 runtime crash（`Fatal error: No ObservableObject of type AIService found`）。
  - `AppScreenHeader` 的 `title`/`infoMessage` 是 `LocalizedStringKey` **只吃字面**——不要抽成 `String` 常數。

- **COMMIT**: `feat(meeting-copilot): MeetingCopilotPageView — session list, dual-track transcript + tiered cue detail (FR-29)`

---

### Task 7: ViewType.meetingCopilot — 五處導覽接線

**Files:**
- Modify: `VoiceInk/Views/ContentView.swift`（enum + `detailView(for:)`）
- Modify: `VoiceInk/Views/Sidebar/AppSidebar.swift`（`title` / `sidebarSections` / `icon` / `sidebarIconStyle` 四處）
- Modify: `VoiceInkTests/MeetingCopilotPageTests.swift`（追加 enum 鎖定測試）

- **ACTION**: 新 case 五處補齊。compile gate 擋得住 `detailView`/`icon`/`sidebarIconStyle` 三處；`title` 與 `sidebarSections` **沒有 compile 防護**（發現 1），靠測試 + DEBUG assert + 手動。

- **TEST FIRST**（追加到 `MeetingCopilotPageTests`）：
```swift
    /// 鎖定 ViewType case 存在與 rawValue（rawValue = Identifiable id + AppNavigator log 字串,改了會斷導覽持久化）。
    func testMeetingCopilotViewTypeExists() {
        XCTAssertTrue(ViewType.allCases.contains(.meetingCopilot))
        XCTAssertEqual(ViewType.meetingCopilot.rawValue, "Meeting Copilot")
        XCTAssertEqual(ViewType.meetingCopilot.id, "Meeting Copilot")
    }
```
  Run: `-only-testing:VoiceInkTests/MeetingCopilotPageTests` — expect **FAIL**（case 不存在，compile error）

- **IMPLEMENT**:

  1. `ContentView.swift:4` — enum 加 case（放在 `.license` 前，`CaseIterable` 順序影響不大但保持群聚）：
```swift
    case askAITemplates = "Ask AI Templates"
    case meetingCopilot = "Meeting Copilot"
    case settings = "Settings"
```
  2. `ContentView.swift:69` — `detailView(for:)` 加 arm（exhaustive，漏了此處根本編不過）：
```swift
        case .meetingCopilot:
            MeetingCopilotPageView()
```
  3. `AppSidebar.swift:120` — `title`（⚠️ 有 `default:`，**漏了不報錯**，會靜默顯示英文 rawValue）：
```swift
        case .recorderLog: return "Recording Management"
        case .meetingCopilot: return "會議錄音管理"
```
  4. `AppSidebar.swift:142` — `sidebarSections`：加入「錄音輸入」組末（SRS Open Question 定案：不另開 section，與錄音管線相鄰；⚠️ 漏了 = DEBUG assert crash / RELEASE 頁面失聯）：
```swift
        ("錄音輸入", [.recorders, .recorderMode, .categories, .recorderLog, .transcribeAudio, .meetingCopilot]),
```
  5. `AppSidebar.swift:157` — `icon`（exhaustive）：
```swift
        case .meetingCopilot: return "person.2.wave.2.fill"
```
  6. `AppSidebar.swift:181` — `sidebarIconStyle`（exhaustive；重用既有 `.audio`，與 history/recorderLog 同族——都是「錄下來的東西的管理頁」）：
```swift
        case .meetingCopilot:
            return .init(background: AppTheme.Sidebar.audio)
```

- **MIRROR**: `VIEWTYPE_WIRING` + `SIDEBAR_PRIVATE_EXTENSION`

- **VALIDATE**:
  1. Compile gate — 零錯誤（三個 exhaustive switch 的把關在此）
  2. `-only-testing:VoiceInkTests/MeetingCopilotPageTests` — **PASS**（含新測試）
  3. **手動（DEBUG build，這步不可省——`sidebarSections`/`title` 的唯二防線）**：`make deploy` 後開 app →
     - 側欄「錄音輸入」組末出現「會議錄音管理」且**沒有** assert crash（`assertSidebarItemsCoverAllCases` 在 sidebar onAppear 跑）
     - 側欄項顯示**繁中**「會議錄音管理」而非英文 "Meeting Copilot"（title arm 生效）
     - 點擊 → 管理頁開啟；header「設定」→ 設定 modal 開啟、各控制項可操作
     - 若 M2 replay 已產生過 session → 列表有資料、詳情雙軌逐字稿與 cue 三層正確呈現

- **GOTCHA**:
  - `private extension ViewType` 是 AppSidebar.swift **file-private**——四處只能在該檔內改，不能從新檔 extend。
  - `sidebarSection(_ items:)` 的 body **不用改**——純新頁落入 generic `SidebarItemButton` 分支（`AppSidebar.swift:274`）。不要加 `else if viewType == .meetingCopilot`（那是 expandable 子清單才需要的，M5 不做）。
  - SF Symbol `person.2.wave.2.fill` 需 macOS 13+（本專案 target 滿足）；若 asset 缺失（render 成問號）就換 `quote.bubble.fill`——icon 只是顯示，不影響功能。
  - `AppTheme.Sidebar` 是封閉集（`AppTheme.swift:63`）——只能用既有 static let，`.init(background:)` 不吃任意 Color。

- **COMMIT**: `feat(meeting-copilot): ViewType.meetingCopilot — sidebar page wired in all five switch sites (FR-29)`

---

### Task 8: Bump build 252 + 全套迴歸

**Files:**
- Modify: `VoiceInk.xcodeproj/project.pbxproj`（`CURRENT_PROJECT_VERSION` 251 → **252**，**Debug + Release 兩處都要**）

- **ACTION**: 收尾。

- **VALIDATE**:
  1. **全套測試**（不只新的——確認零回歸）：
     ```bash
     xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
       -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
       -xcconfig LocalBuild.xcconfig \
       CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
       CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
       SWIFT_ENABLE_EXPLICIT_MODULES=NO
     ```
     EXPECT: **全綠**——特別是既有的 Shortcut 相關測試（Task 1 動了衝突清單）與 M1–M4 的 `Meeting*` 測試
  2. `grep -c "CURRENT_PROJECT_VERSION = 252" VoiceInk.xcodeproj/project.pbxproj` → **2**
  3. **回報 build 號給使用者**（專案記憶 `voiceink-report-build-number`），提醒 `make deploy` 後到 Settings → About 確認 build 252

- **COMMIT**: `chore: bump build to 252 (meeting-copilot M5)`

---

## Testing Strategy

### Unit Tests

| Test | Input | Expected | AC |
|---|---|---|---|
| `MeetingShortcutTests::testAllMeetingActionsAreStored` | 三個會議 action | `isStored == true` | AC-19 |
| `…::testMeetingShortcutBlocksOtherActions` | 鍵先給 `.toggleMeetingRecording`，再驗 `.pasteLastTranscription` | `.alreadyUsedBy` | 🔴 AC-19 |
| `…::testOtherShortcutBlocksMeetingActions` | 鍵先給 `.pasteLastTranscription`，再驗三個會議 action | 全部非 nil（雙向） | 🔴 AC-19 |
| `…::testOverlayHotkeysConflictWithEachOther` | toggle 佔用 → peek | `.alreadyUsedBy` | AC-19 |
| `MeetingCopilotModelsTests::testFallsBackWhenProviderDisconnected` | stored=Groq，available 無 Groq | `("Anthropic", nil)`，回傳無 Groq | 🔴 AC-18 |
| `…::testUsesStoredWhenStillConnected` | stored=Groq，available 含 Groq | 沿用設定 | AC-18 |
| `…::testNilStoredFallsBackToDefault` / `…::testEmptyStringsAreTreatedAsUnset` | nil / "" 邊界 | 預設 provider + nil model | AC-18 |
| `MeetingCopilotPageTests::testTitleFromStartDate` 等 5 項 | Date/秒數/計數 | 繁中顯示字串（含「進行中」「<1 分」「—」） | FR-29 |
| `…::testMeetingCopilotViewTypeExists` | — | case 存在 + rawValue 鎖定 | FR-29 |

### Edge Cases Checklist
- [x] 熱鍵衝突偵測**雙向**（會議→其他、其他→會議、overlay 互撞）
- [x] resolve：斷線 provider / nil / 空字串 / 空 model
- [x] 進行中會議（`endedAt == nil`）
- [x] 0 則 cue 的會議（詳情 empty state）
- [x] Tier 1/2 尚未產生的 cue（只顯示已有的層）
- [x] 空搜尋 / 無結果搜尋
- [ ] **provider 斷線後開設定頁**——picker 已存選擇不在清單中的顯示行為（手動：應顯示回「自動」而非空白）
- [ ] **meeting.store 無資料**（M2 未跑過）——頁面 empty state（手動）

---

## Validation Commands

### 編譯（快速 gate，不啟動 host）
```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  CODE_SIGNING_ALLOWED=NO SWIFT_ENABLE_EXPLICIT_MODULES=NO build
```
EXPECT: 零錯誤。exhaustive switch（`detailView`/`icon`/`sidebarIconStyle`/`storageName`/`displayName`）與 `private(set)` 直綁的把關都在這一步。

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

> 🔴 **為什麼不能用普通 `xcodebuild test`**（專案記憶 `voiceink-running-unit-tests`）：`VoiceInkTests` 是 **host-app** bundle，runner 會啟動 `VoiceInk.app`。未簽章時 SwiftData 的 `dictionary` store 走 `.private("iCloud...")` CloudKit → `_os_crash`，host 開機即死。完整形式鏡射 `make local`（ad-hoc 簽章 + `LOCAL_BUILD` flag）。`SWIFT_ENABLE_EXPLICIT_MODULES=NO` 必要，否則 Xcode 16+ `@testable import` 失敗。**`-only-testing` 仍會編譯所有測試檔**——任一檔編譯錯誤 = 整輪失敗。

### 部署（**人工執行，不要自動跑**）
```bash
make deploy
```
> 專案記憶：不要 build 進 /tmp；不自動 deploy——由使用者自己跑，Settings → About 確認 build 252。

### 手動驗證
- [ ] 側欄出現「會議錄音管理」（**繁中**，非英文 rawValue）且無 DEBUG assert crash
- [ ] 管理頁：列表 / 搜尋 / 三欄排序 / 點列開詳情（雙軌逐字稿 + cue 三層）
- [ ] 設定 modal：每個控制項改動後重啟 app 值保留
- [ ] fast/deep picker 選一個模型 → 移除該 provider 的 API key → 重啟 → 功能回退預設、不 crash（AC-18 的實機面）
- [ ] Settings → Additional Shortcuts 三個新 row；錄鍵可用；衝突鍵被拒（AC-19 的 UI 面）
- [ ] `.toggleMeetingRecording` 錄鍵後按鍵可啟停會議錄製（修復驗證）
- [ ] 既有 19 個頁面照常開啟（sidebar 零回歸）

---

## Acceptance Criteria

- [ ] **AC-18**（模型解析回退）：`MeetingCopilotModelsTests` 全綠——stored provider 斷線 → 回退預設、不 crash、回傳值不含失效 provider（= 不可能對其發請求）；fast/deep 同一純函式
- [ ] **AC-19**（三熱鍵可設定 + 衝突偵測）：`MeetingShortcutTests` 全綠（雙向 `.alreadyUsedBy`）+ 手動確認 `SettingsView` 與 `MeetingCopilotSettingsView` 三個 `ShortcutRecorder` row 皆可操作
- [ ] **FR-29**（頁面）：`@Query` 反序列表 + 記憶體內搜尋/排序 + centeredModal 詳情（雙軌 + 三層）——構建通過 + `MeetingCopilotPageTests` 綠 + 手動肉眼驗收（SwiftUI view 無穩定單元 seam，SRS 明定此驗收方式）
- [ ] **FR-30**（設定）：全部控制項經 `Binding(get:set:)` 走 `set…()` mutator（compile gate 把關）+ 手動持久化驗證
- [ ] **FR-31**：resolve 純函式，鏡射 `AskAIAnswerModel.resolve`，兩份實作不並存
- [ ] 全套測試零回歸；編譯零錯誤零新警告
- [ ] Build 252（pbxproj 兩處），已回報給使用者

## Completion Checklist
- [ ] 五處 `ViewType` 接線全補（含無 compile 防護的 `title` / `sidebarSections`）
- [ ] Optional Picker tag 全部精確型別（`.none` / `.some(c)`）
- [ ] 所有新 UI 文案硬寫繁中；ASR 無術語偏置明示在 picker 旁；無任何「無條件隱形」宣稱
- [ ] centeredModal 內容有顯式 `.environmentObject` 重注入
- [ ] 沒有超出 M5 範圍的新增（無 @Model / 無 schema 註冊 / 無 NSPanel / 無 event tap 改動 / 無刪除功能）
- [ ] 冪等 task（1、3）沒有留下重複實作（grep `MeetingCopilotModels`、檢查 `legacyKeyboardShortcutActions` 無重複項）

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **M2/M3 落地欄位名與 plan 書寫不同**（`endedAt`/`tier1Bullets` 等） | M | M — view/測試編不過 | 發現 8：Task 4/5/6 開工前先 Read 模型檔與 config store；view 遷就資料層 |
| `title`/`sidebarSections` 漏補（無 compile 防護） | M | M–H — 靜默英文標題 / DEBUG crash / RELEASE 頁面失聯 | Task 7 測試 + 手動 gate 專門盯這兩處；`assertSidebarItemsCoverAllCases` 綠燈 |
| Optional Picker tag 型別寫錯 → 選取 runtime 靜默失效 | M | M | 發現 9；嚴格照 `RecorderModeSettingsView.swift:69`；手動驗證「選了會變」 |
| M4 未把三 action 放進衝突清單 → AC-19 不成立 | M | M | Task 1 測試先行 + 冪等修補（M5 自己補得上） |
| `MeetingShortcutTests` 汙染使用者真實熱鍵設定 | L | M | setUp/tearDown 完整 save/restore `userDefaultsKey`；seed 走 `ShortcutStore.setShortcut`（自動清 cleared 標記） |
| centeredModal 內 environment 缺失 → 開設定 modal 即 crash | M | M | 顯式 `.environmentObject(aiService/recordingShortcutManager)`（`VoiceLibraryView.swift:695` 先例）；手動開一次 modal |
| **overlay 隱蔽文案過度承諾**（macOS 15.4+ SCK 忽略 `sharingType`） | H（若文案亂寫） | H — 使用者在分享整螢幕時暴露私人筆記 | 發現 5：頁面 infoMessage 與設定 caption 已寫死誠實版本，實作不得改寫 |
| `meeting.store` 未註冊（M2 未完成就開工） | L | M — `@Query` runtime 無資料 | 依賴鏈前置檢查（見 Notes）；症狀 = 永遠 empty state |
| resolve 兩份實作並存（M3 也寫了一份） | L | L | Task 3 開工先 grep；有就只補測試 |

## Notes

- **本 plan 依賴 M2 → M3 → M4 全部先完成**：
  - **M2** 提供 `meeting.store` 三處註冊 + `MeetingLiveSession`/`MeetingLiveCue` `@Model`（管理頁的資料源）；
  - **M3** 提供 `MeetingCopilotConfigStore` 的 fast/deep/grounding 欄位與 setter（設定頁的綁定對象），以及（依 umbrella 歸屬）`MeetingCopilotModels.resolve` 本體；
  - **M4** 提供 `.toggleMeetingCopilotOverlay`/`.peekMeetingCopilotOverlay` 兩個 `ShortcutAction` case（`storageName`/`displayName`/`legacyKeyboardShortcutsNames` 三個 exhaustive switch 的 arm）與其在 `globalUtilityActions`/衝突清單的登錄。
  缺 M4 → Task 1/2/5 **compile error**；缺 M3 → Task 5 compile error；缺 M2 → Task 6/7 compile error 或頁面永遠空。任何一個缺，**停下來先完成前置里程碑**，不要在 M5 裡「順手」實作前置件——那會跟對應 plan 撞出兩份實作。
- M5 完成後整個 meeting-copilot 模組收攏：引擎（M2/M3）、即時呈現（M4）、回顧與組態（M5）。記得跑 `/prp-spec` 把五個里程碑的實作回寫進 `docs/spec/meeting-copilot.spec.md` 的 Change History。
