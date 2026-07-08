---
linear_issue: null
---
# SRS: Recording Library (Recording Management 量級化)

## Metadata
- **Module**: `recorder-automation`
- **Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source PRD**: `docs/prd/ask-ai-and-recording-library.prd.md` (Milestone 1)
- **Source Linear Issue**: N/A
- **Created**: 2026-07-06
- **Grill level**: 1 (standard)
- **Plans**:
  - `docs/plans/recorder-automation-recording-library.plan.md` (Mode B, created 2026-07-07)

## Feature Summary

Upgrades the Recording Management page from an unbounded in-memory list into a **library** that stays fast at 1,000+ recordings: database-side filtering/sorting with **cursor pagination**, a filter bar (category / source / status / starred / date range), extended batch operations (star, reclassify, re-export, delete), and removal of the page's O(n) hotspots. Also lands the **citation-focus hook** the Ask AI feature (see `docs/srs/ask-ai-semantic-qa.srs.md`) needs to jump to a specific recording.

## Delta from Current Module State

> Verified current state (`Views/History/RecorderHistoryView.swift`): unbounded `@Query` over all imported rows (`:10-12`, no `fetchLimit`); ALL filtering in-memory over the full array (`filteredItems` `:37-52`); fixed sort (timestamp desc only); full `ImportLedgerEntry` table fetched on every count change for filenames (`loadFileNames()` `:174-180`); good news — rich row actions (apply/export/delete-audio/delete-record/rename/star `:433-484`), shift-click multi-select (`:156-167`), and batch delete (`:169-172`) already exist. The app already owns the right pagination pattern: cursor `FetchDescriptor` + `fetchLimit` + Load More in `InlineHistoryView.swift:22,34-59,345-377` / `TranscriptionHistoryView.swift:21,33-59,395-434`, and id-only select-all via `propertiesToFetch = [\.id]` (`TranscriptionHistoryView.swift:460-487`).

### New / Changed API Endpoints

N/A — UI + query-layer change only.

### New / Changed Data Models

- **CHANGED** `Transcription` — add `#Index` entries: `[\.recorderCategoryId]`, `[\.recorderFavorite]`, `[\.recorderSourceDeviceId]` (today only `[\.timestamp]`, `[\.importFingerprint]` exist — `Models/Transcription.swift:15`). Index-only change, lightweight migration.
- **No new entities.** (`recorderSourceLabel` arrives via the meeting-capture SRS and is displayed/filterable here.)

### Changed Business Logic

- **Fetch layer**: replace the unbounded `@Query` with the existing cursor-pagination pattern — `FetchDescriptor` with compiled `#Predicate` (all active filters + free-text `localizedStandardContains` over `text`/`enhancedText`/`recorderTitle`/`recorderCategoryName`), `sortBy` from the sort control, `fetchLimit = pageSize (50)`; `fetchCount` for the result summary. In-memory filtering limited to nothing — every filter is predicate-side.
- **Filter bar**: category (existing store list), source (recorder devices + 會議 label + manual), status (`transcriptionStatus`), starred, date range presets (今天/7 天/30 天/自訂). Persisted as page state.
- **Sort control**: timestamp ↓↑ (indexed), duration ↓↑, title A-Z.
- **Batch operations**: extend the existing selection bar with batch star/unstar, batch reclassify (category picker → reuse `RecorderPostProcessor.reclassify` per item, sequential with progress + cancel), batch re-export (`export` path), existing batch delete stays. Select-all-matching uses the id-only fetch pattern (works across pages).
- **Filename lookup**: replace the full-ledger `loadFileNames()` prefetch with a page-scoped fetch (`fingerprint IN pageFingerprints`, leveraging the existing `[\.fingerprint]` index on `ImportLedgerEntry`).
- **Citation-focus hook**: page accepts a `focusTranscriptionId: UUID?` (via `AppNavigator` companion `@Published pendingFocusTranscriptionId` — net-new, section-level nav exists but no row-level focus anywhere today, `Services/AppNavigator.swift:13-25`): pages-in the row if needed (cursor from its timestamp), scrolls to it, opens its detail.

### Explicitly Out of Scope

- New organization dimensions (folders/custom tags) — categories + star + filters cover v1 (PRD open question); editing transcripts; virtualized custom table (LazyVStack + pagination suffices at target scale); changes to the dictation history pages.

## Functional Requirements

- [ ] **FR-1** Initial render fetches exactly one page (50) regardless of library size; scrolling/Load More appends pages; no code path fetches all rows for display.
- [ ] **FR-2** All filters combine (AND) and execute as a store predicate; result count shown ("符合 137 筆").
- [ ] **FR-3** Free-text search debounced (existing 250 ms pattern) and predicate-side.
- [ ] **FR-4** Sort control re-queries from page one; selection survives filter/sort changes only for still-visible rows (cleared otherwise, with a hint).
- [ ] **FR-5** Batch star / reclassify / re-export / delete over the selection, sequential with progress and cancel; failures reported per-item without aborting the rest.
- [ ] **FR-6** 「全選符合條件」selects all matching ids without materializing full rows.
- [ ] **FR-7** Page-scoped filename/byte-size lookup (no full-ledger fetch).
- [ ] **FR-8** `focusTranscriptionId` navigation: from anywhere (Ask AI citation), the page opens with that row paged-in, highlighted, detail opened.
- [ ] **FR-9** All existing single-row actions and the TranscriptSheet remain functional unchanged.

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| Responsiveness | Filter/sort change → first page rendered <100 ms at 2,000 rows | Predicate + indexes + fetchLimit |
| Memory | Only current pages materialized (≤ a few hundred rows) | Cursor pagination |
| Correctness | Batch ops exactly-once per selected id, resumable UI | Sequential runner with progress state |
| Compatibility | Zero behavior change for existing single-row flows | Card component untouched where possible |

## Architecture Notes

- This SRS deliberately mirrors `InlineHistoryView`'s proven pattern rather than inventing a table stack — consistency over novelty at this scale.
- SwiftData `#Predicate` has real limits (optional chaining, computed properties are off-limits) — filters must target stored scalar fields only (`recorderCategoryId`, `recorderFavorite`, `transcriptionStatus`, `timestamp`, `recorderSourceDeviceId`); anything derived stays out of predicates. Verify optional-UUID equality compiles early (known Open Question).
- The focus hook is the one piece shared with the `ask-ai` module — land it here so citations have a target; Ask AI's v1 fallback (detail sheet in place) works even before this ships.

## Acceptance Criteria

### AC-1: 千筆量級初載
- **Given**: a store seeded with 2,000 recorder transcriptions (in-memory container, existing test pattern)
- **When**: the page loads
- **Then**: exactly one page of rows is fetched (assert displayed count == pageSize) and render completes without fetching all rows
- **Test**: `RecordingLibraryQueryTests::initialLoadFetchesOnePage`

### AC-2: 組合篩選正確性
- **Given**: seeded rows across categories/starred/dates
- **When**: filtering 分類=會議 AND 星標 AND 最近 7 天
- **Then**: results exactly match the seeded expectation; count label correct
- **Test**: `RecordingLibraryQueryTests::combinedPredicateMatches`

### AC-3: 批次操作
- **Given**: 100 selected rows
- **When**: batch star, then batch reclassify to 通用
- **Then**: all 100 rows updated and persisted; progress shown; a mid-run cancel stops cleanly with completed items kept
- **Test**: `RecordingLibraryBatchTests::batchStarAndReclassify` + manual

### AC-4: 全選符合條件
- **Given**: a filter matching 700 rows
- **When**: 全選符合條件 → batch star
- **Then**: all 700 starred (id-only selection path)
- **Test**: unit on the id-fetch seam

### AC-5: 引用聚焦
- **Given**: a transcription NOT on the first page
- **When**: navigation arrives with its `focusTranscriptionId`
- **Then**: the page opens, pages-in, scrolls to, highlights, and opens the detail of that row
- **Test**: manual + unit on cursor-from-timestamp seam

## Open Questions

- [ ] SwiftData `#Predicate` support for optional-UUID equality (`recorderCategoryId == x`) — verify at plan time; fallback = filter on `recorderCategoryName` (String).
- [ ] Page size 50 vs 20 (history uses 20; cards are heavier than history rows) — pick after a feel test.
- [ ] Should 會議/manual/裝置 "source" filter read `recorderSourceDeviceId` + `recorderSourceLabel` or a dedicated enum field — decide with meeting-capture implementation.
