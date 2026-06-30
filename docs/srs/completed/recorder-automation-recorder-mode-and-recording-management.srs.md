---
linear_issue: null
---
# SRS: Recorder Mode & Manual Recording Management

## Metadata
- **Module**: `recorder-automation`
- **Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source PRD**: `docs/prd/recorder-auto-import-and-template-routing.prd.md` (extends)
- **Prior SRS**: `docs/srs/recorder-automation-auto-import-template-routing.srs.md` (M1–M2)
- **Source Linear Issue**: N/A
- **Created**: 2026-06-30
- **Grill level**: 1 (standard — requirements pre-confirmed with user)

## Feature Summary

Decouple the recorder pipeline from voice-input (Modes), give the recorder its own transcription
+ default-analysis model settings ("Recorder Mode"), and shift template application + Obsidian
export from automatic to a **manual, reviewable** workflow centred on a new **Recording Management**
page. Raw audio + raw transcript are always preserved for later AI analysis.

## Delta from Current Module State

> See `docs/spec/recorder-automation.spec.md` for the M1–M2 architecture. This SRS changes only the
> following. Voice-input (dictation) behaviour is **unchanged**.

### Two fully separated pipelines

| | Path A — Voice Input (dictation) | Path B — Recorder Import |
|---|---|---|
| Transcription model | active **Voice Mode**'s model | **Recorder Mode**'s model (new) |
| Prompt/template | Voice Mode's **voice prompt** | **recorder prompt**, applied **manually** in Recording Management |
| Trigger conditions | app/website/triggers | none — plug-in only |
| Output | paste at cursor | **manual export** to Obsidian (per template sub-folder) |
| Obsidian | never | only on explicit export |

### New / Changed Data Models

- **NEW config** `RecorderConfigStore.recorderTranscriptionModelName: String?`,
  `recorderLanguage: String?`, `recorderTextFormattingEnabled: Bool`, plus the existing
  `defaultAIProviderName/defaultAIModelName` (the latter **relocated** in the UI from the Recorder
  Prompts page to the Recorder Mode page; storage keys unchanged).
- **NEW config** `recorderAutoExportEnabled: Bool` (default **false** = manual).
- **CHANGED** `RecorderCategory` / recorder prompts: already a separate store
  (`RecorderConfigStore.recorderPrompts`, key `recorderCategoryPromptsV1`) decoupled from voice
  prompts (`AIEnhancementService.customPrompts`). This SRS ratifies that split (R1).
- **REUSED** `Transcription` (@Model): `text` (raw transcript — never overwritten), `enhancedText`
  (applied-template result), `audioFileURL`, `recorderCategoryId/Name`, `importFingerprint`,
  `exportedFilePath`. No new SwiftData columns required.

### Changed Business Logic

- **Recorder transcription model source**: `RecorderImportService.handleMount` /
  `AudioTranscriptionManager.processItem` (recorder branch) must derive the transcription
  configuration from **Recorder Mode** settings — NOT from `ModeManager.shared.activeConfiguration`.
  Build a synthetic transcription config (model + language + formatting; AI enhancement off).
- **Import becomes "transcribe + suggest only"** (when `recorderAutoExportEnabled == false`):
  `RecorderPostProcessor` runs classification to set a **suggested** `recorderCategoryName/Id`, then
  **stops** — it does NOT enhance with a template and does NOT export. Apply + export move to the UI.
- **Manual apply/export** (new service surface): given a `Transcription` + a chosen recorder
  category/prompt → run enhancement (model resolution: category override → Recorder Mode default →
  fallback) → store `enhancedText`; export writes `{vault}/{category.subfolder}/<name>.md` and sets
  `exportedFilePath`. Re-apply with a different template overwrites `enhancedText` (raw `text` stays).
- **Auto mode** (`recorderAutoExportEnabled == true`) preserves the M2 zero-click flow
  (classify → apply → export) as an opt-in.

### Explicitly Out of Scope

- Real speaker diarization (still M5).
- Changing the voice-input/dictation flow in any way.
- Cloud sync of recorder config; multi-vault.
- Bulk/batch apply across many recordings in one action (single-item apply in v1).

## Functional Requirements

> Status legend: [x] already implemented in M1–M2 (ratified here), [ ] new in this SRS.

- [x] **FR-R1** Recorder prompts are a separate store from voice prompts; the two never share a list.
- [ ] **FR-R2** A **Recorder Mode** settings surface lets the user choose the recorder's
  **transcription (STT) model** from the available transcription models (independent of API keys),
  a **default analysis model** (from enhancement-capable, key-configured providers), an optional
  **language** (default auto), and an optional **text-formatting** toggle.
- [ ] **FR-R3** Recorder imports transcribe using Recorder Mode settings, never the active Voice Mode.
- [ ] **FR-R4** Default behaviour is **manual**: on import, the system auto-copies the file to local
  storage, transcribes the **raw transcript** (preserved), and sets a **suggested category**; it does
  **not** auto-apply a template or auto-export. An opt-in toggle restores full-auto.
- [ ] **FR-R5** A **Recording Management** page (replaces "Import Log") lists each imported recording
  as an expandable card showing: playable **original audio**, **raw transcript**, **applied result**,
  date/time, and category.
- [ ] **FR-R6** The category on a card is a **dropdown** defaulting to the AI suggestion; the user can
  change it.
- [ ] **FR-R7** A **template dropdown + Apply** action runs the chosen recorder prompt over the raw
  transcript via the resolved analysis model and shows the result in an "applied" tab; re-applying a
  different template replaces the applied result without touching the raw transcript.
- [ ] **FR-R8** An **Export** action writes the applied result to the matching template's Obsidian
  sub-folder and records `exportedFilePath`; nothing is bound to Obsidian before export.
- [ ] **FR-R9** Per recording: **delete audio only** (keep transcript) and **delete entire record**.
- [ ] **FR-R10** Recorder audio + transcript are **preserved** — recorder transcriptions are exempt
  from the automatic audio cleanup; raw transcript is never overwritten by template application.
- [ ] **FR-R11** Sidebar "Recorder → Obsidian" section reads: **Recorder Devices / Recorder Mode /
  Recorder Prompts / Recording Management**.

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| Separation / no regression | Voice-input flow byte-for-byte unchanged | Recorder branch reads Recorder Mode config; Modes path untouched |
| Data preservation | Raw transcript + audio retained until user deletes | Cleanup predicate excludes `recorderSourceDeviceId != nil`; apply writes `enhancedText`, never `text` |
| Cost control | No AI enhancement/export spend unless the user acts (manual default) | Import stops after classify; apply/export are explicit |
| Model selectability | STT list independent of API keys; analysis list = enhancement-capable + keyed | STT from `transcriptionModelManager.usableModels`; analysis from `aiService.connectedProviders` |
| Reversibility | Non-destructive; removing the module leaves optional fields/keys harmless | Additive config keys; reuse existing `Transcription` fields |

## Architecture Notes

- **Recorder Mode** is a thin settings surface, not a full Mode: model + language + formatting only,
  no triggers, no prompt selection (prompt is chosen per-recording, manually, in Recording Management).
- **Synthetic transcription config**: rather than thread a new parameter through the queue, the
  recorder branch constructs a `ModeConfig`-shaped transcription configuration from Recorder Mode
  (transcription model name, language, formatting; `isAIEnhancementEnabled = false`) and feeds the
  existing `AudioTranscriptionManager.startProcessing(modelContext:engine:mode:)` path.
- **Manual apply/export** reuses the M2 building blocks — `RecorderPostProcessor` (factored so
  classify, apply, and export are independently callable), `VaultExportService`, and the
  category→model resolution — but driven by UI actions instead of the mount handler.
- **Recording Management** is a SwiftData `@Query` over `Transcription where importFingerprint != nil`
  (rich, History-style cards), reusing `AudioPlayerView` / `MarkdownContentView` / `CopyIconButton`.
- See `docs/spec/recorder-automation.spec.md` for the broader pipeline + components.

## Acceptance Criteria

### AC-R1: Recorder transcription uses Recorder Mode, not Voice Mode
- **Given**: Recorder Mode's transcription model = X, while the active Voice Mode's model = Y (X≠Y)
- **When**: a recorder volume mounts and a file is imported
- **Then**: the raw transcript is produced with model **X**; switching the active Voice Mode does not
  change recorder transcription
- **Test**: `VoiceInkTests/RecorderModeTests::recorderUsesRecorderModeTranscriptionModel`

### AC-R2: Manual default — import transcribes + suggests but does not export
- **Given**: `recorderAutoExportEnabled == false` and a configured device + vault root
- **When**: a new file is imported and transcribed
- **Then**: a `Transcription` exists with non-empty raw `text`, a **suggested** `recorderCategoryName`,
  `enhancedText == nil`, and `exportedFilePath == nil`; no `.md` is written to the vault
- **Test**: `VoiceInkTests/RecorderManualFlowTests::importStopsAtSuggestion`

### AC-R3: Manual apply produces a result without touching the raw transcript
- **Given**: an imported recording with raw `text`
- **When**: the user picks template T and taps Apply
- **Then**: `enhancedText` holds T's result, raw `text` is unchanged; picking template T2 and applying
  replaces `enhancedText` again with `text` still intact
- **Test**: `VoiceInkTests/RecorderManualFlowTests::applyPreservesRawTranscript`

### AC-R4: Export writes to the template's sub-folder and records the path
- **Given**: an applied recording for category "會議" (sub-folder "Meetings"), vault root set
- **When**: the user taps Export
- **Then**: a `.md` exists at `{vault}/Meetings/<name>.md` and `exportedFilePath` is set; before this
  action no vault file existed for the item
- **Test**: `VoiceInkTests/RecorderManualFlowTests::exportWritesToCategorySubfolder`

### AC-R5: Delete audio vs delete record
- **Given**: a recording with audio + transcript
- **When**: the user chooses "delete audio only"
- **Then**: the audio file is removed and `audioFileURL` cleared, but the `Transcription` (raw text)
  remains; choosing "delete record" removes the `Transcription` entirely
- **Test**: `VoiceInkTests/RecorderManualFlowTests::deleteAudioKeepsTranscript`

### AC-R6: Recorder audio survives auto-cleanup
- **Given**: a recorder transcription older than the audio-retention window
- **When**: automatic audio cleanup runs
- **Then**: its audio file is **not** deleted (recorder items are exempt)
- **Test**: `VoiceInkTests/AudioCleanupTests::recorderAudioExempt`

### AC-R7: Model pickers list the right sources
- **Given**: several transcription models downloaded but only one enhancement provider keyed
- **When**: the user opens Recorder Mode
- **Then**: the **transcription** picker lists all usable transcription models; the **analysis** picker
  lists only enhancement-capable, key-configured providers' models
- **Test**: manual / UI

## Open Questions

- [ ] Where should `recorderAutoExportEnabled` live — global (Recorder Mode) or per-device? (Lean global.)
- [ ] When the user changes a card's category, should the template dropdown auto-switch to that
  category's bound prompt, or stay on the last manual pick?
- [ ] Should "delete record" also delete the exported `.md` in the vault, or leave it? (Lean: leave it.)
