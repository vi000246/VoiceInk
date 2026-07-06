---
linear_issue: null
---
# SRS: Meeting Capture (免 bot 會議錄製 → Recorder 管線)

## Metadata
- **Module**: `recorder-automation`
- **Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source PRD**: `docs/prd/meeting-capture-to-obsidian.prd.md`
- **Source Linear Issue**: N/A
- **Created**: 2026-07-06
- **Grill level**: 1 (standard)
- **Plans**:
  - `docs/plans/recorder-automation-meeting-capture.plan.md` (Mode B, created 2026-07-07)

## Feature Summary

One-hotkey recording of an online meeting: system audio (remote participants, via a **CoreAudio process tap**) mixed with the microphone (the user) into a single audio file, which is then fed through the **existing** recorder import pipeline (ledger → ElevenLabs scribe_v2 whole-file transcription+diarization → 繁中 → category template → Obsidian export), with an optional **fixed 「會議」 category** that skips the classifier.

## Delta from Current Module State

> Refer to `docs/spec/recorder-automation.spec.md` for existing architecture (esp. **Key Decisions / 踩雷筆記** — whole-file ElevenLabs, provider-aware chunking; this feature must not reintroduce chunking). This section describes ONLY what changes.

### New / Changed API Endpoints

N/A — local app, no HTTP API. External contracts unchanged (ElevenLabs path untouched). New OS contract: **CoreAudio process tap** (`CATapDescription` + `AudioHardwareCreateProcessTap` + private aggregate device), macOS 14.2+.

### New Components

| Component | Responsibility | Interface |
|---|---|---|
| `MeetingCaptureService` | Own the capture graph: system-wide tap (`CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, exclude own process) + selected mic as the ONLY two sub-devices of a private aggregate device; raw HAL `AudioDeviceCreateIOProcIDWithBlock` (⚠️ NOT `AVAudioEngine` — it silently ignores tap-backed aggregates); mix to mono; write one audio file to a staging dir; teardown+rebuild BOTH tap and aggregate on default-output-device change | `@MainActor` singleton: `start() async throws`, `stop() async -> URL?`, `@Published state: MeetingCaptureState` (idle/recording(start: Date)/failed) |
| `MeetingIndicatorWindowManager` + `MeetingIndicatorView` | Lightweight floating indicator (red dot + elapsed timer + stop button), decoupled from the dictation `RecordingState` machine | Mirrors `MiniWindowManager` (`Views/Recorder/MiniWindowManager.swift`) `show()/hide()` |
| `ShortcutAction.toggleMeetingRecording` | Global hotkey start/stop | New enum case + `storageName`/`displayName` + `globalUtilityActions` entry (`Shortcuts/ShortcutAction.swift:3,29,56,91`) + switch arm in `RecordingShortcutManager.handleGlobalShortcut` (`Shortcuts/RecordingShortcutManager.swift:314`); ⚠️ must be handleable regardless of dictation `RecordingState` gating (`canHandleShortcutAction`, `:92`) |
| Menu bar item | Start/stop with dynamic title + elapsed time | New `Button` in `MenuBarView.swift` `completedOnboardingMenu` (`:43`), label driven by `MeetingCaptureService.state` |

### New / Changed Data Models

- **CHANGED** `RecorderConfigStore` (per-field pattern, `Services/RecorderAutomation/RecorderConfigStore.swift:33-91,95,178-211`):
  - `meetingFixedCategoryId: UUID?` — key `recorderMeetingFixedCategoryIdV1`; default = the seeded 「會議」 category id if present, else nil (nil ⇒ auto-classify).
  - `meetingMicEnabled: Bool` — key `recorderMeetingMicEnabledV1`, default `true` (off ⇒ system-audio-only capture).
- **CHANGED** `QueueItemOrigin` (`Models/AudioFileQueueItem.swift:26-29`): new case `.meetingCapture(fingerprint: String)` (no deviceId — meetings are not a `RecorderDevice`).
- **CHANGED** `Transcription` — additive optional `recorderSourceLabel: String?` (e.g. `"會議 · Zoom"`); lightweight migration, mirrors existing optional-field precedent (`Models/Transcription.swift:37-47`).
- **CHANGED** `Info.plist` — add `NSAudioCaptureUsageDescription` (confirmed absent today; TCC bucket `SystemAudioCaptureRequests`, separate from Screen Recording's periodic re-consent nag).

### Changed Business Logic

- `RecorderImportService` — new entry `importMeetingFile(url: URL, appName: String?) async`: fingerprint (existing streaming SHA-256) → ledger dedup → copy into `RecorderImports/` staging (`copyIntoAppStorage`, `RecorderImportService.swift:368`) → `addToQueue(urls:origin: .meetingCapture(fingerprint:))` + `startProcessing(mode: RecorderTranscriptionConfig.current())` (mirrors `:128-135`). Deletes the staging original from the meeting staging dir after success (internal file, not user data).
- `AudioFileTranscriptionManager.swift:286-293` — `.meetingCapture` branch calls the post-processor like `.recorderImport` but passes the fixed category.
- `RecorderPostProcessor.process(...)` (`RecorderPostProcessor.swift:83`) — new optional `fixedCategory: RecorderCategory?`; when set, **skip `suggestCategory`** (`:128,164-192`) and jump to `applyTemplate` (`:210`) + export with that category. Classifier untouched for all other paths.
- Capture format: mix to **mono 48 kHz AAC (.m4a)** via `ExtAudioFile` (~45 MB/h; a 3 h meeting ≈ 135 MB ≪ ElevenLabs 2 GB `maxUploadBytes` ⇒ never chunks, per Key Decision #2). Tap and mic stream formats differ → convert at the IOProc boundary (client-format conversion), sum with unity gain.

### Explicitly Out of Scope

- Live transcript / realtime HUD; auto-start on meeting detection (only a **reminder notification** is Should); calendar or meeting-platform integration; stereo my-side/their-side separation; own echo cancellation (headphones recommended in UI copy); capturing when TCC denied (degrade with guidance, never silently record nothing).

## Functional Requirements

- [ ] **FR-1** Start/stop via menu bar button AND global shortcut; both reflect current state (title + elapsed time).
- [ ] **FR-2** While recording: floating indicator with red dot + elapsed timer + stop button; indicator never blocks clicks elsewhere (non-activating panel, mirrors mini recorder).
- [ ] **FR-3** Capture = system-audio tap + mic (if `meetingMicEnabled`) mixed to one mono m4a in a staging dir; file is finalized (playable) on stop, on app quit, and on capture failure — a partial recording is never lost.
- [ ] **FR-4** First start triggers the `NSAudioCaptureUsageDescription` TCC prompt; if denied, show an error toast with a deep-link/guidance to System Settings (no zombie "recording" state). Detection heuristic: probe tap creation (no status API exists).
- [ ] **FR-5** On stop, the file auto-enters the recorder pipeline; with `meetingFixedCategoryId` set the classifier is **not called** and the category is applied directly; with nil it auto-classifies as today.
- [ ] **FR-6** Default-output-device change mid-recording (e.g. AirPods connect): teardown + rebuild tap AND aggregate; if rebuild fails, finalize the file, notify, and stop cleanly (no indefinite all-zero-buffer recording).
- [ ] **FR-7** Settings section (inside 錄音設定 page): fixed-category picker (default 會議), mic on/off toggle, shortcut recorder link.
- [ ] **FR-8** (Should) When a known meeting app (Zoom/Teams/Meet in browser via existing `BrowserURLService`/`ActiveWindowService`) is frontmost and mic is in use and no meeting recording is active → one reminder notification per meeting-app session.
- [ ] **FR-9** Resulting `Transcription` carries `recorderSourceLabel` ("會議 · <app>") shown in Recording Management; Obsidian note frontmatter includes the label.

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| Reliability | 0 lost recordings across stop/quit/failure paths | Finalize-on-any-exit; staging file flushed incrementally (`ExtAudioFile` writes per IOProc cycle) |
| Overhead | No audible dropouts; CPU addition small enough to not affect the meeting (measure; no verified public benchmark exists) | Raw HAL IOProc, no per-buffer allocation; profile in AC-6 |
| Permission UX | Exactly one TCC prompt; denial handled with guidance | Probe-based detection (AudioCap pattern); Info.plist string |
| Storage | ≤ ~50 MB/h | Mono 48 kHz AAC ~96 kbps |

## Architecture Notes

- **Respects module Key Decisions**: whole-file ElevenLabs transcription+diarization (meetings are the diarization headline case — up to 48 speakers, consistent ids); no chunking (AAC keeps files far below the 2 GB gate).
- **Separate indicator window, NOT a new `RecordingState` case** — the dictation state machine gates 6+ sites in `VoiceInkEngine` + shortcut handling; meeting capture is an independent long-running session and must not block dictation shortcuts. (Dictating *during* a meeting recording is allowed and expected.)
- **Signing caveat**: TCC prompt only fires for properly signed builds — `make deploy` (stable-signed) is the test target, not ad-hoc builds.
- Reference implementation for the tap+aggregate flow: `insidegui/AudioCap` (see research log in module spec Decisions).

## Acceptance Criteria

### AC-1: 一鍵錄會議出筆記（happy path）
- **Given**: ElevenLabs key configured, 「會議」 category exists and is set as fixed category, TCC granted
- **When**: user starts recording, a meeting app plays remote speech while the user speaks, user stops after ≥2 min
- **Then**: exactly one new Transcription appears with BOTH sides' content in the transcript, diarized speaker segments, `recorderCategoryName == "會議"`, `recorderSourceLabel` set, and an exported note in the 會議 vault subfolder — with **zero** classifier API calls (verifiable in request log/os_log)
- **Test**: manual (Linear checklist) + unit for fixed-category routing: `RecorderPostProcessorTests::fixedCategorySkipsClassifier`

### AC-2: TCC 拒絕
- **Given**: system-audio permission denied
- **When**: user starts recording
- **Then**: error notification with guidance appears ≤3 s; state returns to idle; no file is enqueued
- **Test**: manual (tccutil reset SystemAudioCaptureRequests)

### AC-3: 裝置切換韌性
- **Given**: an active meeting recording through built-in speakers
- **When**: AirPods connect mid-recording
- **Then**: recording continues (rebuilt graph) or finalizes with a notification — the saved file contains audio up to the switch at minimum; no silent multi-minute zero-filled tail
- **Test**: manual (Linear checklist)

### AC-4: 停止即入管線
- **Given**: recording stopped
- **When**: pipeline completes
- **Then**: same end state as a recorder-device import (history row, retention rules, orphan-sweep compatibility — staging file reclaimed)
- **Test**: `RecorderImportServiceTests::meetingImportEnqueuesWithMeetingOrigin` (pure seam)

### AC-5: 快捷鍵/選單列一致
- **Given**: idle
- **When**: toggling via shortcut, then via menu bar
- **Then**: both toggle the same state; indicator + menu title agree; works while a dictation recording is active
- **Test**: manual + unit on shortcut action registration

### AC-6: 純系統音訊模式
- **Given**: `meetingMicEnabled = false`
- **When**: recording a meeting
- **Then**: file contains system audio only (mic muted in mix)
- **Test**: manual

## Open Questions

- [ ] Mono mixdown vs keeping tap stereo → mono only at mix: any measurable ElevenLabs diarization difference? (decide during implementation with one real meeting)
- [ ] Post-grant relaunch: some reports say the tap only works after app restart following TCC grant — verify on macOS 26; if true, FR-4 guidance must say 重啟 app.
- [ ] Echo acceptability when user is on speakers (mic re-captures remote audio) — if bad, add UI hint recommending headphones; own AEC is out of scope.
- [ ] Elapsed-timer in the menu bar title vs only in the indicator (menu re-render cadence).
- [ ] Meeting-app detection list for FR-8 (Zoom/Teams native + meet.google.com via `BrowserURLService`) — finalize at plan time.
