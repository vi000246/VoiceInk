---
linear_issue: null
---
# Plan: Recorder Mode & Manual Recording Management

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type` (feature). Mode B —
> task-level test-first: pure-logic seams get a failing test first; pages/queue/AI wiring are
> verified manually (see Manual Validation). Several R1/R10/R11 items already shipped in earlier
> commits — this plan covers the remaining new work (Recorder Mode page, manual flow, Recording
> Management actions).

## Summary
Decouple recorder transcription from voice Modes (new **Recorder Mode** settings), make template
application + Obsidian export a **manual, reviewable** flow (default), and turn the recorder log
into a full **Recording Management** page (apply template → preview → export; delete audio / record).
Raw audio + transcript are always preserved.

## User Story
As a recorder owner, I want the recorder to use its own transcription model and let me review each
recording, pick a template, preview, and export to Obsidian on my terms — so my raw transcripts stay
intact for later AI analysis and nothing is processed or exported without my say-so.

## Problem → Solution
Today (M2): recorder transcription follows the active voice Mode, and import auto-classifies +
auto-enhances + auto-exports. → New: recorder has its own model settings; import only transcribes +
suggests a category; apply + export happen manually in Recording Management.

## Metadata
- **Module**: recorder-automation
- **Parent Plan**: N/A
- **Source PRD**: `docs/prd/recorder-auto-import-and-template-routing.prd.md`
- **Source Feature SRS**: `docs/srs/recorder-automation-recorder-mode-and-recording-management.srs.md`
- **Source Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source Linear Issue**: N/A
- **Type**: feature
- **Size**: L
- **Complexity**: Large
- **Rigor**: balanced
- **Mode**: B — 任務先測
- **TDD**: on (pure-logic seams); manual for pages/AI/queue
- **Commit cadence**: per-task
- **Estimated Files**: 4 new, 8 modified

---

## UX Design

### Before (M2)
```
插入錄音筆 → 用「作用中語音模式」轉錄 → AI 分類 → 自動套範本 → 自動匯出 Obsidian（零點擊）
匯入紀錄 = 唯讀清單
```

### After
```
插入錄音筆 → 用「錄音筆模式」轉錄（與語音模式無關）→ AI 只建議分類 → 停
錄音管理頁：挑分類/範本 → 套用（AI）→ 預覽「套用後」→ 匯出 Obsidian / 刪音檔 / 刪紀錄
（可選開關恢復全自動）
```

### Interaction Changes
| Touchpoint | Before | After | Notes |
|---|---|---|---|
| 轉錄模型來源 | 作用中語音模式 | 錄音筆模式 | 新設定頁 |
| 套範本 + 匯出 | 匯入即自動 | 錄音管理手動（預設） | 可開關回自動 |
| 匯入紀錄 | 唯讀 | 可套用/匯出/刪除 | 改名「錄音管理」 |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/recorder-automation-recorder-mode-and-recording-management.srs.md` | all | FR/AC source |
| P0 | `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` | all | Where new settings + recorderPrompts live |
| P0 | `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | all | Refactor classify/apply/export into callable units |
| P0 | `VoiceInk/Services/RecorderAutomation/RecorderImportService.swift` | 60-90,handleMount | Build recorder transcription config; auto/manual branch |
| P0 | `VoiceInk/Services/AudioFileTranscriptionManager.swift` | 72-90,115-266 | startProcessing(mode:); recorder branch in processItem |
| P0 | `VoiceInk/Modes/ModeConfig.swift` | 64-126 | ModeConfig init — build a synthetic recorder transcription config |
| P0 | `VoiceInk/Modes/ModeRuntimeConfiguration.swift` | 3-127 | transcriptionConfiguration resolver; EnhancementRuntimeConfiguration.replacing |
| P1 | `VoiceInk/Views/History/RecorderHistoryView.swift` | all | Becomes Recording Management; reuse cards |
| P1 | `VoiceInk/Views/Settings/CategoriesSettingsView.swift` | DefaultModelCard, recorderModelChoices | Move default-model card to Recorder Mode; reuse model picker helper |
| P1 | `VoiceInk/Views/Settings/RecordersSettingsView.swift` | VaultRootCard, AppScreenHeader | Card + page patterns to mirror |
| P1 | `VoiceInk/Views/ContentView.swift` + `Views/Sidebar/AppSidebar.swift` | ViewType + sidebarSections | Add `.recorderMode`; rename recorderLog→Recording Management |
| P1 | `VoiceInk/Modes/Components/PromptSelectionGrid.swift` / `ModeConfigFormView.swift:163` | transcription model picker | How transcription models are listed (`transcriptionModelManager.usableModels`) |
| P2 | `VoiceInk/Views/History/InlineHistoryView.swift` | AudioPlayerView/Markdown usage | Card components to reuse |

## External Documentation

> None — all internal patterns (SwiftData, SwiftUI, existing recorder services).

---

## Patterns to Mirror

### CONFIG_STORE (UserDefaults-backed published settings)
```swift
// SOURCE: VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift (vaultRoot/defaultModel)
@Published private(set) var vaultRootBookmark: Data?
func setVaultRoot(_ bookmark: Data?) { vaultRootBookmark = bookmark; /* UserDefaults set/remove */ }
```

### MODEL_PICKER_HELPER (reuse for analysis model; transcription is separate list)
```swift
// SOURCE: VoiceInk/Views/Settings/CategoriesSettingsView.swift:recorderModelChoices
@MainActor func recorderModelChoices(_ aiService: AIService) -> [RecorderModelChoice] { ... }
// Transcription models come from a DIFFERENT source:
//   engine.transcriptionModelManager.usableModels  (name + displayName)
```

### TRANSCRIPTION_CONFIG_RESOLVE
```swift
// SOURCE: VoiceInk/Modes/ModeRuntimeConfiguration.swift:62-86
// transcriptionConfiguration(mode:) uses mode.selectedTranscriptionModelName, else usableModels.first.
// → Build a synthetic ModeConfig whose selectedTranscriptionModelName = Recorder Mode's model.
```

### ENHANCE_WITH_MODEL (manual apply)
```swift
// SOURCE: VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift
let cfg = baseConfig.replacing(prompt: prompt, provider: model.provider, modelName: model.modelName)
let (enhanced, _, _) = try await enhancementService.enhance(rawText, configuration: cfg)
```

### SIDE_PANEL_CARD_PAGE
```swift
// SOURCE: VoiceInk/Views/Settings/RecordersSettingsView.swift (AppScreenHeader + cards + .sidePanel)
AppScreenHeader(title: "...", infoMessage: "...", infoURL: nil) { AppIconButton(...) }
```

### RECORDER_QUERY_CARD (Recording Management list)
```swift
// SOURCE: VoiceInk/Views/History/RecorderHistoryView.swift
@Query(filter: #Predicate<Transcription> { $0.importFingerprint != nil },
       sort: \Transcription.timestamp, order: .reverse) private var items: [Transcription]
// reuse AudioPlayerView / MarkdownContentView / CopyIconButton
```

### TEST_STRUCTURE
```swift
// SOURCE: VoiceInkTests/RecorderPipelineTests.swift (XCTest, @MainActor, pure seams)
@MainActor final class RecorderModeTests: XCTestCase { ... }
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` | UPDATE | Recorder Mode settings (transcription model, language, formatting, autoExport) |
| `VoiceInk/Services/RecorderAutomation/RecorderTranscriptionConfig.swift` | CREATE | Build synthetic transcription ModeConfig from Recorder Mode |
| `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | UPDATE | Split into suggestCategory / applyTemplate / export; branch auto vs manual |
| `VoiceInk/Services/RecorderAutomation/RecorderImportService.swift` | UPDATE | Use recorder transcription config; pass auto/manual intent |
| `VoiceInk/Services/AudioFileTranscriptionManager.swift` | UPDATE | Recorder branch: post-process honours manual default |
| `VoiceInk/Views/Settings/RecorderModeSettingsView.swift` | CREATE | New Recorder Mode page |
| `VoiceInk/Views/Settings/CategoriesSettingsView.swift` | UPDATE | Remove DefaultModelCard (moved to Recorder Mode) |
| `VoiceInk/Views/History/RecorderHistoryView.swift` | UPDATE | Recording Management: category/template dropdowns, Apply, Export, delete actions |
| `VoiceInk/Views/ContentView.swift` | UPDATE | `.recorderMode` route; recorderLog title → Recording Management |
| `VoiceInk/Views/Sidebar/AppSidebar.swift` | UPDATE | Add `.recorderMode` to section + icon/style + title |
| `VoiceInk/Localizable.xcstrings` | UPDATE | New keys (Recorder Mode, Recording Management, Apply/Export…) |
| `VoiceInkTests/RecorderModeTests.swift` | CREATE | Unit tests for config builder + manual/auto decision |

## NOT Building
- Real diarization (M5).
- Any change to voice-input/dictation.
- Batch apply/export across many recordings at once.
- Per-device auto-export override (global toggle only in v1; see Open Question).

---

## Step-by-Step Tasks

### Task 1: Recorder Mode settings in the store

**Files:** Modify `RecorderConfigStore.swift`; Test `RecorderModeTests.swift`

- [ ] **TEST FIRST**
```swift
import XCTest
@testable import VoiceInk

@MainActor final class RecorderModeTests: XCTestCase {
    func testRecorderModeDefaults() {
        let s = RecorderConfigStore.shared
        s.setRecorderTranscriptionModel(nil)
        s.setRecorderAutoExport(false)
        XCTAssertFalse(s.recorderAutoExportEnabled)   // default manual
    }
    func testRecorderModePersistsModel() {
        let s = RecorderConfigStore.shared
        s.setRecorderTranscriptionModel("whisper-large-v3")
        XCTAssertEqual(s.recorderTranscriptionModelName, "whisper-large-v3")
        s.setRecorderTranscriptionModel(nil)
    }
}
```
  Run: `... -only-testing:VoiceInkTests/RecorderModeTests` — expect FAIL.

- [ ] **IMPLEMENT** in `RecorderConfigStore`:
```swift
@Published private(set) var recorderTranscriptionModelName: String?
@Published private(set) var recorderLanguage: String?           // nil = auto
@Published private(set) var recorderTextFormattingEnabled: Bool = false
@Published private(set) var recorderAutoExportEnabled: Bool = false
private let recTranscriptionKey = "recorderTranscriptionModelV1"
private let recLanguageKey = "recorderLanguageV1"
private let recFormattingKey = "recorderTextFormattingV1"
private let recAutoExportKey = "recorderAutoExportV1"
// load() : read the four keys (bool via UserDefaults.bool, strings via string)
func setRecorderTranscriptionModel(_ name: String?) { recorderTranscriptionModelName = name; persist(name, recTranscriptionKey) }
func setRecorderLanguage(_ code: String?) { recorderLanguage = code; persist(code, recLanguageKey) }
func setRecorderTextFormatting(_ on: Bool) { recorderTextFormattingEnabled = on; UserDefaults.standard.set(on, forKey: recFormattingKey) }
func setRecorderAutoExport(_ on: Bool) { recorderAutoExportEnabled = on; UserDefaults.standard.set(on, forKey: recAutoExportKey) }
// private func persist(_ v: String?, _ k: String) { if let v { UserDefaults.standard.set(v,forKey:k) } else { UserDefaults.standard.removeObject(forKey:k) } }
```
- [ ] **MIRROR**: CONFIG_STORE.
- [ ] **VALIDATE**: re-run Task-1 test — PASS.
- [ ] **COMMIT**: `feat(recorder): add Recorder Mode settings (transcription model, language, auto-export)`

---

### Task 2: Synthetic recorder transcription config

**Files:** Create `RecorderTranscriptionConfig.swift`; Test `RecorderModeTests.swift`

- [ ] **TEST FIRST** (pure builder — given a model name + formatting, produce a ModeConfig):
```swift
func testRecorderModeConfigUsesSelectedModel() {
    let cfg = RecorderTranscriptionConfig.makeMode(
        transcriptionModelName: "whisper-large-v3", language: "auto", textFormatting: true)
    XCTAssertEqual(cfg.selectedTranscriptionModelName, "whisper-large-v3")
    XCTAssertFalse(cfg.isAIEnhancementEnabled)   // recorder never uses Mode enhancement
    XCTAssertTrue(cfg.isTextFormattingEnabled)
}
```
  Run — expect FAIL.

- [ ] **IMPLEMENT** `RecorderTranscriptionConfig.swift`:
```swift
import Foundation
enum RecorderTranscriptionConfig {
    /// Build a transcription-only ModeConfig from Recorder Mode settings. AI enhancement is OFF —
    /// recorder analysis is applied later (manually) via RecorderPostProcessor, not the Mode path.
    static func makeMode(transcriptionModelName: String?, language: String?, textFormatting: Bool) -> ModeConfig {
        ModeConfig(
            name: "Recorder",
            isAIEnhancementEnabled: false,
            selectedTranscriptionModelName: transcriptionModelName,
            selectedLanguage: language,
            isTextFormattingEnabled: textFormatting)
    }
    @MainActor static func current() -> ModeConfig {
        let s = RecorderConfigStore.shared
        return makeMode(transcriptionModelName: s.recorderTranscriptionModelName,
                        language: s.recorderLanguage, textFormatting: s.recorderTextFormattingEnabled)
    }
}
```
- [ ] **GOTCHA**: verify the real `ModeConfig` init parameter labels/order against `ModeConfig.swift:98-102` (`name`, `isAIEnhancementEnabled`, `selectedTranscriptionModelName`, `selectedLanguage`, `isTextFormattingEnabled` all have defaults except `name`/`isAIEnhancementEnabled`). Adjust the call to match.
- [ ] **MIRROR**: TRANSCRIPTION_CONFIG_RESOLVE.
- [ ] **VALIDATE**: re-run test — PASS.
- [ ] **COMMIT**: `feat(recorder): synthetic recorder transcription config from Recorder Mode`

---

### Task 3: Recorder uses its own transcription model (decouple from voice Mode)

**Files:** Modify `RecorderImportService.swift` (handleMount)

- [ ] **ACTION**: replace `ModeManager.shared.activeConfiguration ?? configurations.first` with the recorder transcription config when starting processing for recorder imports.
- [ ] **TEST**: manual (queue/engine) — see Manual Validation AC-R1.
- [ ] **IMPLEMENT** in `handleMount(device:)` where it currently resolves `mode` + calls `startProcessing`:
```swift
let recorderMode = RecorderTranscriptionConfig.current()
AudioTranscriptionManager.shared.startProcessing(modelContext: modelContext, engine: engine, mode: recorderMode)
```
- [ ] **GOTCHA**: the recorder branch in `processItem` already skips Mode enhancement via `if case .manual = item.origin` (recorder items take the raw `else` branch). The synthetic mode having `isAIEnhancementEnabled = false` is belt-and-suspenders; do not remove the origin guard.
- [ ] **VALIDATE**: `xcodebuild ... build` — success.
- [ ] **COMMIT**: `feat(recorder): transcribe imports with Recorder Mode model, not active voice Mode`

---

### Task 4: Split RecorderPostProcessor into callable units + manual/auto branch

**Files:** Modify `RecorderPostProcessor.swift`

- [ ] **ACTION**: factor the orchestrator so the UI can call pieces:
  - `func suggestCategory(transcription:rawText:enhancementService:aiService:) async` — classify only; set `recorderCategoryId/Name` + `classificationConfidence`; save. No enhance, no export.
  - `func applyTemplate(transcription:category:enhancementService:aiService:modelContext:) async` — resolve model (category → default → fallback), condense if long, enhance with category's recorder prompt → set `enhancedText`; save. (No export.)
  - keep `exportToVault(...)` callable + add `func export(transcription:category:modelContext:) async` wrapper that builds title + writes md + sets `exportedFilePath`.
  - `process(...)` (mount path): if `RecorderConfigStore.shared.recorderAutoExportEnabled` → suggest + apply + export (current M2 chain); else → `suggestCategory` only, then post `.recorderImportCompleted` + "完成（待處理）" toast.
- [ ] **TEST FIRST** (the branch decision is pure-ish — test the default is manual via the store flag):
```swift
func testManualIsDefaultSoNoAutoExportFlag() {
    RecorderConfigStore.shared.setRecorderAutoExport(false)
    XCTAssertFalse(RecorderConfigStore.shared.recorderAutoExportEnabled)
}
```
  (Full apply/export are AI+SwiftData — verified manually; this guards the default.)
- [ ] **IMPLEMENT**: refactor as above. Reuse existing `resolvedAnalysisModel`, `generateShortTitle`, `TemplateRouter`, `LongTranscriptSummarizer`, `VaultExportService`. The recorder prompt lookup uses `RecorderConfigStore.shared.recorderPrompt(byId:)`.
- [ ] **GOTCHA**: `process()` still records the ledger via the existing `.transcriptionCreated` observer in `RecorderImportService` — do not duplicate ledger writes here.
- [ ] **MIRROR**: ENHANCE_WITH_MODEL.
- [ ] **VALIDATE**: `xcodebuild ... build`; re-run Task-4 test — PASS.
- [ ] **COMMIT**: `feat(recorder): split post-processor into suggest/apply/export; default to manual`

---

### Task 5: Recorder Mode settings page

**Files:** Create `RecorderModeSettingsView.swift`; Modify `ContentView.swift`, `AppSidebar.swift`, `CategoriesSettingsView.swift`, `Localizable.xcstrings`

- [ ] **ACTION**: new page with: transcription model picker (from `transcriptionModelManager.usableModels`), default analysis model picker (reuse `recorderModelChoices`), language (optional), text-formatting toggle, auto-export toggle. Add `.recorderMode` ViewType in the Recorder section (after `.recorders`). Remove the `DefaultModelCard` from `CategoriesSettingsView` (moved here).
- [ ] **TEST**: manual (UI) — see Manual Validation.
- [ ] **IMPLEMENT** — `RecorderModeSettingsView` mirrors `RecordersSettingsView` (AppScreenHeader + Form cards). Transcription model picker needs `@EnvironmentObject transcriptionModelManager: TranscriptionModelManager` (provided to ContentView). Bind selections to `RecorderConfigStore.set...`.
  - `ContentView`: `case recorderMode = "Recorder Mode"` + `case .recorderMode: RecorderModeSettingsView()`.
  - `AppSidebar`: add `.recorderMode` to the `"Recorder → Obsidian"` section items, `title` → "Recorder Mode", icon (e.g. `slider.horizontal.3`), sidebarIconStyle fallback. Update `assertSidebarItemsCoverAllCases` (automatic — it flat-maps sections).
  - Catalog: "Recorder Mode"→繁"錄音筆模式"/簡"录音笔模式"; plus field labels as needed.
- [ ] **GOTCHA**: `transcriptionModelManager.usableModels` element has `.name` (id) + `.displayName`; store the `.name` in `recorderTranscriptionModelName`. A "預設（自動選）" option = nil.
- [ ] **MIRROR**: SIDE_PANEL_CARD_PAGE, MODEL_PICKER_HELPER.
- [ ] **VALIDATE**: `xcodebuild ... build`; UI check in Manual Validation.
- [ ] **COMMIT**: `feat(recorder): Recorder Mode page (transcription + default analysis model + language)`

---

### Task 6: Recording Management page (apply / export / delete)

**Files:** Modify `RecorderHistoryView.swift` (rename to Recording Management), `ContentView.swift`/`AppSidebar.swift` (title), `Localizable.xcstrings`

- [ ] **ACTION**: upgrade each card in `RecorderHistoryView` to a management card:
  - **category dropdown** (defaults to AI suggestion `recorderCategoryName`; editable → updates `recorderCategoryId/Name`).
  - **template dropdown** (recorder prompts from `RecorderConfigStore.shared.recorderPrompts`, default = the suggested category's bound prompt) + **套用** button → `RecorderPostProcessor.applyTemplate(...)` → result shows in the "套用後" tab.
  - **匯出** button → `RecorderPostProcessor.export(...)` → writes to the category sub-folder; show "已輸出" + open-in-Finder (existing).
  - **刪除錄音檔**（only audio: delete file + clear `audioFileURL`, keep `Transcription`) and **刪除整筆紀錄**（`modelContext.delete(transcription)`）, both with confirm.
  - Keep existing raw/applied tabs + audio player.
- [ ] **TEST**: manual — see Manual Validation AC-R3/R4/R5.
- [ ] **IMPLEMENT**: the card needs `@Environment(\.modelContext)`, `@EnvironmentObject enhancementService`, `@EnvironmentObject aiService`, `@StateObject store = RecorderConfigStore.shared`. Apply/export run in a `Task`. After mutation, the `@Query` refreshes the list automatically.
  - Rename sidebar/page title: `recorderLog` rawValue stays (routing id), but `title` → "Recording Management"; page `AppScreenHeader(title: "Recording Management" …)`. Catalog "Recording Management"→繁"錄音管理"/簡"录音管理".
- [ ] **GOTCHA**: deleting only audio must not delete the `Transcription`; deleting the record should also try to remove the app-storage wav (mirror `InlineHistoryView.performDeletion`). Do NOT delete the exported `.md` (Open Question — leave it).
- [ ] **MIRROR**: RECORDER_QUERY_CARD; `InlineHistoryView` delete pattern.
- [ ] **VALIDATE**: `xcodebuild ... build`; UI in Manual Validation.
- [ ] **COMMIT**: `feat(recorder): Recording Management — apply template, preview, export, delete`

---

## Testing Strategy

### Unit Tests
| Test | Input | Expected | Edge? |
|---|---|---|---|
| `testRecorderModeDefaults` | fresh store | autoExport == false | no |
| `testRecorderModePersistsModel` | set model | value persists | no |
| `testRecorderModeConfigUsesSelectedModel` | name+formatting | ModeConfig fields | no |
| `testManualIsDefaultSoNoAutoExportFlag` | default | manual | no |

### Edge Cases Checklist
- [ ] No recorder transcription model set → falls back to first usable model
- [ ] Apply with a category that has no bound prompt → output = raw transcript (no enhance)
- [ ] Export with no vault root configured → no-op + notify
- [ ] Delete audio when file already gone → no crash, clears `audioFileURL`
- [ ] Auto-export ON → full chain still works (regression)

---

## Validation Commands

### Build
```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```
EXPECT: BUILD SUCCEEDED.

### Unit Tests (host-app — use make-local settings; see docs/plans/recorder-automation-auto-import.plan.md note)
```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  -only-testing:VoiceInkTests/RecorderModeTests -only-testing:VoiceInkTests/RecorderPipelineTests
```
EXPECT: all pass.

### Deploy
```bash
make deploy   # stable-signed, /Applications, relaunch
```

### Manual Validation (AC)
- [ ] **AC-R1**: Recorder Mode model = X, voice Mode = Y. Plug in → transcript uses X; switching voice Mode doesn't change recorder.
- [ ] **AC-R2**: Default manual — after import: raw text present, suggested category, `enhancedText` empty, no .md written.
- [ ] **AC-R3**: In Recording Management, pick template → 套用 → "套用後" shows result; raw tab unchanged; re-apply T2 replaces applied, raw intact.
- [ ] **AC-R4**: 匯出 → `.md` at `{vault}/{subfolder}/`; before export none existed.
- [ ] **AC-R5**: 刪除錄音檔 → audio gone, transcript stays; 刪除整筆 → record gone.
- [ ] **AC-R6**: recorder audio survives auto-cleanup (already implemented — confirm predicate excludes recorder items).
- [ ] **AC-R7**: transcription picker lists usable models regardless of keys; analysis picker lists enhancement-capable keyed providers.

---

## Acceptance Criteria
- [ ] Tasks 1–6 complete
- [ ] Build succeeds; unit tests pass; no voice-input regression
- [ ] AC-R1..R7 verified manually
- [ ] Manual default: import does not auto-export
- [ ] Raw transcript + audio preserved

## Completion Checklist
- [ ] Patterns followed (@MainActor singletons, Logger category RecorderAutomation, JSON/UserDefaults)
- [ ] Recorder transcription decoupled from voice Modes; voice input unaffected
- [ ] New files compiled into targets (file-system-synchronized groups — automatic)
- [ ] `assertSidebarItemsCoverAllCases` holds (new `.recorderMode` in a section)
- [ ] Localized keys added (Recorder Mode, Recording Management, …)
- [ ] Self-contained — no questions needed during implementation

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Synthetic `ModeConfig` init mismatch (param labels) | M | M | Task 2 GOTCHA verifies against ModeConfig.swift:98 before building |
| Manual default surprises users expecting auto | M | L | Auto-export toggle in Recorder Mode; "完成（待處理）" toast signals manual step |
| Apply uses wrong model (only Gemini keyed) | M | M | Resolution falls back to first connected provider; surfaced in Recorder Mode picker |
| Deleting record leaves orphan exported .md | L | L | Documented (Open Question — leave .md); user can delete in Obsidian |

## Notes
- Already shipped (earlier commits, ratified by the SRS): prompt split (R1), sectioned sidebar +
  renames (R11 minus the Recording-Management rename), rich recorder log, audio-cleanup exemption (R10).
- Mode B + balanced: pure seams (store persistence, config builder, manual default) are test-first;
  pages + AI apply/export + queue wiring are manual (no host-testable harness for those).
- The default-analysis-model card moves from Recorder Prompts → Recorder Mode (storage keys unchanged,
  so existing value carries over).
