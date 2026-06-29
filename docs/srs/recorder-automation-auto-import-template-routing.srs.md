---
linear_issue: null
---
# SRS: Recorder Auto-Import & Template Routing

## Metadata
- **Module**: `recorder-automation`
- **Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source PRD**: `docs/prd/recorder-auto-import-and-template-routing.prd.md`
- **Source Linear Issue**: N/A
- **Created**: 2026-06-29
- **Grill level**: 3 (full)
- **Plans**: `docs/plans/recorder-automation-auto-import.plan.md` (M1)

## Feature Summary

Adds an automated pipeline to VoiceInk: when a configured recorder (e.g. a Sony "IC RECORDER"
mounted as a USB mass-storage volume) is plugged in, the app auto-imports new audio files,
transcribes them raw, classifies each transcript into a user-defined category via a lightweight
cloud-AI call, applies that category's `CustomPrompt` to produce an analysis (e.g. interview
debrief, talk/panel notes), and exports a Markdown file into the matching sub-folder of an
Obsidian vault — all with zero clicks. v1 focuses on two flagship use cases: **interview
analysis** and **talk/seminar transcripts**.

## Delta from Current Module State

> `recorder-automation` is a NEW module. There is no prior Module Spec; see
> `docs/spec/recorder-automation.spec.md` for the full as-designed architecture. This section
> lists what changes **relative to the existing VoiceInk codebase** that this feature touches.

### New / Changed API Endpoints

N/A — VoiceInk is a local macOS app with no HTTP API. "Contracts" here are Swift service
interfaces and the AI provider calls; they are specified in the Module Spec's *API Contracts*
(internal service signatures) and *External Dependencies* (AI provider) sections.

### New / Changed Data Models

- **NEW** `RecorderDevice` (config struct, persisted as JSON in `UserDefaults`, mirroring the
  `ModeManager` pattern at `Modes/ModeConfig.swift:276-287`).
- **NEW** `RecorderCategory` (config struct, JSON in `UserDefaults`); each binds an existing
  `CustomPrompt` (`Models/CustomPrompt.swift:4`) + a vault sub-folder + a classifier description.
- **NEW** `ImportLedgerEntry` (SwiftData `@Model`) for idempotent dedup of already-imported files.
- **CHANGED** `Transcription` (`Models/Transcription.swift:12`) — add optional fields:
  `recorderCategoryName`, `recorderCategoryId`, `recorderSourceDeviceId`,
  `classificationConfidence`, `exportedFilePath`, `importFingerprint`, `speakerLabeled` (Bool).
  All optional with defaults → safe SwiftData lightweight migration (existing rows unaffected).
- **CHANGED** `AudioFileQueueItem` (`Models/AudioFileQueueItem.swift:26`) — add an optional
  `origin` tag (`.manual` | `.recorderImport(deviceId:)`) so the queue processor can route
  recorder items down the bypass path.

### Changed Business Logic

- **`AudioTranscriptionManager.processItem()`** (`Services/AudioFileTranscriptionManager.swift`):
  for items tagged `.recorderImport`, **skip the active-Mode enhancement** (raw transcript only),
  then hand the completed transcript to the new `RecorderPostProcessor`. Manual-drop items keep
  today's behavior (transcribe + active Mode enhancement) unchanged.
- **Enhancement reuse**: `RecorderPostProcessor` calls the existing
  `AIEnhancementService.enhance()` (`Services/AIEnhancement/AIEnhancementService.swift:394`)
  with the **category's** `CustomPrompt` rather than the active Mode's prompt.

### Explicitly Out of Scope

- Real-time / streaming classification (classification is a one-shot post-transcription step).
- Cloud sync / multi-machine sharing of recorder & category config (v1).
- Recorder firmware integration — device is always treated as a mounted volume + audio folder.
- A parallel template system — categories bind the existing `CustomPrompt`.
- Real speaker diarization is **specified but milestone-gated** (M5); v1 uses prompt-based
  speaker inference inside the interview analysis prompt.

## Functional Requirements

> **Status (2026-06-30):** FR-1–5 shipped in M1. FR-6–14 shipped in M2 (this pass);
> code unit-tested (18/18 pure-seam tests green) but not yet manually verified on hardware.
> FR-12 is complete in the sidebar **History** page (`InlineHistoryView`): a category badge on each
> row + a right-click **重新分類** submenu calling `RecorderPostProcessor.reclassify`. The separate
> standalone history window (`TranscriptionHistoryView`, opened by `HistoryWindowController`) does
> not yet show the badge — it lacks the injected `AIEnhancementService` env object.
> FR-15 (real diarization) remains M5 / out of v1.

- [x] **FR-1** Detect volume mount/unmount via `NSWorkspace.shared.notificationCenter`
  (`didMountNotification` / `didUnmountNotification`) and match the mounted volume name against
  each configured `RecorderDevice.volumeNameMatch`.
- [x] **FR-2** On a match with `autoImportEnabled`, scan the device's configured source folder
  for files whose type is in `SupportedMedia` (`Services/SupportedMedia.swift`).
- [x] **FR-3** Dedup each candidate against the import ledger using a two-stage key:
  fast `(filename, byteSize)` filter, then SHA-256 content-hash confirm on collisions.
- [x] **FR-4** Copy each new file into app-controlled storage (security-scoped access) and
  enqueue it into `AudioTranscriptionManager` tagged `.recorderImport(deviceId:)`.
- [x] **FR-5** Transcribe recorder items **raw** (no active-Mode enhancement).
- [x] **FR-6** Classify each raw transcript with one lightweight cloud-AI call returning a
  category id **or** `uncertain`, plus a 0–1 confidence. Categories + their classifier
  descriptions are the prompt input.
- [x] **FR-7** Route to the matched `RecorderCategory`'s `CustomPrompt`; on `uncertain` route to
  the undeletable **general/fallback** category.
- [x] **FR-8** For transcripts whose estimated token count exceeds a threshold, run a map-reduce
  summarization pre-pass before final enhancement (long talk/seminar support).
- [x] **FR-9** Enhance the (possibly summarized) transcript via `AIEnhancementService.enhance()`
  using the category's prompt, persisting the result on the `Transcription` row with category
  metadata + confidence.
- [x] **FR-10** Export a Markdown file to `{vaultRoot}/{category.subfolder}/{filename}` containing
  YAML frontmatter (date, source device, category, models) + the analysis + a collapsible raw
  transcript. Vault root is a security-scoped bookmark.
- [x] **FR-11** Post floating notifications via `NotificationManager` at import start
  ("匯入 N 個新檔") and on completion ("完成").
- [x] **FR-12** Show a category badge on each queue/history item; allow manual re-classification
  which re-runs routing/enhancement/export for that item.
- [x] **FR-13** Provide a **Recorders** sidebar page (device cards + ~400pt slide-out form) and a
  **Categories** sidebar page (category ↔ prompt ↔ sub-folder list, with an undeletable fallback).
- [x] **FR-14** Optional per-device `deleteAfterImport` (default **off**): delete the original
  file from the device only after successful import + transcription + export.
- [ ] **FR-15** (M5, milestone-gated) Optional real speaker diarization via FluidAudio
  `OfflineDiarizerManager`, writing per-speaker segments used by the interview prompt.

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| Reliability (idempotency) | A given source file is processed **exactly once**, even across re-mounts / restarts | Persistent `ImportLedgerEntry` keyed on content hash; delete-after-import gated on full-success |
| Security / privacy | No file read outside user-granted folders; transcripts leave device only to the already-configured AI provider | Security-scoped bookmarks for source folder + vault root; API keys via existing `KeychainService`; reuse `AIEnhancementService` provider routing |
| Responsiveness | Import-start notification within ~3 s of mount | Lightweight folder scan on mount; transcription/analysis run async in background queue |
| Observability | Every stage (mount → scan → import → transcribe → classify → enhance → export) is traceable | `os.Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")` |
| Robustness (long audio) | 90-min seminar transcript produces a summary without exceeding provider context window | Token-estimate gate + map-reduce chunk summarization |

> Product-level metrics (zero-click completion rate, ≥80% classification accuracy, ≤20% manual
> correction) live in the PRD's *Success Metrics* — not restated here.

## Architecture Notes

- **Pipeline bypass**: recorder items are a distinct path that decouples transcription from
  enhancement so classification can sit between them. The existing manual-drop path is untouched.
  See Module Spec *Data Flow* + *Sequence Diagrams*.
- **Classification is a separate AI call** (not folded into enhancement) so it can return a
  category + confidence, drive fallback, surface a badge, and be re-run on manual correction.
- **Config storage** follows the proven `ModeManager` JSON-in-`UserDefaults` convention; only
  the dedup ledger needs queryable persistence → SwiftData `@Model`.
- **Diarization** requires **no new dependency** — FluidAudio (`FluidInference/FluidAudio`,
  already linked, see `Package.resolved`) ships `OfflineDiarizerManager` / `SpeakerManager`;
  v1 leaves it unwired and uses prompt-based speaker inference, M5 wires it in.
- **Sandbox risk**: reading `/Volumes/IC RECORDER/...` under the app sandbox requires a
  user-granted, bookmarked folder (or a removable-volume entitlement). The Recorders form
  obtains this once via `NSOpenPanel` and persists the bookmark. See Module Spec *Risks*.

## Acceptance Criteria

### AC-1: Plug-in triggers zero-click import
- **Given**: a `RecorderDevice` is configured with `autoImportEnabled = true`, a valid source
  folder bookmark, and the device contains 3 audio files not yet in the ledger
- **When**: the device volume mounts
- **Then**: within ~3 s a "匯入 3 個新檔" notification appears, the 3 files enter the
  transcription queue tagged `.recorderImport`, and no user click was required
- **Test**: `VoiceInkTests/RecorderImportServiceTests::importsNewFilesOnMount`

### AC-2: Dedup prevents reprocessing
- **Given**: a file already has an `ImportLedgerEntry` (same content hash)
- **When**: the same device re-mounts (or the app restarts and re-scans)
- **Then**: that file is **not** re-imported or re-transcribed
- **Test**: `VoiceInkTests/ImportLedgerTests::skipsAlreadyImportedByHash`

### AC-3: Recorder items skip Mode enhancement and route by category
- **Given**: a recorder-tagged queue item whose raw transcript classifies as category "面試"
- **When**: `processItem` completes transcription
- **Then**: the active Mode's prompt is **not** applied; instead the "面試" category's
  `CustomPrompt` is used by `AIEnhancementService.enhance()`, and the `Transcription` row
  records `recorderCategoryName = "面試"` and a confidence value
- **Test**: `VoiceInkTests/RecorderPostProcessorTests::routesToCategoryPromptBypassingMode`

### AC-4: Uncertain classification falls back to general category
- **Given**: the classifier returns `uncertain` (or confidence below the configured floor)
- **When**: routing runs
- **Then**: the undeletable fallback category's prompt is applied and the file is exported to
  the fallback sub-folder
- **Test**: `VoiceInkTests/TemplateRouterTests::usesFallbackOnUncertain`

### AC-5: Export lands in the right vault sub-folder with full content
- **Given**: a completed analysis for category "演講" with vault root `~/ObsidianVault` and
  sub-folder "Talks"
- **When**: export runs
- **Then**: a Markdown file exists at `~/ObsidianVault/Talks/<name>.md` containing YAML
  frontmatter (date, source device, category, models), the analysis body, and a collapsible
  section holding the raw transcript
- **Test**: `VoiceInkTests/VaultExportServiceTests::writesMarkdownWithFrontmatterAndRawTranscript`

### AC-6: Long transcript is summarized without context overflow
- **Given**: a transcript whose estimated tokens exceed the summarization threshold
- **When**: enhancement runs
- **Then**: a map-reduce pre-pass produces a bounded input to `AIEnhancementService.enhance()`
  and the run completes without a provider context-length error
- **Test**: `VoiceInkTests/LongTranscriptSummarizerTests::chunksAndReducesOverThreshold`

### AC-7: Manual re-classification re-routes and re-exports
- **Given**: a completed item classified as "面試" that the user re-tags to "演講"
- **When**: the user changes the category badge in History
- **Then**: routing/enhancement/export re-run for that item against the "演講" category and the
  old exported file is superseded
- **Test**: `VoiceInkTests/RecorderPostProcessorTests::reprocessesOnManualReclassification`

### AC-8: Delete-after-import is gated on full success and off by default
- **Given**: `deleteAfterImport = false` (default)
- **When**: import + transcription + export complete
- **Then**: the original file remains on the device; and **only** when `deleteAfterImport = true`
  AND all stages succeeded is the original removed
- **Test**: `VoiceInkTests/RecorderImportServiceTests::deletesOriginalOnlyWhenEnabledAndSucceeded`

## Open Questions

- [ ] Does VoiceInk's sandbox entitlement set allow bookmarked access to removable `/Volumes`
  folders, or is a `com.apple.security.files.user-selected.read-write` bookmark sufficient?
  (Verify against `VoiceInk/*.entitlements` during planning.)
- [ ] Map-reduce chunk size + token-estimate method (char/4 heuristic vs tokenizer) — and whether
  to persist both full transcript and summary.
- [ ] Confidence floor value for fallback (start permissive; calibrate against real recordings).
- [ ] Export filename convention + collision policy (e.g. `YYYY-MM-DD HHmm <category> <device>`).
- [ ] Multiple recorders / one recorder with rotating source folders — v1 boundary.
