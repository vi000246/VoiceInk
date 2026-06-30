# Spec: Recorder Automation

## Metadata
- **Module**: recorder-automation
- **Parent Module**: N/A
- **Sub-modules**: N/A
- **Source PRDs**:
  - `docs/prd/recorder-auto-import-and-template-routing.prd.md` — initial creation
- **Source Linear Issue**: N/A
- **Owner**: TBD (personal fork — vi000246/VoiceInk)
- **Status**: ACTIVE — living document
- **Created**: 2026-06-29
- **Last Updated**: 2026-06-30

## Change History

| Date | Source PRD | Feature SRS | Summary |
|------|------------|-------------|---------|
| 2026-06-29 | `docs/prd/recorder-auto-import-and-template-routing.prd.md` | `docs/srs/recorder-automation-auto-import-template-routing.srs.md` | Created from brownfield analysis — new module that watches recorder volume mounts, auto-imports audio into the existing transcription queue, classifies each transcript, routes to a category's CustomPrompt, and exports analysis Markdown to an Obsidian vault. |
| 2026-06-29 | same | same | **M1 implemented** — mount monitor, import ledger (SHA-256 dedup), device config/store, queue origin tag + raw-transcription bypass, minimal Recorders page. Build green; 5 unit tests. |
| 2026-06-30 | same | same | **M2 implemented** (FR-6–11,13,14) — `TranscriptClassificationService` (classify→id/uncertain+confidence), `TemplateRouter` (fallback on uncertain/below-floor), `LongTranscriptSummarizer` (map-reduce), `VaultExportService` (frontmatter+collapsible raw md), `RecorderPostProcessor` (orchestrator wired into `processItem`), `RecorderCategory` + store w/ undeletable fallback, Categories page, vault-root capture, delete-after-import. FR-12 partial: `reclassify` logic done, History badge UI deferred. 18 unit tests green. Manual/hardware AC pending. |
| 2026-06-30 | extends | `docs/srs/recorder-automation-recorder-mode-and-recording-management.srs.md` | **M3 spec'd** — two pipelines fully separated: recorder prompts split from voice prompts (`recorderPrompts` store, implemented); new **Recorder Mode** (own transcription model + default analysis model + language, decoupled from active Voice Mode); export shifts to **manual** by default (import = transcribe + suggest category only); new **Recording Management** page (replaces Import Log) with raw audio/transcript preservation, manual template apply→preview→export, delete-audio / delete-record; recorder audio exempt from auto-cleanup. Implemented so far: prompt split, sectioned sidebar + renames, rich recorder log, cleanup exemption. Pending: Recorder Mode page, manual apply/export flow, auto-export toggle. |

## Summary

`recorder-automation` is a new VoiceInk module that turns a plugged-in physical recorder into a
zero-click "audio → classified, formatted note" pipeline. It adds disk-mount monitoring and a
post-transcription classification router on top of VoiceInk's existing batch file-transcription
and AI-enhancement capabilities, then exports results as Markdown into a vault. The design
**reuses ~80% of VoiceInk** (transcription queue, `AIEnhancementService`, `CustomPrompt`,
security-scoped bookmarks, notifications, SwiftData history, sidebar/side-panel UI) and adds
only thin new services plus two settings pages.

---

## Domain Model

### Bounded Context
- **Context Name**: RecorderAutomation
- **Domain Layer**: Supporting Domain (orchestrates existing Core transcription/enhancement)
- **Parent Module**: N/A

### Ubiquitous Language
| Term | Definition |
|------|-----------|
| Recorder (Device) | A physical recorder that mounts as a USB mass-storage volume (e.g. "IC RECORDER"). Modeled as `RecorderDevice` config. |
| Source Folder | The folder **on the device** that holds new recordings; user-granted + bookmarked. |
| Import | Copying a new source file into app-controlled storage and enqueueing it for transcription. |
| Import Ledger | Persistent record of already-imported files (content-hash keyed) ensuring exactly-once processing. |
| Category | A user-defined content class (e.g. 面試 / 演講 / 通用). Binds an existing `CustomPrompt`, a classifier description, and a vault sub-folder. Modeled as `RecorderCategory`. |
| Classification | One lightweight cloud-AI call mapping a raw transcript → a category id or `uncertain` + confidence. |
| Routing | Selecting the category's `CustomPrompt` for enhancement; `uncertain` → fallback category. |
| Fallback (General) Category | The undeletable default category used when classification is `uncertain`. |
| Vault Root | The Obsidian vault directory (security-scoped bookmark) under which category sub-folders live. |
| Speaker Inference (v1) | Prompt-driven guess of who spoke (interviewer vs me), absent real diarization. |
| Diarization (M5) | Real per-speaker segmentation via FluidAudio `OfflineDiarizerManager`. |

### Domain Events
| Event | Trigger Condition | Consumers |
|---|---|---|
| `recorderDidMount` (internal) | Configured volume name matches a mounted volume | `RecorderImportService` |
| `recorderImportCompleted` (`Notification.Name`, new) | All stages succeed for an item | UI badge refresh, optional delete-after-import |

---

## System Context

### Scope & Boundaries
- **In scope**: mount monitoring; folder scan + dedup + import; raw transcription routing;
  post-transcription classification; template routing to `CustomPrompt`; long-transcript
  summarization; Markdown export to vault; Recorders & Categories settings UI; category badge +
  manual re-classification; optional delete-after-import; (M5) real diarization.
- **Out of scope**: streaming/real-time classification; cloud sync of config; recorder firmware
  integration; a parallel template system; building a new transcription engine.

### Actors
| Actor | Type | Interaction |
|---|---|---|
| User | Human | One-time setup (devices, categories, vault); plugs in recorder; optionally re-classifies |
| Physical recorder | External device | Mounts as a volume exposing an audio source folder |
| AI provider (Anthropic / OpenAI / …) | Service | Classification call + enhancement call (existing provider routing) |
| Obsidian vault (filesystem) | External store | Destination for exported Markdown notes |
| FluidAudio models (M5) | Local ML | Speaker diarization (offline) |

### External Dependencies
| Dependency | Purpose | Failure Mode |
|---|---|---|
| `NSWorkspace` mount notifications | Detect device plug-in | If unavailable, fall back to manual "Scan now" button in Recorders page |
| AI provider (via `AIEnhancementService` / `AIChatCompletionService`) | Classification + enhancement | Reuse existing retry/backoff + graceful error strings; item marked failed, original kept |
| Security-scoped bookmarks (source folder + vault root) | Sandbox-safe file access | Stale bookmark → prompt user to re-grant in Recorders page |
| `FluidInference/FluidAudio` (already linked) | (M5) diarization | Models not downloaded → silently keep v1 prompt-based inference |

---

## Architecture

### High-Level Diagram
```
                ┌──────────────────────────────────────────────────────────────┐
                │                     VoiceInk (existing)                        │
                │  AudioTranscriptionManager • AIEnhancementService • CustomPrompt│
                │  Transcription(@Model) • NotificationManager • Sidebar/SidePanel│
                └───────────────▲───────────────────────────▲──────────────────┘
                                │ enqueue(raw)               │ enhance(prompt)
   plug in        ┌────────────┴───────────┐   raw text  ┌──┴───────────────────┐
 ──────────►  RecorderDeviceMonitor ─► RecorderImportService ─► [queue] ─► RecorderPostProcessor
  (mount)        (NSWorkspace)          scan+dedup+copy          │            │ 1.classify (AI)
                                         │                       │            │ 2.route→category prompt
                                  ImportLedger(@Model)           │            │ 3.(long?)summarize
                                                                 │            │ 4.enhance (reuse)
                                                                 │            │ 5.persist+export
                                                                 ▼            ▼
                                                       Transcription(@Model)  VaultExportService
                                                       (+category metadata)   → {vault}/{subfolder}/*.md
   config (UserDefaults JSON): RecorderDevice[] , RecorderCategory[]
```

### Components
| Component | Responsibility | Interface |
|---|---|---|
| `RecorderDeviceMonitor` | Observe mount/unmount; match volume name → device | `@MainActor` singleton; subscribes to `NSWorkspace.shared.notificationCenter`; emits to `RecorderImportService` |
| `RecorderImportService` | Scan source folder, dedup via ledger, copy + enqueue, optional delete-after-success | `func handleMount(_ device:)`, `func scanNow(_ device:)` |
| `ImportLedger` | Exactly-once bookkeeping | SwiftData-backed: `func fingerprint(for:) -> String`, `func contains(_:) -> Bool`, `func record(_:)` |
| `RecorderPostProcessor` | Orchestrate classify → route → summarize → enhance → persist → export for recorder items | `func process(transcription:rawText:device:) async` |
| `TranscriptClassificationService` | One lightweight AI call → category id / `uncertain` + confidence | `func classify(_ text:, categories:) async -> ClassificationResult` |
| `TemplateRouter` | Map category → `CustomPrompt` (+ fallback) | `func prompt(for categoryId:) -> CustomPrompt` |
| `LongTranscriptSummarizer` | Map-reduce summarization above token threshold | `func condense(_ text:) async -> String` |
| `VaultExportService` | Write Markdown (frontmatter + analysis + collapsible raw) to vault sub-folder | `func export(_:to category:device:) throws -> URL` |
| `RecorderConfigStore` | Persist `RecorderDevice[]` / `RecorderCategory[]` as JSON in `UserDefaults` | mirrors `ModeManager` (`Modes/ModeConfig.swift:276-287`) |
| `SpeakerDiarizationService` (M5) | Wrap FluidAudio `OfflineDiarizerManager` → per-speaker segments | `func diarize(_ audioURL:) async -> [SpeakerSegment]` |
| Recorders / Categories views | Settings UI (cards + ~400pt side panel; category list) | New `ViewType` cases + `AppSidebar` entries |

### Data Flow
Mount (sync notification) → folder scan + dedup (sync, fast) → copy + enqueue (async). The
transcription queue processes items **sequentially** (existing behavior). For
`.recorderImport` items the post-processor runs the classify → enhance → export chain
**asynchronously** per item. Everything after mount detection is background; the user only sees
two notifications (start, complete).

### Sequence Diagrams (key flow)
```
User        NSWorkspace   DeviceMonitor   ImportService   Ledger   Queue(ATM)   PostProcessor   AIProvider   VaultExport
 │ plug in ───► didMount ──►              │               │        │            │               │            │
 │                          match device ─► scan folder    │        │            │               │            │
 │                                         ├─ fingerprint ─► contains?           │               │            │
 │                                         │◄─ false (new) ─┤        │            │               │            │
 │                                         ├─ copy+enqueue ──────────► add(.recorderImport)        │            │
 │ ◄─ notify "匯入 N 檔" ───────────────────┤               │        │            │               │            │
 │                                                          record ──┤            │               │            │
 │                                                                   │ transcribe(raw)            │            │
 │                                                                   ├─ done ─────► process()      │            │
 │                                                                                 ├─ classify ────► (AI)       │
 │                                                                                 │◄─ category+conf┤            │
 │                                                                                 ├─ (long?) summarize ─►(AI)   │
 │                                                                                 ├─ enhance(prompt) ─►(AI)     │
 │                                                                                 ├─ persist Transcription      │
 │                                                                                 ├─ export ───────────────────► write .md
 │ ◄─ notify "完成" ───────────────────────────────────────────────────────────────┤                            │
```

---

## Data Model

### Entities
| Entity | Owner | Lifecycle |
|---|---|---|
| `RecorderDevice` (config) | `RecorderConfigStore` | Created/edited in Recorders page; persists until deleted |
| `RecorderCategory` (config) | `RecorderConfigStore` | Created/edited in Categories page; fallback undeletable |
| `ImportLedgerEntry` (@Model) | `ImportLedger` | Created on successful import; retained for dedup |
| `Transcription` (@Model, existing — extended) | VoiceInk core | Created per transcription; gains recorder metadata |

### Schema (new / changed)
```swift
// NEW config structs (Codable; JSON in UserDefaults, key e.g. "recorderDevicesV1" / "recorderCategoriesV1")
struct RecorderDevice: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var volumeNameMatch: String        // matched against mounted volume name, e.g. "IC RECORDER"
    var sourceFolderBookmark: Data      // security-scoped bookmark to the folder ON the device
    var allowedFileTypes: [String]      // defaults from SupportedMedia
    var autoImportEnabled: Bool         // default true
    var deleteAfterImport: Bool         // default false
    var vaultRootBookmark: Data         // security-scoped bookmark to Obsidian vault root
    var createdAt: Date
}

struct RecorderCategory: Codable, Identifiable {
    let id: UUID
    var name: String
    var classifierDescription: String   // "when to use" text fed to the classifier
    var customPromptId: UUID            // binds existing CustomPrompt
    var subfolderName: String           // under vault root
    var isFallback: Bool                // exactly one true; undeletable
}

// NEW SwiftData model (in its own or the default store; see VoiceInk.swift:48-81 Schema array)
@Model final class ImportLedgerEntry {
    var fingerprint: String = ""        // sha256(content) — primary dedup key
    var fileName: String = ""
    var byteSize: Int = 0               // fast-path pre-filter with fileName
    var sourceDeviceId: UUID?
    var importedAt: Date = Date()
    var transcriptionId: UUID?
}

// CHANGED — additive optional fields on existing Transcription (Models/Transcription.swift:12)
//   var recorderCategoryName: String?
//   var recorderCategoryId: UUID?
//   var recorderSourceDeviceId: UUID?
//   var classificationConfidence: Double?
//   var exportedFilePath: String?
//   var importFingerprint: String?
//   var speakerLabeled: Bool = false
```

### Migration Strategy
- **Forward**: `ImportLedgerEntry` added to the Schema array in `VoiceInk.swift:48-81`. New
  `Transcription` fields are optional with defaults → SwiftData lightweight migration; existing
  rows unaffected. Config structs are new `UserDefaults` keys (absent = empty list).
- **Backward**: removing the module leaves orphaned optional fields/keys harmless; no destructive
  change to existing columns.
- **Backfill**: none — only newly imported files get ledger entries / metadata.
- **Coexistence**: manual-drop transcriptions keep `recorder*` fields nil and behave as today.

---

## API Contracts

> No HTTP API. Contracts are (a) internal Swift service signatures and (b) the AI classification
> call shape.

### Internal service signatures
See *Components* table. Key new types:
```swift
struct ClassificationResult { let categoryId: UUID?; let confidence: Double }  // nil id = uncertain
enum QueueItemOrigin { case manual; case recorderImport(deviceId: UUID) }
```

### Classification AI call (logical contract)
```
INPUT  → system: "Classify the transcript into exactly one category id, or 'uncertain'.
                  Categories: [{id, name, classifierDescription}]. Return JSON {categoryId, confidence}."
         user:   <raw transcript or its head/representative excerpt>
OUTPUT ← { "categoryId": "<uuid>" | "uncertain", "confidence": 0.0–1.0 }
```
Reuses provider routing + retry from `AIEnhancementService` / `AIChatCompletionService`
(`Services/AIEnhancement/AIChatCompletionService.swift:4`).

### Error Codes (internal `RecorderAutomationError`)
| Case | Meaning | Handling |
|---|---|---|
| `bookmarkStale` | Source/vault bookmark can't resolve | Notify; prompt re-grant in Recorders page; keep original |
| `classificationFailed` | AI classify call failed after retries | Route to fallback category; record low confidence |
| `enhancementFailed` | `AIEnhancementService` returned error | Mark item failed; keep raw transcript + original file |
| `exportFailed` | Vault write failed | Mark item failed; do **not** delete original |

### Versioning Strategy
Config JSON keys are version-suffixed (`recorderDevicesV1`); bump suffix + migrate on
breaking shape changes (mirrors `ModeManager`'s `modeConfigurationsV2`).

---

## Non-Functional Requirements

| Category | Target | Measurement | How Achieved |
|---|---|---|---|
| Reliability | Exactly-once per source file across re-mounts/restarts | Unit test re-mount + restart scenarios | Content-hash ledger; success-gated delete |
| Security | No reads outside granted folders; secrets in Keychain | Code audit of file access + entitlements | Security-scoped bookmarks; reuse `KeychainService`/`APIKeyManager` |
| Responsiveness | Import-start notification ≤ ~3 s after mount | Manual timing on real device | Sync fast scan; async heavy work |
| Observability | Full per-stage trace | Console.app filter on category | `os.Logger` category `RecorderAutomation` |
| Robustness (long audio) | 90-min transcript summarized without context overflow | Test with synthetic long transcript | Token-estimate gate + map-reduce |

---

## Technology Choices

| Concern | Choice | Alternatives | Rationale |
|---|---|---|---|
| Mount detection | `NSWorkspace.didMountNotification` | DiskArbitration, FSEvents on `/Volumes` | Highest-level, idiomatic, least code; volume-granular |
| Config persistence | JSON in `UserDefaults` (`RecorderConfigStore`) | New SwiftData models | Mirrors proven `ModeManager`; config is small + non-queryable |
| Dedup persistence | SwiftData `@Model` `ImportLedgerEntry` | UserDefaults set, sidecar file | Needs queryable exactly-once across restarts |
| Dedup key | `(filename,size)` fast filter + SHA-256 confirm | filename+mtime only; hash only | Cheap common case, robust on collision (user chose both) |
| Classification | Separate lightweight AI call | Fold into enhancement prompt | Returns confidence, enables fallback/badge/re-run (user chose separate) |
| Enhancement | Reuse `AIEnhancementService.enhance()` | New analysis engine | 80% reuse; provider routing/retry/filter already solid |
| Speaker labeling v1 | Prompt-based inference | Real diarization now | Zero cost; validate quality before wiring diarization |
| Diarization (M5) | FluidAudio `OfflineDiarizerManager` | Add new dependency | Already linked (`FluidInference/FluidAudio`); no new dep |
| Export format | Markdown + YAML frontmatter | JSON, plain txt | Obsidian-native; frontmatter carries metadata |

---

## Integration Points

| Touchpoint | Type | Contract | Backwards Compat |
|---|---|---|---|
| `AudioTranscriptionManager.addToQueue` + `processItem` | In-process call + branch | Add `origin` tag; skip Mode enhancement for recorder items | Yes — manual path unchanged |
| `AIEnhancementService.enhance()` | In-process async | `(text, prompt) → enhanced` | Yes — additive caller |
| `CustomPrompt` / prompt store | Read | Category binds an existing prompt id | Yes — no schema change to prompts |
| `Transcription` `@Model` | Schema (additive) | New optional fields | Yes — lightweight migration |
| `NotificationManager.showNotification` | In-process call | Start/complete toasts | Yes — additive |
| Sidebar `ViewType` / `AppSidebar` | UI registration | Two new cases + items | Yes — additive |
| Schema array in `VoiceInk.swift:48-81` | App bootstrap | Add `ImportLedgerEntry` | Yes — additive |

### Rollout Strategy
Feature is inert until the user configures ≥1 `RecorderDevice`. No flag needed for personal
fork; if desired, gate behind an `@AppStorage("recorderAutomationEnabled")` toggle. Kill switch =
disable auto-import per device. Rollback = remove `ImportLedgerEntry` from Schema + delete config
keys (optional fields harmless).

---

## Codebase Patterns to Follow

| Pattern | Where to Find | Why Follow |
|---|---|---|
| `@MainActor` singleton service | `Services/AudioFileTranscriptionManager.swift:8-24` | Shape for `RecorderDeviceMonitor` / `RecorderImportService` |
| JSON config in UserDefaults | `Modes/ModeConfig.swift:276-287` | `RecorderConfigStore` for devices/categories |
| SwiftData `@Model` + Schema registration | `Models/Transcription.swift:12`, `VoiceInk.swift:48-81` | `ImportLedgerEntry`; additive `Transcription` fields |
| Additive migration | `Models/Transcription.swift:28-31` (`@Attribute(originalName:)`) | Safe field additions |
| AI enhancement call | `Services/AIEnhancement/AIEnhancementService.swift:394` | Reuse for category enhancement |
| AI chat completion (for classify) | `Services/AIEnhancement/AIChatCompletionService.swift:4` | Lightweight classification call |
| Provider/key resolution | `Services/AIEnhancement/AIService.swift:4`, `APIKeyManager.swift:12-27`, `KeychainService.swift:8-55` | Reuse provider routing + secrets |
| Security-scoped bookmark + access | `Views/AudioTranscribeView.swift:347-355`, `Services/AudioFileTranscriptionManager.swift:138-139` | Source folder + vault root access |
| File import + supported types | `Services/SupportedMedia.swift`, `AudioFileTranscriptionManager.swift:28-43` | Scan + filter device files |
| Queue lifecycle + status phases | `Models/AudioFileQueueItem.swift:4-38`, `AudioFileTranscriptionManager.swift:72-90` | Tagging + processing recorder items |
| Persist + notify on completion | `AudioFileTranscriptionManager.swift:247-250` | Post-processor persistence + toasts |
| Floating notifications | `Notifications/NotificationManager.swift:12-81`, `AppNotifications.swift:3-23` | Import start/complete toasts + new `Notification.Name` |
| Sidebar routing | `Views/ContentView.swift:4-16,67-88`, `Views/Sidebar/AppSidebar.swift:69-126` | Recorders / Categories pages |
| ~400pt slide-out panel | `Views/Components/SidePanel.swift:87-100`, `Modes/ModeView.swift:17-65` | Device card → form |
| Reusable prompt editor | `PromptEditorView` / `PromptSelectionGrid` | Editing the prompt a category binds |
| FluidAudio service wrapper | `Transcription/FluidAudio/FluidAudioTranscriptionService.swift` | (M5) where to wire `OfflineDiarizerManager` |

---

## Risks & Trade-offs

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| App sandbox blocks reading `/Volumes/<device>/...` without proper entitlement/bookmark | M | H | User grants source folder once via `NSOpenPanel` → security-scoped bookmark; verify entitlements in planning; "Scan now" fallback |
| Volume-name matching is fragile (rename / duplicate names) | M | M | Match volume name + optional marker file; allow re-identify when device is plugged in |
| Classification accuracy below trust threshold | M | M | Fallback category + confidence floor; manual re-classification (AC-7); product metric tracked in PRD |
| Long-transcript context overflow | M | M | Token-estimate gate + map-reduce (FR-8 / AC-6) |
| Delete-after-import data loss | L | H | Default off; gated on full success of import+transcribe+export (AC-8) |
| Diarization model download size / compute (M5) | M | L | Off by default; only download when user opts in; v1 prompt inference unaffected |
| Sequential queue serializes long imports | L | M | Acceptable for personal use; background; notifications keep visibility |

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|----------|--------|--------------|-----------|
| Recorder enhancement flow | Dedicated post-processor, bypass active Mode | Map classification to a Mode | Decouples transcription from enhancement so classify can sit between |
| Classification | Separate lightweight AI call (category + confidence) | Combined with enhancement | Enables fallback, badge, re-run, confidence gate |
| Dedup key | filename+size fast filter + SHA-256 confirm | filename+mtime; hash-only | Cheap common case + robust (user decision) |
| Delete originals | Default off, optional, success-gated | Always delete; never | Safety first (user decision) |
| Diarization | Spec both: prompt inference v1, real FluidAudio M5 | Prompt-only; diarization-only | Library already linked; validate quality first (user decision) |
| Export | Markdown: frontmatter + analysis + collapsible raw | Analysis only; two files | Obsidian-friendly, max info in one file (user decision) |
| Config storage | JSON in UserDefaults | SwiftData | Mirrors ModeManager; small non-queryable config |
| Mount detection | `NSWorkspace.didMountNotification` | DiskArbitration/FSEvents | Idiomatic, least code |

---

## Open Questions

- [ ] Sandbox entitlements: confirm bookmarked removable-volume folder access is permitted by
  VoiceInk's `*.entitlements`.
- [ ] Map-reduce chunk size + token-estimate method; persist full transcript + summary or summary only.
- [ ] Confidence floor for fallback (calibrate on real recordings).
- [ ] Export filename convention + collision policy.
- [ ] Multiple recorders / rotating source folders — v1 boundary.
- [ ] Should the classifier see the full transcript or a representative excerpt (cost vs accuracy)?
