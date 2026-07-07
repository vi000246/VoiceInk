---
linear_issue: null
---
# SRS: iCloud Recorder Sources (Just Press Record / Voice Memos)

## Metadata
- **Module**: `recorder-automation`
- **Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source PRD**: `docs/prd/icloud-recorder-sources.prd.md`
- **Source Linear Issue**: N/A
- **Created**: 2026-07-06
- **Grill level**: 1 (standard)
- **Plans**:
  - `docs/plans/recorder-automation-icloud-sources.plan.md` (Mode B, created 2026-07-07)

## Feature Summary

Adds **preset iCloud-backed recorder sources** — Just Press Record (iCloud Drive container) and Apple Voice Memos (local group container synced by CloudKit) — with the plumbing today's `.folder` sources lack: **recursive scanning**, **iCloud dataless-placeholder download-then-import**, sync-aware watching, forced keep-originals, per-source default category, and path/creation-date recording-time recovery.

## Delta from Current Module State

> Refer to `docs/spec/recorder-automation.spec.md`. Key existing gaps this feature closes (verified in code):
> scan is **flat** (`contentsOfDirectory`, `RecorderImportService.swift:38-40` — same flat pattern at `:159,:256,:279,:327,:348`); a dataless iCloud file's fingerprint read **throws and the file is silently skipped with no download trigger** (`try?` at `:56`; streaming SHA-256 at `ImportLedger.swift:18-28`); the vnode watcher is per-folder non-recursive (`RecorderFolderWatcher.swift`); recording-time recovery parses `yyMMdd_HHmm` filenames only and the ledger stores `lastPathComponent` only (`RecorderRecordingTime.swift:23-26`, ledger write at `RecorderImportService.swift:59`).

### New / Changed API Endpoints

N/A — no HTTP API. New OS contracts: `NSMetadataQuery` with **explicit folder-URL search scope** (NOT the ubiquitous-scope constants — those only cover our own container), `URLResourceKey.ubiquitousItemDownloadingStatusKey`, `FileManager.startDownloadingUbiquitousItem(at:)`.

### New / Changed Data Models

- **CHANGED** `RecorderDevice` (`Services/RecorderAutomation/RecorderDevice.swift`) — **additive fields, NO new `Kind` case** (an old build decoding an unknown Kind raw value fails that element's decode; fields default in safely via the existing `decodeIfPresent` pattern, `:29-39`):
  - `recursive: Bool = false` — gates enumerator-based scan + recursive watching.
  - `isICloudSource: Bool = false` — gates placeholder handling, the metadata-query watcher, and **forces keep-originals**.
  - `presetKind: String?` — `"justPressRecord" | "voiceMemos"` (nil = custom); drives auto-location + UI labeling.
  - `defaultCategoryId: UUID?` — when set, classification is skipped and this category applied (device-level analog of meeting-capture's fixed category).
- **CHANGED** `ImportLedgerEntry` (`Models/ImportLedgerEntry.swift`) — additive `relativePath: String?` (path under the source folder) so recording-time recovery can use date-named parent folders; lightweight migration.
- **UNCHANGED** dedup semantics: content SHA-256 remains the identity — a re-synced/re-downloaded file dedups correctly.

### Changed Business Logic

- `RecorderImportService.newImportableFiles` — recursive `FileManager.enumerator` when `device.recursive`; prefetch adds ubiquity keys for `isICloudSource`; **dataless files**: count as `deferred`, batch-trigger `startDownloadingUbiquitousItem` **off-main and outside the metadata-query callback** (main-queue batch storms are a known pitfall), rely on existing `scheduleRecheck` loop until materialized; fingerprint only after download completes.
- **Watcher split by source type**:
  - JPR (iCloud Drive): new `ICloudSourceWatcher` — `NSMetadataQuery` with `searchScopes = [folderURL]` + audio-extension predicate; update notifications → debounce → `importNewFiles`. Rides on filesystem read access (non-sandboxed app).
  - Voice Memos: **NOT ubiquitous** — a plain local folder inside `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/` (flat, CloudKit-synced by the OS). Existing vnode `RecorderFolderWatcher` works unchanged; no placeholder handling needed.
  - `RecorderFolderWatcher.sync()` (`:31-41`) skips `isICloudSource` devices; both watchers rescan on wake/app-activate + manual 「立即掃描」.
- `RecorderPostProcessor.suggestCategory` — short-circuit when the source device has `defaultCategoryId` (shares the `fixedCategory` parameter added by the meeting-capture SRS).
- `RecorderRecordingTime` — accept `relativePath` + file creation date: pattern chain = existing `yyMMdd_HHmm` filename → `yyyy-MM-dd` parent folder + `HH-mm-ss` filename (JPR) → file creation date (Voice Memos' opaque names) → import time.
- `RecordersSettingsView` (`Views/Settings/RecorderSettingsView.swift` panel `:471+`) — preset buttons in the 類型 section (`:525-531`): auto-locate the folder, build the security-scoped bookmark programmatically (non-sandboxed; `canSave` requires a bookmark, `:513-517`), fall back to `NSOpenPanel` (`chooseSourceFolder()` `:562-580`) when auto-location fails. Voice Memos preset shows a readability check + Full Disk Access guidance (deep-link to System Settings) when the folder is unreadable.
- Import copy/enqueue/ledger/staging path unchanged (`copyIntoAppStorage` `:368`).

### Explicitly Out of Scope

- Building an iOS/watchOS app; writing back or deleting anything in the source folders (**delete-after-import is force-disabled and hidden for `isICloudSource`**); reading Voice Memos' internal title database (titles fall back to filename/date); non-Apple cloud folders; minute-level sync-latency guarantees (bounded by iCloud/CloudKit sync).

## Functional Requirements

- [ ] **FR-1** 「新增來源」presets: Just Press Record — auto-locate the container under `~/Library/Mobile Documents/` (glob `iCloud~com~openplanetsoftware~*`; literal name unverified — see Open Questions), else open-panel fallback; source saved with `recursive=true, isICloudSource=true, presetKind`.
- [ ] **FR-2** Voice Memos preset: fixed group-container path; readability probe; if unreadable, show 完整磁碟取用權 guidance and re-check on return; saved with `recursive=false, isICloudSource=false*, presetKind="voiceMemos"` (*local folder — but keep-originals still forced via presetKind).
- [ ] **FR-3** Recursive scan imports files from nested date folders (JPR `YYYY-MM-DD/HH-MM-SS.m4a`); all supported audio extensions (JPR can produce m4a/wav/aiff — never hardcode m4a; `SupportedMedia.swift:5-8` already covers these).
- [ ] **FR-4** A dataless placeholder is never silently dropped: download is triggered, the file counts as deferred, and it imports automatically once materialized (recheck loop), including across app restarts (initial sweep).
- [ ] **FR-5** Originals in preset/iCloud sources are never deleted or modified, regardless of any toggle state.
- [ ] **FR-6** `defaultCategoryId` on a source skips the classifier and applies the category + its template directly (verifiable: zero classification calls).
- [ ] **FR-7** Recording time on imported items reflects true recording time via the pattern chain (path date / filename / creation date), not import time, wherever recoverable.
- [ ] **FR-8** Source card shows liveness: last scan time, pending-download count, and a manual 「立即掃描」 button.
- [ ] **FR-9** Sync races produce no duplicates: repeated metadata-query bursts, re-downloads, and rename-in-place all dedup via content fingerprint (existing ledger).

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| Reliability | Exactly-once per recording across sync/download/restart races | Content-hash ledger (unchanged) + fingerprint-after-materialize |
| Responsiveness | No main-thread stalls during download storms | Batch download triggers off-main; metadata callbacks only schedule |
| Robustness | Source folder evicted/missing → clear status, no crash loop | Liveness UI (FR-8) + watcher error path mirrors existing bookmark-stale handling |
| Compatibility | Existing configured sources unaffected | Additive `decodeIfPresent` fields; no key bump |

## Architecture Notes

- **Two watcher strategies on purpose**: iCloud Drive folders get `NSMetadataQuery` (sync events + download-status keys; vnode misses subfolder events), while Voice Memos' group container is an ordinary flat local folder — reusing the proven vnode watcher avoids Spotlight-indexing uncertainty over `~/Library` (Group Containers indexing is one of the Open Questions; the vnode path sidesteps it entirely).
- Per-source `defaultCategoryId` and meeting-capture's `meetingFixedCategoryId` converge on the same `RecorderPostProcessor.process(fixedCategory:)` seam — implement once.
- JPR nesting means the **watcher AND all five flat-scan sites** need the recursive path gated by `device.recursive` — but only `newImportableFiles`/`reprocess` strictly need it for v1; the cleanup/duration helpers follow.

## Acceptance Criteria

### AC-1: 手錶錄音自動進庫（JPR happy path）
- **Given**: a configured JPR preset source; auto-import on
- **When**: a new recording appears in a nested date folder (simulate: copy a file into `<source>/2026-07-06/`)
- **Then**: it is imported exactly once, transcribed, classified (or default-categorized), exported to the vault; its Transcription timestamp reflects the path-derived recording time
- **Test**: `RecorderImportServiceTests::recursiveScanFindsNestedFiles`, `RecorderRecordingTimeTests::parsesJPRPathDates` (pure seams) + manual end-to-end

### AC-2: 佔位檔下載後匯入
- **Given**: a dataless placeholder in the source folder (evict via Finder 「移除下載項目」)
- **When**: a scan runs
- **Then**: download is triggered; item shows as pending; after materialization it imports automatically without user action; no silent skip
- **Test**: manual (requires real iCloud) + unit for the deferred-counting seam with mocked resource values

### AC-3: 原始檔不可侵犯
- **Given**: any preset source with hypothetical delete-after-import forced on in stored JSON
- **When**: an import completes
- **Then**: the source file still exists untouched
- **Test**: `RecorderImportServiceTests::icloudSourceNeverDeletesOriginals`

### AC-4: 預設分類跳過分類器
- **Given**: a source with `defaultCategoryId` = 獨白記錄
- **When**: a recording imports
- **Then**: zero classification calls; category + its template applied
- **Test**: `RecorderPostProcessorTests::deviceDefaultCategoryShortCircuits`

### AC-5: 舊設定相容
- **Given**: `recorderDevicesV1` JSON written by the previous build
- **When**: the new build loads
- **Then**: all sources decode with defaults (`recursive=false` etc.) and behave exactly as before
- **Test**: `RecorderDeviceTests::decodesLegacyJSONWithDefaults`

### AC-6: 同步風暴不重複
- **Given**: the same file reported by multiple metadata-query bursts / re-downloaded after eviction
- **When**: scans run repeatedly
- **Then**: exactly one Transcription exists for it
- **Test**: unit on ledger dedup path (existing pattern) + manual soak

## Open Questions

- [ ] **JPR literal container folder name** — vendor KB blocked (HTTP 403); verify on the user's machine (`ls ~/Library/Mobile\ Documents/ | grep -i openplanet`) before hardcoding the glob. User must have JPR's 「iCloud Drive」storage mode on (it has 3 storage backends).
- [ ] **Voice Memos folder readability**: does the group container require Full Disk Access on macOS 26 for a non-sandboxed app? (Expected yes — protected-data class.) Also verify the Tahoe path is still `group.com.apple.VoiceMemos.shared/Recordings`.
- [ ] **Voice Memos sync trigger**: uncorroborated claim that recordings only sync down after Voice Memos.app has been opened once with iCloud on — verify; if true, preset UI copy must say so.
- [ ] **`.qta` format** (unverified report: iOS 26-originated Voice Memos) — if real, extend `SupportedMedia`.
- [ ] JPR pro formats (wav/aiff, up to 96 kHz) — confirm ElevenLabs accepts them at size; large wav could approach chunk gates on very long recordings.
