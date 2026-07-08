# Spec: Recorder Automation

## Metadata
- **Module**: recorder-automation
- **Parent Module**: N/A
- **Sub-modules**: N/A
- **Source PRDs**:
  - `docs/prd/recorder-auto-import-and-template-routing.prd.md` — initial creation
  - `docs/prd/meeting-capture-to-obsidian.prd.md` — meeting capture (2026-07-06)
  - `docs/prd/icloud-recorder-sources.prd.md` — iCloud sources: JPR / Voice Memos (2026-07-06)
  - `docs/prd/ask-ai-and-recording-library.prd.md` — Recording Library upgrade, M1 (2026-07-06; M2–3 live in `docs/spec/ask-ai.spec.md`)
- **Source Linear Issue**: N/A
- **Owner**: TBD (personal fork — vi000246/VoiceInk)
- **Status**: ACTIVE — living document
- **Created**: 2026-06-29
- **Last Updated**: 2026-07-06

## Change History

| Date | Source PRD | Feature SRS | Summary |
|------|------------|-------------|---------|
| 2026-07-08 | N/A（v2 需求） | `docs/srs/completed/recorder-automation-meeting-into-recorder-input.srs.md` | **會議併入錄音輸入 implemented（WP5，build 234）** — `.meetingCapture` 後處理改 `process(fixedCategory: nil)`，與錄音筆匯入同路徑（自動分類/尊重自動匯出/錄音管理手動套範本，不強制「會議」）;錄音設定的「固定分類」picker 移除;`recorderSourceLabel` 保留。 |
| 2026-07-08 | N/A（v2 需求） | `docs/srs/recorder-automation-meeting-into-recorder-input.srs.md` | **會議併入錄音輸入 spec'd（WP5，未實作）** — 反轉會議「固定會議分類」自動行為:`.meetingCapture` 改走 `process(fixedCategory: nil)`，與 `.recorderImport` 同路徑（自動分類/尊重自動匯出/錄音管理手動套範本）;`recorderSourceLabel` 保留供 tag 篩選;會議設定併入「錄音輸入」側欄群。 |
| 2026-07-07 | `docs/prd/icloud-recorder-sources.prd.md` | `docs/srs/completed/recorder-automation-icloud-sources.srs.md` | **iCloud sources implemented (build 230).** Tasks 1-8: additive `RecorderDevice` fields (`recursive`/`isICloudSource`/`presetKind`/`defaultCategoryId`, legacy-safe decode); recursive enumerator scan + `relativePath` through ledger (new column); dataless placeholders defer + batch `startDownloadingUbiquitousItem` (never silently skipped); `protectsOriginals` double gate; per-device default category rides `process(fixedCategory:)`; recording-time chain (filename → JPR dated path → creation date) converged in one `recordingDate` helper; new `ICloudSourceWatcher` (NSMetadataQuery folder scope + wake/activate rescan), vnode watcher skips iCloud sources; preset buttons (JPR glob + VM readability probe w/ FDA guidance). 8+2 unit tests; suite green. Also build 228-229: meeting empty-recording guard + neutral no-audio hint. |
| 2026-07-07 | `docs/prd/meeting-capture-to-obsidian.prd.md` | `docs/srs/completed/recorder-automation-meeting-capture.srs.md` | **Meeting capture implemented (build 227).** T1-T9 shipped (T10 reminder deferred): `MeetingCaptureService` (system-wide process tap + private aggregate w/ mic, raw HAL IOProc, mono AAC m4a, device-change rebuild, zero-signal probe), `MeetingCaptureController` + floating indicator + menu-bar item + `.toggleMeetingRecording` global shortcut, `.meetingCapture` queue origin → `process(fixedCategory:)` skips classifier (fixed 「會議」 default), `recorderSourceLabel` end-to-end (history chip + `來源:` frontmatter), `importMeetingFile`/`stageMeetingFile`, `NSAudioCaptureUsageDescription`. Two pre-flagged API fixes at build time ([AudioObjectID] init, qualified CATapMuteBehavior) + ShortcutMigration exhaustive switch. 12 new unit tests; full suite green. Manual TCC/device-switch ACs tracked in Linear verification issue. |
| 2026-07-06 | `docs/prd/meeting-capture-to-obsidian.prd.md` | `docs/srs/completed/recorder-automation-meeting-capture.srs.md` | **Meeting capture spec'd** — one-hotkey system-audio (CoreAudio process tap + private aggregate w/ mic, raw HAL IOProc — NOT AVAudioEngine) mixed mono m4a → existing import pipeline via new `.meetingCapture` origin; optional fixed 「會議」 category skips classifier (`process(fixedCategory:)` seam); new `MeetingCaptureService` + indicator window + `NSAudioCaptureUsageDescription`. Not yet implemented. |
| 2026-07-06 | `docs/prd/icloud-recorder-sources.prd.md` | `docs/srs/recorder-automation-icloud-sources.srs.md` | **iCloud sources spec'd** — JPR / Voice Memos presets via additive `RecorderDevice` fields (`recursive`/`isICloudSource`/`presetKind`/`defaultCategoryId`; deliberately NO new Kind case); recursive scan + dataless-placeholder download-then-import; `NSMetadataQuery` watcher for iCloud Drive, existing vnode watcher for VM group container; keep-originals forced; path/creation-date recording-time recovery. Not yet implemented. |
| 2026-07-06 | `docs/prd/ask-ai-and-recording-library.prd.md` | `docs/srs/recorder-automation-recording-library.srs.md` | **Recording Library spec'd** — Recording Management page moves to cursor pagination + predicate-side filters (category/source/status/starred/date) + sort, batch star/reclassify/re-export, new `#Index` on `recorderCategoryId`/`recorderFavorite`/`recorderSourceDeviceId`, page-scoped ledger lookups, and the citation focus hook consumed by the `ask-ai` module. Not yet implemented. |
| 2026-07-02 | free-form request | N/A | **OpenCC dictionaries vendored (build 207).** SwiftyOpenCC 1.0.1's `Package.swift` declares no SPM resources, so build 206 shipped WITHOUT the `.ocd` dictionaries → `ChineseConverter` init threw → conversion silently no-oped. Fix: vendored the package's prebuilt `OpenCCDictionary.bundle` (Contents/Resources/Dictionary/*.ocd) into `VoiceInk/Resources/`; `TraditionalChineseConverter` loads it via `Bundle.main.url(forResource:"OpenCCDictionary", withExtension:"bundle")`. Verified the `.bundle` copies into the app intact (not flattened) + an end-to-end test proves conversion works. ⚠️ Keep this bundle whenever changing the OpenCC dependency. |
| 2026-07-02 | free-form request | N/A | **Recorder perf + 繁中 + speaker export (build 206).** (1) **Single diarized call**: the recorder's transcription step now makes ONE ElevenLabs `diarize=true` call that serves as BOTH the transcript and the speaker segments (cached in `DiarizationCoordinator`, consumed by post-processing) — no more transcribing an hour of audio twice. Falls back to a normal transcription if it fails. (2) **Traditional Chinese** via OpenCC (SwiftyOpenCC 1.0.1, product `OpenCC`): `TraditionalChineseConverter` (`.traditionalize + .TWStandard`, no idiom rephrasing) converts transcript + speaker segments once in `RecorderPostProcessor` before classify/analyse/export; Recorder Mode toggle `輸出繁體中文` (`recorderConvertToTraditional`). (3) **Speaker-separated export**: Obsidian `## 原始逐字稿` renders `**講者N：** …` when natively diarized. (4) **TranscriptSheet perf**: decode segments once (was O(n²) via per-segment `displayName`), `LazyVStack`, plain `Text` for the raw transcript (skip Markdown parsing). (5) **Reveal-in-vault**: `在 Vault 顯示` shows `已匯出` when the exported file was moved/renamed instead of a dead button. |
| 2026-07-02 | free-form request | N/A | **Chunking made provider-aware — ElevenLabs never chunks.** Recordings were still being split into ~10-min WAV chunks because the chunk gate (`AudioFileTranscriptionManager`) and the `fileTooLarge` guard (`CloudTranscriptionService`) used a fixed 25MB limit for ALL cloud providers. Added `ModelProvider.maxUploadBytes` (ElevenLabs 2GB, others ~25MB); both sites now gate on it, so an ElevenLabs recording is transcribed + diarized as ONE file. Timeout ceiling raised 600s→1800s for large single uploads. Build 204. |
| 2026-07-02 | free-form request | N/A | **方案 C — diarization unified on whole-file ElevenLabs; FluidAudio diarization fallback REMOVED.** Root cause of "only the first 10-min chunk had speakers": the recorder reused the transcript path's <25MB WAV chunks for diarization, and ElevenLabs numbers speakers per request (so chunk N's `speaker_0` ≠ chunk N+1's). Two failed attempts recorded so we don't retry them (see **Key Decisions** below): (M2) per-chunk merge only labelled the whole transcript, ids still restarted per chunk; (方案 A) using a single local FluidAudio diarizer pass for a consistent timeline collapsed the whole recording to ONE speaker (FluidAudio diarization too weak on real audio). **Fix:** ElevenLabs STT accepts up to 5GB and diarizes long audio natively (up to 48 speakers, consistent), so the diarization call now sends the WHOLE recording in ONE request (`DiarizationCoordinator` reassembles chunks → one WAV when needed). Recorder transcription model is hardcoded to ElevenLabs `scribe_v2` via `RecorderTranscriptionConfig.transcriptionModelName` (settings picker hidden). `FluidAudioDiarizer` + `DiarizationAlignment` deleted; FluidAudio remains the app's local *transcription* engine (unchanged). Build green; tests trimmed to the surviving seams. |
| 2026-06-29 | `docs/prd/recorder-auto-import-and-template-routing.prd.md` | `docs/srs/recorder-automation-auto-import-template-routing.srs.md` | Created from brownfield analysis — new module that watches recorder volume mounts, auto-imports audio into the existing transcription queue, classifies each transcript, routes to a category's CustomPrompt, and exports analysis Markdown to an Obsidian vault. |
| 2026-06-29 | same | same | **M1 implemented** — mount monitor, import ledger (SHA-256 dedup), device config/store, queue origin tag + raw-transcription bypass, minimal Recorders page. Build green; 5 unit tests. |
| 2026-06-30 | same | same | **M2 implemented** (FR-6–11,13,14) — `TranscriptClassificationService` (classify→id/uncertain+confidence), `TemplateRouter` (fallback on uncertain/below-floor), `LongTranscriptSummarizer` (map-reduce), `VaultExportService` (frontmatter+collapsible raw md), `RecorderPostProcessor` (orchestrator wired into `processItem`), `RecorderCategory` + store w/ undeletable fallback, Categories page, vault-root capture, delete-after-import. FR-12 partial: `reclassify` logic done, History badge UI deferred. 18 unit tests green. Manual/hardware AC pending. |
| 2026-06-30 | extends | `docs/srs/recorder-automation-recorder-mode-and-recording-management.srs.md` | **M3 spec'd** — two pipelines fully separated: recorder prompts split from voice prompts (`recorderPrompts` store, implemented); new **Recorder Mode** (own transcription model + default analysis model + language, decoupled from active Voice Mode); export shifts to **manual** by default (import = transcribe + suggest category only); new **Recording Management** page (replaces Import Log) with raw audio/transcript preservation, manual template apply→preview→export, delete-audio / delete-record; recorder audio exempt from auto-cleanup. Implemented so far: prompt split, sectioned sidebar + renames, rich recorder log, cleanup exemption. Pending: Recorder Mode page, manual apply/export flow, auto-export toggle. |
| 2026-07-01 | code-sync | N/A | **Synced to code** — (1) new **watched-folder source**: `RecorderDevice.Kind` (`.volume`/`.folder`) lets an ordinary always-present folder be monitored (not just removable volumes); new `RecorderFolderWatcher` (per-folder `DispatchSource` vnode watcher, debounced, file-stability gated). (2) `handleMount`→`importNewFiles` unified entry; `newImportableFiles` now returns `(candidates, deferredCount)` with `minimumStableAge` + `hasQuickMatch` pre-skip for mid-copy files. (3) **Export raw-transcript is now opt-in**: `recorderExportIncludeRawTranscript` (default off → analysis-only note); when on, the full transcript is appended under a `## 原始逐字稿` rule (replaces the always-on collapsible callout). |
| 2026-07-01 | code-sync | `docs/plans/completed/recorder-automation-speaker-diarization-m2.plan.md` | **Diarization M2 implemented (AC-4) — universal.** On-device FluidAudio fallback for non-native models: `DiarizationAlignment` (pure token↔speaker-timeline max-overlap) + `FluidAudioDiarizer` (Parakeet ASR token timings + offline diarizer on the same 16kHz samples); `DiarizationCoordinator` now falls back to it for any non-native model or native failure. Settings copy clarifies native (ElevenLabs) vs local fallback. Build green; 15 pure-seam tests. M3 (other native providers, shared Parakeet instance, export labels) deferred. |
| 2026-07-01 | code-sync | `docs/plans/completed/recorder-automation-speaker-diarization-m1.plan.md` | **Diarization M1 implemented** — `SpeakerSegment` + `Transcription` segment/rename accessors; `supportsNativeDiarization` capability (ElevenLabs); in-repo `ElevenLabsDiarizingClient` (`diarize=true`); `DiarizationCoordinator` (native route + graceful degrade); Recorder Mode toggle + expected-speakers; wired into `RecorderPostProcessor`; speaker-grouped transcript view + rename. Build green; 11 pure-seam tests. FluidAudio fallback / Whisper alignment (AC-4) remain M2. |
| 2026-07-01 | free-form request | `docs/srs/recorder-automation-speaker-diarization.srs.md` | **Universal speaker diarization spec'd** — **replaces the old M5/FR-15 FluidAudio-only plan** with a hybrid, provider-agnostic design: a `DiarizationCoordinator` routes native-capable models (ElevenLabs first) through a new in-repo `ElevenLabsDiarizingClient` (`diarize=true`, `words[].speaker_id`) and everything else through a `FluidAudioDiarizer` fallback aligned to transcript timestamps. New `SpeakerSegment` type + `speakerSegmentsRaw`/`speakerNamesRaw` on `Transcription` (reusing existing `speakerLabeled`). Speakers are anonymous (講者1/2) and **manually renamable** transcript-wide. Off by default; batch recorder imports only (no streaming). Not yet implemented. |

## Summary

`recorder-automation` is a new VoiceInk module that turns a plugged-in physical recorder into a
zero-click "audio → classified, formatted note" pipeline. It adds disk-mount monitoring and a
post-transcription classification router on top of VoiceInk's existing batch file-transcription
and AI-enhancement capabilities, then exports results as Markdown into a vault. The design
**reuses ~80% of VoiceInk** (transcription queue, `AIEnhancementService`, `CustomPrompt`,
security-scoped bookmarks, notifications, SwiftData history, sidebar/side-panel UI) and adds
only thin new services plus two settings pages.

---

## Key Decisions / 踩雷筆記 (diarization)

> **Read this before touching recorder diarization.** These are locked-in decisions from real
> failures — don't re-introduce the removed approaches.

1. **Recorder transcription model is hardcoded to ElevenLabs `scribe_v2`.**
   Single source of truth: `RecorderTranscriptionConfig.transcriptionModelName`. The Recorder Mode
   settings picker is hidden. Rationale: ElevenLabs accepts the whole recording in one request
   (≤5GB) and diarizes long audio natively with **consistent speaker ids across the entire file**,
   so the recorder never has to chunk-for-diarization, stitch speakers across chunks, or fall back
   to a local diarizer. To change the model later, edit that one constant (the UI adapts).
   *Requires an ElevenLabs API key* — without one, transcription resolution falls back to the first
   usable model and diarization is unavailable.

2. **Chunking is provider-aware — ElevenLabs never chunks (transcript OR diarization).**
   Chunking is gated on `ModelProvider.maxUploadBytes`: ElevenLabs = 2GB (docs allow ~5GB), whisper-
   style providers = ~25MB. `AudioFileTranscriptionManager.transcribeSamples` only splits when the
   whole 16kHz WAV exceeds that cap, and `CloudTranscriptionService` guards on the same per-provider
   value. So an ElevenLabs recording of any realistic length is transcribed as ONE file, and
   `DiarizationCoordinator.diarize` sends that same whole recording in ONE
   `ElevenLabsDiarizingClient.transcribeDiarized` call (it still reassembles chunks into one file if
   a *different* provider ever produced them). ❌ Do not reinstate a fixed global 25MB/10-min chunk
   limit — that split ElevenLabs recordings for no reason and broke cross-chunk speaker identity.

3. **The on-device FluidAudio diarization fallback is REMOVED** (`FluidAudioDiarizer`,
   `DiarizationAlignment` deleted). It stays only as the app-wide local *transcription* engine.
   ❌ **Do not re-add a local diarizer fallback for the recorder.** Two removed attempts and why:
   - **Per-chunk merge (M2 → superseded):** diarize each chunk and offset times. Labelled the whole
     transcript but speaker ids restarted per chunk — cross-chunk identity wrong.
   - **方案 A (local global timeline):** one FluidAudio diarizer pass over the concatenated audio to
     get consistent ids, aligning ElevenLabs words onto it. **FluidAudio's diarizer collapsed the
     whole recording to ONE speaker** on real audio — its diarization quality is not good enough.
     ElevenLabs' own diarizer is far stronger; use it, don't reinvent it.

4. **Only-if-forced future path:** if a recording ever exceeds ElevenLabs' limits (≈never for a
   voice recorder), the fallback is speaker-embedding voiceprint matching across chunks — **not** a
   local frame-level diarizer. Not implemented; do not build until actually needed.

---

## Domain Model

### Bounded Context
- **Context Name**: RecorderAutomation
- **Domain Layer**: Supporting Domain (orchestrates existing Core transcription/enhancement)
- **Parent Module**: N/A

### Ubiquitous Language
| Term | Definition |
|------|-----------|
| Recorder Source (Device) | A configured audio source, modeled as `RecorderDevice`. Two `Kind`s: **`.volume`** — a removable recorder matched by mounted volume name and imported on mount; **`.folder`** — an ordinary always-present folder watched live for new files. |
| Watched Folder | A `.folder`-kind source monitored continuously by `RecorderFolderWatcher` (directory-vnode `DispatchSource`); imports fire on file changes, debounced. |
| File-stability Gate | Import skips files modified within `minimumStableAge` (4 s on the folder path) — they may still be copying in — reporting them as `deferredCount` and re-checking via `scheduleRecheck`. |
| Source Folder | The bookmarked folder holding new recordings — on the device (`.volume`) or anywhere on disk (`.folder`); user-granted + security-scoped. |
| Import | Copying a new source file into app-controlled storage and enqueueing it for transcription. |
| Import Ledger | Persistent record of already-imported files (content-hash keyed) ensuring exactly-once processing. |
| Category | A user-defined content class (e.g. 面試 / 演講 / 通用). Binds an existing `CustomPrompt`, a classifier description, and a vault sub-folder. Modeled as `RecorderCategory`. |
| Classification | One lightweight cloud-AI call mapping a raw transcript → a category id or `uncertain` + confidence. |
| Routing | Selecting the category's `CustomPrompt` for enhancement; `uncertain` → fallback category. |
| Fallback (General) Category | The undeletable default category used when classification is `uncertain`. |
| Vault Root | The Obsidian vault directory (security-scoped bookmark) under which category sub-folders live. |
| Diarization | Splitting a transcript into per-speaker segments so the user can tell who said what. **(方案 C, 2026-07-02)** Recorder path is ElevenLabs-only — see Key Decisions. |
| Native Diarization | Speaker labels returned by the transcription model's own API (ElevenLabs `diarize=true` → `words[].speaker_id`). Whole recording sent in one request → speaker ids consistent across the entire transcript. |
| ~~Diarization Fallback~~ | **SUPERSEDED (2026-07-02, 方案 C)** — local FluidAudio fallback removed; the recorder is hardcoded to ElevenLabs which diarizes natively. |
| Speaker Segment | A `{ speaker, text, start, end }` unit; consecutive same-speaker words/segments merged. Stored as JSON in `Transcription.speakerSegmentsRaw`. |
| Speaker Id vs Name | Segments carry a stable anonymous id ("1", "2"); a rename map (`speakerNamesRaw`) resolves ids → display names (講者1 → "Logan") at render time. |
| Speaker Inference (legacy) | Old prompt-driven guess of the speaker; superseded by real diarization above. |
| Meeting Capture | A system-audio (process tap) + mic mixed recording of an online meeting, entering the pipeline as a `.meetingCapture` queue item — not a `RecorderDevice`. **(spec'd)** |
| Fixed Category | A category applied without classification: `meetingFixedCategoryId` (meetings) or `RecorderDevice.defaultCategoryId` (per source). Both converge on the `RecorderPostProcessor.process(fixedCategory:)` seam. **(spec'd)** |
| iCloud Source | A `.folder` device with `isICloudSource = true` — recursive, placeholder-aware, keep-originals forced; watched via `NSMetadataQuery` instead of vnode. **(spec'd)** |
| Dataless Placeholder | An iCloud file whose content is not local. Today its fingerprint read throws and it is silently skipped; spec'd behavior = trigger download, count as deferred, import after materialization. |
| Preset Source | A one-tap source template (`presetKind`: `justPressRecord` / `voiceMemos`) that auto-locates its folder and pre-sets safe flags. **(spec'd)** |
| Recording Library | The scaled Recording Management page: predicate-filtered, cursor-paginated, batch operations, citation-focusable. **(spec'd)** |

### Domain Events
| Event | Trigger Condition | Consumers |
|---|---|---|
| `recorderDidMount` (internal) | Configured volume name matches a mounted volume (`.volume` source) | `RecorderImportService.importNewFiles` |
| folder vnode change (internal) | `DispatchSource` fires on a watched `.folder` source (write/rename/delete) | `RecorderFolderWatcher` → debounced `importNewFiles` |
| `recorderImportCompleted` (`Notification.Name`, new) | All stages succeed for an item | UI badge refresh, optional delete-after-import |

---

## System Context

### Scope & Boundaries
- **In scope**: mount monitoring (`.volume`) **and live folder watching (`.folder`)**; folder scan + dedup + import; raw transcription routing;
  post-transcription classification; template routing to `CustomPrompt`; long-transcript
  summarization; Markdown export to vault; Recorders & Categories settings UI; category badge +
  manual re-classification; optional delete-after-import; (M5) real diarization; **(spec'd
  2026-07-06)** meeting capture (system-audio tap + mic → pipeline), iCloud sources (JPR /
  Voice Memos presets: recursive + placeholder-aware + keep-originals forced), and the Recording
  Library upgrade (pagination, predicate filters, batch ops, citation focus hook).
- **Out of scope**: streaming/real-time classification; cloud sync of config; recorder firmware
  integration; a parallel template system; building a new transcription engine.

### Actors
| Actor | Type | Interaction |
|---|---|---|
| User | Human | One-time setup (sources, categories, vault); plugs in recorder or drops files into a watched folder; optionally re-classifies |
| Physical recorder | External device | Mounts as a volume (`.volume` source) exposing an audio source folder |
| Watched folder | Local filesystem | An always-present folder (`.folder` source) into which recordings are copied/synced; watched live |
| AI provider (Anthropic / OpenAI / …) | Service | Classification call + enhancement call (existing provider routing) |
| Obsidian vault (filesystem) | External store | Destination for exported Markdown notes |
| ~~FluidAudio diarizer models~~ | ~~Local ML~~ | **SUPERSEDED (2026-07-02, 方案 C)** — local diarization fallback removed; see Key Decisions. Diarization is ElevenLabs-only. |
| ElevenLabs STT API | Service | Native diarization (`diarize` param) returned inline with the transcript — the recorder's sole diarization path (whole recording, one request) |
| Online meeting app (Zoom/Teams/Meet…) | External app | Its audio output is captured via the system-wide process tap during meeting capture **(spec'd)** |
| JPR / Voice Memos folders (iCloud/CloudKit-synced) | External store | Source folders filled by Apple's sync daemons; JPR = iCloud Drive container (dataless placeholders), VM = local group container **(spec'd)** |

### External Dependencies
| Dependency | Purpose | Failure Mode |
|---|---|---|
| `NSWorkspace` mount notifications | Detect `.volume` device plug-in | If unavailable, fall back to manual "Scan now" button in Recorders page |
| `DispatchSource` directory vnode (`O_EVTONLY`) | Detect new files in `.folder` sources | Bookmark unresolvable / `open()` fails → watcher logs + skips that folder |
| AI provider (via `AIEnhancementService` / `AIChatCompletionService`) | Classification + enhancement | Reuse existing retry/backoff + graceful error strings; item marked failed, original kept |
| Security-scoped bookmarks (source folder + vault root) | Sandbox-safe file access | Stale bookmark → prompt user to re-grant in Recorders page |
| ~~`FluidInference/FluidAudio` Diarizer~~ | ~~Local diarization fallback~~ | **SUPERSEDED (2026-07-02, 方案 C)** — removed for the recorder; see Key Decisions. (FluidAudio still linked for local *transcription*.) |
| ElevenLabs STT `diarize` (via in-repo `ElevenLabsDiarizingClient`) | Sole diarization path — whole recording in one request | API error / no key → degrade to plain transcript; diarization-off case uses the unchanged LLMkit path |
| CoreAudio process tap + private aggregate device (macOS 14.2+, TCC bucket `SystemAudioCaptureRequests`, needs `NSAudioCaptureUsageDescription`) **(spec'd)** | Meeting system-audio capture | TCC denied → guidance toast, no recording; tap breaks on output-device change → teardown+rebuild both tap & aggregate, else finalize file + notify (no status API — probe-based detection) |
| `NSMetadataQuery` (explicit folder scope) + `startDownloadingUbiquitousItem` **(spec'd)** | Watch iCloud Drive sources; materialize dataless placeholders | Query silent/unreliable → wake/activate rescan + manual 「立即掃描」 fallback |
| Voice Memos group container (`~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`) **(spec'd)** | VM source folder (plain local, CloudKit-synced) | Unreadable without Full Disk Access → readability probe + guidance UI; path drift across macOS versions → Open Question |

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
| `RecorderDeviceMonitor` | Observe mount/unmount; match volume name → `.volume` device | `@MainActor` singleton; subscribes to `NSWorkspace.shared.notificationCenter`; calls `RecorderImportService.importNewFiles` |
| `RecorderFolderWatcher` | Watch `.folder` sources for new files via per-folder directory-vnode `DispatchSource`; debounce + re-check settling files | `@MainActor` singleton: `start()`, `sync()` (rebuild from device list), `scheduleRecheck(deviceId:)` |
| `RecorderImportService` | Scan source folder, dedup via ledger (with `minimumStableAge` gate + `hasQuickMatch` pre-skip), copy + enqueue, optional delete-after-success | `func importNewFiles(device:)`, `func newImportableFiles(in:context:minimumStableAge:) -> (candidates, deferredCount)` |
| `ImportLedger` | Exactly-once bookkeeping | SwiftData-backed: `func fingerprint(for:) -> String`, `func contains(_:) -> Bool`, `func record(_:)` |
| `RecorderPostProcessor` | Orchestrate classify → route → summarize → enhance → persist → export for recorder items | `func process(transcription:rawText:device:) async` |
| `TranscriptClassificationService` | One lightweight AI call → category id / `uncertain` + confidence | `func classify(_ text:, categories:) async -> ClassificationResult` |
| `TemplateRouter` | Map category → `CustomPrompt` (+ fallback) | `func prompt(for categoryId:) -> CustomPrompt` |
| `LongTranscriptSummarizer` | Map-reduce summarization above token threshold | `func condense(_ text:) async -> String` |
| `VaultExportService` | Write Markdown (frontmatter + analysis; raw transcript appended under a `## 原始逐字稿` rule **only when** `recorderExportIncludeRawTranscript` is on, default off) to vault sub-folder | `func buildMarkdown(_:includeRawTranscript:)`, `func export(...) throws -> URL` |
| `RecorderConfigStore` | Persist `RecorderDevice[]` / `RecorderCategory[]` as JSON in `UserDefaults` | mirrors `ModeManager` (`Modes/ModeConfig.swift:276-287`) |
| `DiarizationCoordinator` | **(方案 C, 2026-07-02)** ElevenLabs-only entry: reassemble chunks → one file → single whole-recording diarization request; native fallback removed | `func diarize(audioURLs:transcriptionModelName:language:expectedSpeakers:detectSpeakerRoles:) async -> Outcome?` |
| `ElevenLabsDiarizingClient` | In-repo (bypasses remote LLMkit) ElevenLabs STT call with `diarize=true`; parse `words[].speaker_id` → merged `[SpeakerSegment]` + full text | `static func transcribeDiarized(...) async throws -> Result` |
| ~~`FluidAudioDiarizer`~~ | ~~Local diarizer timeline~~ | **DELETED (2026-07-02, 方案 C)** — see Key Decisions |
| ~~Diarization alignment~~ | ~~token↔timeline max-overlap~~ | **DELETED (2026-07-02, 方案 C)** — `DiarizationAlignment` removed |
| Recorders / Categories views | Settings UI (cards + ~400pt side panel; category list) | New `ViewType` cases + `AppSidebar` entries |
| `MeetingCaptureService` **(spec'd)** | Own the tap+mic aggregate capture graph (raw HAL IOProc — NOT AVAudioEngine); mix to mono m4a in staging; teardown+rebuild on device change; finalize on any exit | `@MainActor` singleton: `start() async throws`, `stop() async -> URL?`, `@Published state` |
| `MeetingIndicatorWindowManager` **(spec'd)** | Floating red-dot + elapsed-timer indicator, decoupled from the dictation `RecordingState` machine | mirrors `MiniWindowManager` (`Views/Recorder/MiniWindowManager.swift`) |
| `ICloudSourceWatcher` **(spec'd)** | `NSMetadataQuery(searchScopes: [folderURL])` watcher for iCloud Drive sources; debounce → `importNewFiles`; batch download triggers off-main | `start()/sync()` alongside `RecorderFolderWatcher` (which skips `isICloudSource` devices) |

### Data Flow
Four entry triggers converge on `RecorderImportService`: a `.volume` **mount**
(`NSWorkspace` notification), a `.folder` **vnode change** (`RecorderFolderWatcher`, debounced,
with the file-stability gate + `scheduleRecheck` for files still copying), an **iCloud
metadata-query update** (`ICloudSourceWatcher` — spec'd; recursive scan, dataless placeholders
downloaded before fingerprinting, deferred via the same recheck loop), or a **meeting-capture
stop** (`importMeetingFile` — spec'd; staged file, `.meetingCapture` origin, optional fixed
category skipping the classifier). Editing the device list
calls `RecorderFolderWatcher.sync()` to rebuild watchers; `VoiceInk.swift` starts the watcher at
launch alongside the mount monitor. From there: folder scan + dedup (sync, fast) → copy + enqueue (async). The
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
struct RecorderDevice: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case volume, folder }   // removable device vs watched folder
    let id: UUID
    var displayName: String
    var kind: Kind                      // .volume (mount-matched) | .folder (live-watched); back-compat decode → .volume
    var volumeNameMatch: String         // .volume only — matched against mounted volume name, e.g. "IC RECORDER"
    var sourceFolderBookmark: Data      // security-scoped bookmark to the source folder (device or disk)
    var autoImportEnabled: Bool         // default true
    var deleteAfterImport: Bool         // default false
    var createdAt: Date
    // custom init(from:) decodes pre-`kind` rows as .volume; matches(volumeName:) requires .volume + non-empty match
    // vault root is a single global bookmark on RecorderConfigStore (not per-device)
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
//   var speakerLabeled: Bool = false          // existing — set true when segments present

// NEW (speaker diarization) — additive optional fields on Transcription:
//   var speakerSegmentsRaw: String?           // JSON [SpeakerSegment]
//   var speakerNamesRaw: String?              // JSON [speakerId: displayName] rename map
// computed accessors parse/serialize these, mirroring audioChunkURLs/audioChunkPathsRaw

// NEW value type (Codable) — the diarization unit:
struct SpeakerSegment: Codable, Equatable {
    var speaker: String        // stable anonymous id ("1", "2") or native provider label
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

// SPEC'D 2026-07-06 (meeting capture + iCloud sources + Recording Library) — not yet implemented:
// RecorderDevice additive fields (decodeIfPresent defaults; deliberately NO new Kind case —
// an old build decoding an unknown Kind raw value fails that element's decode):
//   var recursive: Bool = false        // enumerator-based scan + recursive watching
//   var isICloudSource: Bool = false   // placeholder handling + metadata-query watcher + keep-originals forced
//   var presetKind: String?            // "justPressRecord" | "voiceMemos" (nil = custom)
//   var defaultCategoryId: UUID?       // skip classifier, apply this category directly
// RecorderConfigStore new keys: recorderMeetingFixedCategoryIdV1, recorderMeetingMicEnabledV1
// QueueItemOrigin: new case .meetingCapture(fingerprint: String)   // meetings are not RecorderDevices
// Transcription: additive optional recorderSourceLabel: String?    // e.g. "會議 · Zoom"
// ImportLedgerEntry: additive relativePath: String?                // recording-time recovery from date folders
// Transcription #Index additions: [\.recorderCategoryId], [\.recorderFavorite], [\.recorderSourceDeviceId]
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
| Speaker diarization | **Hybrid**: native API where supported (ElevenLabs first) + FluidAudio local fallback | Native-only (drops local models); FluidAudio-only (worse quality, extra compute for cloud) | Universality across all models with best available quality per model (user decision) |
| ElevenLabs diarize client | In-repo `ElevenLabsDiarizingClient` calling the HTTP API directly | Fork/modify LLMkit `ElevenLabsClient` | LLMkit is a remote, non-editable package; keep the change in-repo |
| Local diarization engine | FluidAudio `OfflineDiarizerManager` / `DiarizerManager` | Add pyannote/sherpa-onnx dep | Already linked (`FluidInference/FluidAudio`); no new dep |
| Speaker naming | Anonymous ids + manual rename map | Voiceprint enrollment now | Simplest useful v1; enrollment (auto-naming recurring speakers) deferred (user decision) |
| Export format | Markdown + YAML frontmatter; raw transcript **opt-in** (`recorderExportIncludeRawTranscript`, default off) appended under a rule | Always-embed collapsible raw (old plan); JSON/plain txt | Obsidian-native; keep notes analysis-only by default, full transcript on demand (supersedes the always-on callout) |

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
| `RecorderFolderWatcher.shared.start()` in `VoiceInk.swift` | App bootstrap | Start folder watchers after import service is configured | Yes — additive |
| `Info.plist` `NSAudioCaptureUsageDescription` **(spec'd)** | App config | TCC usage string for the system-audio tap | Yes — additive |
| `ShortcutAction` + `RecordingShortcutManager` (`Shortcuts/ShortcutAction.swift:3,29,56,91`; `RecordingShortcutManager.swift:314`) **(spec'd)** | UI registration | New `.toggleMeetingRecording` utility shortcut (must work regardless of dictation state) | Yes — additive |
| `AppNavigator` focus companion (`pendingFocusTranscriptionId`) **(spec'd)** | In-process nav | Row-level focus into the Recording Library (consumed by `ask-ai` citations) | Yes — additive |

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
| FluidAudio service wrapper | `Transcription/FluidAudio/FluidAudioTranscriptionService.swift` | Shape for `FluidAudioDiarizer` wrapping `OfflineDiarizerManager` |
| Cloud provider + client split | `Transcription/Cloud/ElevenLabsProvider.swift`, `Transcription/Cloud/CloudProvider.swift:13` | Where the diarization-off ElevenLabs path stays; capability flag lives near the provider |
| Whisper segment timestamps | `Transcription/Whisper/LibWhisper.swift:21-24` (`whisper_full_n_segments`) | Source of segment `start`/`end` for fallback alignment |
| Multipart STT HTTP call | `LLMkit .../Transcription/ElevenLabsClient.swift` (reference only — remote) | Shape to reimplement in-repo `ElevenLabsDiarizingClient` with `diarize=true` |
| JSON-in-raw-field accessor | `Models/Transcription.swift:43-50` (`audioChunkURLs`/`audioChunkPathsRaw`) | Pattern for `speakerSegments`/`speakerSegmentsRaw` + `speakerNames` accessors |

---

## Risks & Trade-offs

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| App sandbox blocks reading `/Volumes/<device>/...` without proper entitlement/bookmark | M | H | User grants source folder once via `NSOpenPanel` → security-scoped bookmark; verify entitlements in planning; "Scan now" fallback |
| Volume-name matching is fragile (rename / duplicate names) | M | M | Match volume name + optional marker file; allow re-identify when device is plugged in |
| Classification accuracy below trust threshold | M | M | Fallback category + confidence floor; manual re-classification (AC-7); product metric tracked in PRD |
| Long-transcript context overflow | M | M | Token-estimate gate + map-reduce (FR-8 / AC-6) |
| Delete-after-import data loss | L | H | Default off; gated on full success of import+transcribe+export (AC-8) |
| Diarization model download size / compute | M | L | Off by default; download FluidAudio diarizer only when user opts into fallback; native path needs no download |
| Fallback alignment inaccuracy (timeline vs transcript timestamps drift) | M | M | Max-overlap assignment at segment granularity; only local Whisper (has segment timestamps) fully supported in v1; flat-text models degrade (FR-10) |
| Native diarization quality varies by provider / few-speaker over-splitting | M | M | Forward `expectedSpeakerCount` → `num_speakers`; expose `diarization_threshold` later if needed |
| Per-transcript speaker ids not stable across files | H | L | Documented v1 boundary; voiceprint enrollment deferred |
| Sequential queue serializes long imports | L | M | Acceptable for personal use; background; notifications keep visibility |

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|----------|--------|--------------|-----------|
| Recorder enhancement flow | Dedicated post-processor, bypass active Mode | Map classification to a Mode | Decouples transcription from enhancement so classify can sit between |
| Classification | Separate lightweight AI call (category + confidence) | Combined with enhancement | Enables fallback, badge, re-run, confidence gate |
| Dedup key | filename+size fast filter + SHA-256 confirm | filename+mtime; hash-only | Cheap common case + robust (user decision) |
| Delete originals | Default off, optional, success-gated | Always delete; never | Safety first (user decision) |
| Diarization architecture | Hybrid: native-first + FluidAudio fallback | FluidAudio-only (old M5 plan); native-only | Universality with best-per-model quality (user decision, supersedes M5) |
| ElevenLabs diarize impl | In-repo client bypassing LLMkit | Fork LLMkit | LLMkit remote/non-editable |
| Speaker naming | Anonymous ids + manual rename | Voiceprint enrollment now | Simplest useful v1 (user decision); enrollment deferred |
| Diarization scope | Batch recorder imports only | Include streaming | Streaming diarize is a separate path; keep v1 focused |
| Export | Markdown: frontmatter + analysis + collapsible raw | Analysis only; two files | Obsidian-friendly, max info in one file (user decision) |
| Config storage | JSON in UserDefaults | SwiftData | Mirrors ModeManager; small non-queryable config |
| Mount detection | `NSWorkspace.didMountNotification` | DiskArbitration/FSEvents | Idiomatic, least code |
| Meeting capture API **(spec'd)** | CoreAudio process tap + private aggregate (tap + mic ONLY), raw HAL IOProc | ScreenCaptureKit audio-only | Separate TCC bucket (no periodic re-consent nag); no dummy-video hack; ⚠️ AVAudioEngine silently ignores tap-backed aggregates |
| Meeting file format **(spec'd)** | mono 48 kHz AAC m4a (~45 MB/h) | 16 kHz WAV | Hours-long meetings stay far below the ElevenLabs 2 GB gate — Key Decision #2 upheld, never chunk |
| Meeting state UI **(spec'd)** | Separate indicator window | New `RecordingState` case | Dictation state machine gates 6+ sites; meeting recording must coexist with dictation |
| iCloud source modeling **(spec'd)** | Additive fields on `.folder` (`isICloudSource` etc.) | New `Kind.icloudFolder` case | Old builds fail decoding unknown Kind raw values; fields default in safely |
| iCloud watching **(spec'd)** | `NSMetadataQuery` explicit-folder scope (JPR); vnode kept for VM group container | Ubiquitous-scope constants; pure polling | Own-container-only scopes can't see JPR's container; VM folder is local (CloudKit-synced), not ubiquitous |
| Library scaling **(spec'd)** | Cursor pagination + predicate filters (mirror `InlineHistoryView.swift:22-59`) | Virtualized custom table; keep in-memory filtering | Proven in-repo pattern; in-memory filtering over an unbounded `@Query` is the measured bottleneck |

---

## Open Questions

- [ ] Sandbox entitlements: confirm bookmarked removable-volume folder access is permitted by
  VoiceInk's `*.entitlements`.
- [ ] Map-reduce chunk size + token-estimate method; persist full transcript + summary or summary only.
- [ ] Confidence floor for fallback (calibrate on real recordings).
- [ ] Export filename convention + collision policy.
- [ ] Multiple recorders / rotating source folders — v1 boundary.
- [ ] Should the classifier see the full transcript or a representative excerpt (cost vs accuracy)?
- [ ] (meeting) Mono mixdown vs tap-stereo→mono: ElevenLabs diarization quality difference; post-TCC-grant relaunch requirement on macOS 26; echo acceptability on speakers (headphones hint?).
- [ ] (iCloud) JPR literal container folder name (vendor KB blocked — verify `ls ~/Library/Mobile\ Documents/ | grep -i openplanet`); VM Full Disk Access requirement + Tahoe path + "sync only after VM.app opened" claim; possible `.qta` format from iOS 26 recordings.
- [ ] (library) SwiftData `#Predicate` optional-UUID equality support; page size 50 vs 20 for card rows.
