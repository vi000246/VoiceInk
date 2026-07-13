---
linear_issue: null
---
# SRS: Meeting Copilot M7 — 預設講稿讀稿器(自寫講稿的私人提詞面板)

## Metadata
- **Module**: `meeting-copilot`
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source PRD**: N/A(2026-07-13 使用者需求)
- **Source Linear Issue**: N/A
- **Created**: 2026-07-13
- **Grill level**: 1(標準)

## Feature Summary

一個**私人提詞面板(teleprompter / presenter notes)**:使用者事先寫好多份具名講稿(自我介紹、
對某議題的立場…),開會時用一個浮動面板私下看著唸。等同 PowerPoint 簡報者檢視 / 電視讀稿機——
**只顯示使用者自己寫的文字**,不聽對方、不生成任何內容。動機:ADHD 看稿的安全感 + 不想讓
同事看到自己在照稿。

## 範圍界線(本功能與 AI 即時回應的明確切割)

> 這是本 SRS 最重要的一節,後續實作不得逾越。

- **只顯示使用者自己輸入的文字。** 面板內容 100% 來自使用者在設定頁打的講稿。
- **完全不接 AI/ASR。** 讀稿器**不啟動** live pipeline、**不呼叫**任何 ASR、**不呼叫**任何 LLM、
  **不讀** `MeetingCopilotController.cues`。它與 `MeetingCopilotController` / `AnswerCoordinator` /
  `MeetingLiveTranscriber` 之間**零耦合、零引用**。
- **獨立於 copilot 監聽開關。** `copilotEnabled == false`、沒有任何會議在錄音時,讀稿器**照常可用**
  ——它只是一個顯示你自己文字的視窗,不需要任何即時輔助基礎設施在跑。
- **不做「即時偵測問題 → 建議講稿」的連動。** 不偵測對方問句、不自動高亮、不自動切稿。
  切換講稿一律**手動**。
- **不整合進 `CopilotOverlayView`(AI cue 清單那個面板)。** 讀稿器是**獨立的 panel + view**,
  它的「清單」是**你自己的講稿清單**,不是 AI 偵測到的問題清單。

上述界線一旦要放寬(例如把 AI 生成的答案餵進這個面板、或依對方問題自動選稿),屬於另一個
需求,不在本 SRS,且需重新評估。

## Delta from Current Module State

> 現況見 `docs/spec/meeting-copilot.spec.md`。本功能是**新增的獨立子功能**,不改動既有 live pipeline。

### New / Changed API Endpoints

N/A — 本機 app。

### New / Changed Data Models

新增(存 UserDefaults,非 SwiftData → 免 schema 註冊、免 migration):

```
struct PresenterScript: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String   // chip 顯示用(如「自我介紹」)
    var body: String    // 讀稿正文(多行純文字)
}
```

儲存:`PresenterScriptStore`(`@MainActor ObservableObject`),UserDefaults key
`meetingCopilotPresenterScriptsV1`,值為 `[PresenterScript]` 的 JSON。鏡射
`MeetingCopilotConfigStore` 的 `…V1` key + `@Published private(set)` + `set…()` 慣例。
另存 `meetingCopilotPresenterFontSizeV1`(讀稿字級,預設 22,夾在 14…40)。

### Changed Business Logic

新增元件(全部在 `meeting-copilot` 模組,但**不觸及** live pipeline):
- `PresenterScriptStore` — CRUD + 持久化。
- `PresenterScriptPanel` — 鏡射 `CopilotOverlayPanel` 的螢幕分享排除 + 不搶焦點 + 手動拖曳特性,
  但 root view 掛 `PresenterScriptView`,**不持有任何 controller**。
- `PresenterScriptWindowManager` — 鏡射 `CopilotOverlayWindowManager` 的 show/hide/toggle/手動拖曳/
  近鏡頭錨定;`ObservableObject` 暴露 `isPinned` 供按鈕/熱鍵共用。
- `PresenterScriptView` — 兩層導覽(講稿清單 ↔ 讀稿檢視)+ 頂部標題 chips 快速切換 + 大字讀稿區。
- `MeetingCopilotSettingsView` 新增「預設講稿」section(list / 新增 / 編輯 / 刪除)。
- `ShortcutAction.togglePresenterScript` 新熱鍵(4 處註冊)+ `MenuBarView` toggle。

### Explicitly Out of Scope

- 任何 AI/ASR/LLM 連動(見範圍界線)。
- 依對方問題自動選稿/自動高亮。
- 講稿雲端同步、跨裝置(僅本機 UserDefaults)。
- 講稿 Markdown 渲染(純文字即可;正文照原樣換行顯示)。
- 匯入/匯出講稿檔(未來可加)。

## Functional Requirements

- [ ] **FR-33 講稿資料與儲存**:`PresenterScript{id,title,body}`;`PresenterScriptStore`
      以 UserDefaults JSON 持久化;`add/update(id)/delete(id)/move` mutator;啟動載入。
- [ ] **FR-34 設定頁講稿管理**:`MeetingCopilotSettingsView` 新增「預設講稿」section——
      列出現有講稿(標題 + 正文前綴),可新增、編輯(標題 + 多行正文)、刪除;空清單有提示。
- [ ] **FR-35 讀稿浮動面板**:`PresenterScriptPanel`(`sharingType = .none`、`.nonactivatingPanel`、
      `canBecomeKey = false`、`level = .screenSaver`、手動拖曳)。**獨立於 live pipeline**:
      show 不需要 `MeetingCopilotController`、不需要任何會議在錄音。
- [ ] **FR-36 兩層導覽 + chips 切換**:預設顯示**講稿清單**(標題列表);點一則 → 進**讀稿檢視**
      (大字正文);讀稿檢視頂部一排標題 chips,點任一即直接切到該稿;常駐「← 講稿清單」
      按鈕一鍵回清單。切換/回清單皆單擊完成。
- [ ] **FR-37 可讀性**:讀稿正文大字級(預設 22pt)、A−/A+ 可即時調整並持久化;深色實心底 +
      白字高對比(鏡射 cue overlay,恆不透明);正文全文換行不截斷、可捲動。
- [ ] **FR-38 召喚/隱藏**:新增全域熱鍵 `togglePresenterScript`(於 `ShortcutAction` 兩份清單、
      `ShortcutMigration`、`RecordingShortcutManager` 分派、`SettingsView` 熱鍵頁四處註冊)+
      `MenuBarView` 一個 toggle;面板手動拖曳定位、不搶焦點(不帶出 VoiceInk 主視窗)。
- [ ] **FR-39 誠實邊界**:面板常駐螢幕分享警告條(分享**整個螢幕**時 macOS 15.4+ 仍會被錄到,
      安全模式=只分享單一視窗/分頁);**不得**宣稱無條件隱形(沿用 cue overlay 的既有警語)。
- [ ] **FR-40 與 AI 解耦(硬界線)**:讀稿器不建立/不引用 `MeetingLiveTranscriber` /
      `MeetingCopilotController` / `AnswerCoordinator`;不啟動 ASR、不呼叫 LLM、不讀 cue 清單;
      `copilotEnabled == false` 時仍完全可用。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| **與 AI 解耦** | 讀稿器編譯期不依賴 live pipeline 任何型別;開面板 0 次 ASR/LLM 呼叫 | 獨立 panel/manager/view/store;測試斷言 |
| 獨立性 | copilot 關閉、無會議錄音時照常可用 | 不 gate 在 `copilotEnabled`、不需要 `MeetingCopilotController` |
| 可讀性(ADHD) | 大字級可調(14–40)、高對比不透明 | 深色實心底 + 白字 + A−/A+ |
| 隱私 | 講稿僅存本機 | UserDefaults;不落雲、不進網路 |
| 誠實(隱蔽邊界) | 不宣稱無條件隱形 | 常駐警告條(沿用既有 SCK 限制文案) |
| 零回歸 | 既有 cue overlay / live pipeline 行為不變 | 全新檔案,既有檔僅加法(設定 section、熱鍵、選單列 toggle) |
| 焦點契約 | 面板永不搶焦點、不帶出主視窗 | `canBecomeKey=false` + `orderFrontRegardless` + 手動拖曳(不走 activation) |

## Architecture Notes

### 為什麼是獨立面板,而非 cue overlay 的一個分頁

使用者原始描述提到「快速回到問題清單」,把讀稿器想成 AI cue overlay 的一個模式。本 SRS
**刻意不這樣做**:cue overlay 承載的是即時 AI 回應;把讀稿器做成它的分頁,會把「顯示我自己的稿」
和「AI 即時代答」綁成同一個產品。讀稿器改為**獨立面板**,它的「清單」是你自己的講稿清單——
既完整滿足「看著自己的稿唸、隨時切回清單」,又與 AI 回應保持乾淨切割。兩者若要同時開,是兩個
各自獨立的視窗,不互相引用。(決策:2026-07-13。)

### 鏡射來源(pattern reuse,非機能耦合)

`PresenterScriptPanel` / `…WindowManager` **複製** `CopilotOverlayPanel`(:14-48)/
`CopilotOverlayWindowManager` 的**視窗技術**(螢幕分享排除、不搶焦點、`NSEvent.mouseLocation`
手動拖曳、近鏡頭錨定),但**不複製其機能**(不持有 controller、不接 onCueTapped)。
複製的是「怎麼開一個隱蔽浮動視窗」,不是「即時輔助」。

### 熱鍵註冊(4 處,漏一即失效)

沿用既有 `.toggleMeetingCopilotOverlay` 的接線路徑,新增 `togglePresenterScript`:
`ShortcutAction`(enum case + `storageName` + `displayName` + `globalUtilityActions` +
`legacyKeyboardShortcutActions`)、`ShortcutMigration`(exhaustive switch)、
`RecordingShortcutManager`(keyUp 分派 → `PresenterScriptWindowManager.shared.toggle()`)、
`SettingsView` 熱鍵頁(`ShortcutRecorder`)。**漏 `SettingsView` 則熱鍵無法設定**(FR-32 的既有教訓)。

## Acceptance Criteria

> 純 seam 測試(UserDefaults round-trip、無 CoreAudio、無真 LLM),鏡射 `VoiceInkTests/` 慣例。

### AC-20: 講稿 CRUD 持久化
- **Given**: 空的 `PresenterScriptStore`
- **When**: 新增兩則講稿,再以同一 key 重建 store
- **Then**: 兩則講稿以原順序、原 title/body 載回
- **Test**: `PresenterScriptStoreTests::persistsAcrossReload`

### AC-21: 讀稿檢視顯示選定正文
- **Given**: store 有講稿「自我介紹」body = X
- **When**: 讀稿器選「自我介紹」
- **Then**: 讀稿區顯示 X 全文(換行保留、不截斷)
- **Test**: `PresenterScriptViewModelTests::readingShowsSelectedBody`

### AC-22: chip 切換 + 回清單
- **Given**: 讀稿檢視正顯示講稿 A,存在講稿 B
- **When**: 點 B 的 chip → 再點「← 講稿清單」
- **Then**: 先切到 B 正文;再回到講稿清單層
- **Test**: `PresenterScriptViewModelTests::chipSwitchesAndBackReturnsToList`

### AC-23: 獨立於會議錄音的召喚
- **Given**: `copilotEnabled == false`、無任何會議 session
- **When**: 觸發 `togglePresenterScript`
- **Then**: 讀稿面板顯示;**未**建立 `MeetingCopilotController` / transcriber / coordinator
- **Test**: `PresenterScriptWindowManagerTests::togglesWithoutLivePipeline`

### AC-24: 面板隱蔽且不搶焦點
- **Given**: 讀稿面板
- **When**: 建立並顯示
- **Then**: `sharingType == .none`、`canBecomeKey == false`;顯示不激活 app(主視窗不跳前景)
- **Test**: `PresenterScriptPanelTests::isScreenShareExcludedNonActivating`

### AC-25: 硬界線——零 AI/ASR
- **Given**: 讀稿器整個生命週期(開→切稿→關)
- **When**: 全程執行
- **Then**: 0 次 ASR 送音、0 次 LLM 呼叫、0 次讀取 `MeetingCopilotController.cues`
      (以無 live pipeline 依賴的建構 + 型別隔離保證;測試以「不引用」的編譯期事實 + 行為斷言)
- **Test**: `PresenterScriptWindowManagerTests::neverTouchesPipeline`

### AC-26: 字級調整持久化
- **Given**: 讀稿字級預設 22
- **When**: 按 A+ 兩次(→ 24),重啟 store
- **Then**: 載回 24(夾在 14…40)
- **Test**: `PresenterScriptStoreTests::fontSizePersistsClamped`

### AC-27: 空清單提示
- **Given**: 無任何講稿
- **When**: 開讀稿面板
- **Then**: 顯示「尚無講稿——到『會議copilot設定 → 預設講稿』新增」提示,不崩潰
- **Test**: `PresenterScriptViewModelTests::emptyStateHint`

## Open Questions

- [ ] 是否要在「會議錄製指示器」也放一顆讀稿按鈕?(目前定位:讀稿器獨立於會議,主要走全域熱鍵 +
      選單列 toggle;指示器按鈕會把它綁回會議情境,暫不做。)
- [ ] 講稿是否需要匯入/匯出(例如從 Obsidian 筆記貼入)?本版純手打;未來可接 `VaultExportService`。
- [ ] 讀稿檢視是否需要「自動捲動 / 捲動速度」(真讀稿機特性)?本版手動捲動;視使用回饋再加。
