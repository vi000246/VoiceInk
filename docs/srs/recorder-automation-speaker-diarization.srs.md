---
linear_issue: null
---
# SRS: Universal Speaker Diarization

## Metadata
- **Module**: `recorder-automation`
- **Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source PRD**: N/A (free-form feature request)
- **Source Linear Issue**: N/A
- **Created**: 2026-07-01
- **Grill level**: 1 (standard)
- **Supersedes**: `recorder-automation` M5 / FR-15 (previously "prompt-based speaker inference v1 + FluidAudio-only M5")
- **Plans**: `docs/plans/recorder-automation-speaker-diarization-m1.plan.md` (M1 — native ElevenLabs vertical slice; FluidAudio fallback / AC-4 deferred to M2)

## Feature Summary

Adds **universal speaker diarization** to recorder-imported meeting transcripts: every transcript
can be split into per-speaker segments ("講者1 / 講者2 …") so the user can tell who said what in a
meeting. Coverage is **provider-agnostic** via a hybrid strategy — models that support diarization
natively (ElevenLabs Scribe, Deepgram, AssemblyAI, Speechmatics, Soniox) use their native
`diarize` API; models that don't (local Whisper, Native Apple, Groq/Mistral/xAI Whisper) get a
**FluidAudio local diarization pass** aligned to the transcript. Speakers are labelled anonymously
and can be **manually renamed** (e.g. 講者1 → "Logan"), with the rename applied across the whole
transcript. v1 scope is **file-based recorder imports**; real-time streaming diarization is out of
scope.

## Delta from Current Module State

> Refer to `docs/spec/recorder-automation.spec.md` for existing architecture. This section
> describes ONLY what changes. This feature **replaces** the module's previous diarization plan
> (M5 / FR-15), which was FluidAudio-only and gated behind prompt-based inference.

### New / Changed API Endpoints

N/A — VoiceInk is a local macOS app with no HTTP API. The one **external** contract touched is the
ElevenLabs Speech-to-Text HTTP API (`POST https://api.elevenlabs.io/v1/speech-to-text`), which
must now be called with diarization parameters. Because `ElevenLabsClient` lives in the **remote,
non-editable** `LLMkit` package (`github.com/Beingpax/LLMkit.git`), a diarization-capable client is
added **inside the VoiceInk repo** rather than modifying LLMkit.

### New / Changed Data Models

- **NEW** `SpeakerSegment` (Codable value type): `{ speaker: String, text: String, start:
  TimeInterval, end: TimeInterval }`. `speaker` is a stable id ("1", "2", …) or a native
  provider label; display name is resolved separately (see rename map).
- **CHANGED** `Transcription` (`Models/Transcription.swift:12`) — add optional fields:
  - `speakerSegmentsRaw: String?` — JSON-encoded `[SpeakerSegment]` (nil = not diarized).
  - `speakerNamesRaw: String?` — JSON-encoded `[speakerId: customName]` rename map (nil = all anonymous).
  - **REUSE** existing `speakerLabeled: Bool` (`Models/Transcription.swift:41`) — set `true` when
    segments are present. Computed accessors (`speakerSegments`, `speakerNames`, and a
    display-name resolver) parse/serialize these raw fields, mirroring the existing
    `audioChunkURLs` / `audioChunkPathsRaw` pattern (`Models/Transcription.swift:43-50`).
  - All new fields optional with defaults → safe SwiftData lightweight migration; existing rows
    and non-diarized transcripts are unaffected.
- **CHANGED** recorder config (`RecorderConfigStore`) — add diarization settings to Recorder Mode:
  `diarizationEnabled: Bool` (default off) and optional `expectedSpeakerCount: Int?`.

### Changed Business Logic

- **New provider-agnostic stage** `DiarizationCoordinator`, invoked by the recorder pipeline after
  raw transcription (`RecorderPostProcessor.process`, `Services/RecorderAutomation/RecorderPostProcessor.swift:78`):
  1. If diarization is disabled → no-op (today's behavior).
  2. If the selected transcription model **supports native diarization** → the transcription call
     itself returns speaker-labelled segments (single API call, best quality).
  3. Otherwise → run `FluidAudioDiarizer` on the audio to get a speaker **timeline**
     `[(speaker, start, end)]`, then **align** it with the transcript's word/segment timestamps
     to produce `[SpeakerSegment]`.
- **New in-repo `ElevenLabsDiarizingClient`** — when diarization is on and the model is ElevenLabs,
  the recorder pipeline calls this client instead of the LLMkit path. It POSTs `diarize=true`
  (plus optional `num_speakers` / `diarization_threshold`), parses the `words[]` array's
  `speaker_id` + `start`/`end`, and groups consecutive same-speaker words into `SpeakerSegment`s.
  When diarization is off, the existing LLMkit `ElevenLabsProvider` path is unchanged.
- **Rename application** — a display resolver maps each segment's `speaker` id through
  `speakerNames` before rendering; renaming "講者1" writes the map and re-renders the whole
  transcript without re-transcribing.

### Explicitly Out of Scope

- **Real-time / streaming diarization** — the streaming path
  (`Transcription/Streaming/*`, `scribe_v2_realtime`) is untouched; diarization applies only to
  batch file transcription of recorder imports.
- **Cross-recording speaker identity** — v1 speaker ids are **per-transcript**; "講者1" in file A
  is unrelated to "講者1" in file B. Persistent voiceprint enrollment (naming a recurring speaker
  once and auto-matching thereafter) is a future milestone, not v1.
- **Manual-drop / active-Voice-Mode transcripts** — diarization is wired into the recorder
  pipeline only; the general dictation path is unchanged.
- **Per-word confidence / editing of segment boundaries** — v1 renders read-only segments;
  no timeline editor.

## Functional Requirements

- [ ] **FR-1** Add a Recorder Mode setting `啟用語者辨識` (`diarizationEnabled`, default **off**)
  and an optional `預期人數` (`expectedSpeakerCount`), persisted via `RecorderConfigStore`.
- [ ] **FR-2** Introduce `SpeakerSegment` and a `DiarizationCoordinator` that decides, per model,
  whether to use native diarization or the FluidAudio fallback.
- [ ] **FR-3** Provide a capability signal per transcription model — `supportsNativeDiarization`
  — so the coordinator can route. Native-capable providers in v1: ElevenLabs (implemented first);
  design must allow Deepgram / AssemblyAI / Speechmatics / Soniox to opt in later without changing
  the coordinator.
- [ ] **FR-4** Implement `ElevenLabsDiarizingClient` (in-repo, bypassing LLMkit) that sends
  `diarize=true` (+ `num_speakers`/`diarization_threshold` when `expectedSpeakerCount` is set),
  parses `words[].speaker_id`/`start`/`end`, and merges consecutive same-speaker words into
  `[SpeakerSegment]` while also returning the joined full `text`.
- [ ] **FR-5** Implement `FluidAudioDiarizer` wrapping FluidAudio's diarizer
  (`OfflineDiarizerManager` / `DiarizerManager`) to produce a speaker timeline for any audio file,
  honoring `expectedSpeakerCount` when provided.
- [ ] **FR-6** Implement timestamp **alignment**: given a speaker timeline and a transcript that
  carries segment/word timestamps (local Whisper via `whisper_full_n_segments`), assign each
  transcript segment to the speaker whose timeline range has the greatest temporal overlap.
- [ ] **FR-7** Persist results: on success set `speakerLabeled = true` and store
  `speakerSegmentsRaw`; leave `speakerNamesRaw` nil (all anonymous) until the user renames.
- [ ] **FR-8** Render the transcript grouped by speaker (`講者1: …` / `講者2: …`) in the Recording
  Management detail view, resolving display names through the rename map.
- [ ] **FR-9** Allow the user to rename a speaker (e.g. 講者1 → "Logan"); persist to
  `speakerNamesRaw` and re-render all segments for that speaker across the transcript.
- [ ] **FR-10** Degrade gracefully: if diarization fails or the model provides no usable
  timestamps for alignment (e.g. Native Apple / flat-text cloud Whisper), keep the plain
  transcript, set `speakerLabeled = false`, and surface a non-blocking notice — never lose the
  transcript.

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| Universality (coverage) | Every recorder transcription model yields either native or fallback speaker labels, OR degrades cleanly with a stated reason | Hybrid coordinator + capability flag; FR-10 fallback contract |
| Privacy | Local models never send audio off-device for diarization | FluidAudio runs fully on-device; native diarize only for models already sending audio to that cloud |
| Reliability | Diarization failure never corrupts or drops the transcript | Diarization is a post-transcription, best-effort stage; raw text persisted first (FR-10) |
| Cost | Native diarization adds **no extra API call** (same request as transcription) | ElevenLabs `diarize=true` is a parameter on the existing STT call |
| Backward compatibility | Existing transcripts and non-diarized flows unaffected | All new fields optional; `speakerLabeled` already exists; default off |
| Observability | Every diarization decision (native vs fallback vs skipped) is traceable | `os.Logger` category `RecorderAutomation`, sub-scope `Diarization` |

## Architecture Notes

- **Hybrid, native-first** (user decision): native diarization is preferred where available because
  it is word-accurate and free (rides the transcription call); FluidAudio is the universal
  fallback so local/offline models still get speaker labels. See Module Spec *Decisions Log*.
- **LLMkit is remote and non-editable** → the ElevenLabs diarization client is added inside the
  VoiceInk repo (`Transcription/Cloud/`), calling the ElevenLabs HTTP API directly. The existing
  LLMkit `ElevenLabsClient` path remains for the diarization-off case.
- **FluidAudio needs no new dependency** — the `Diarizer` module
  (`Sources/FluidAudio/Diarizer/`: `DiarizerManager`, `OfflineDiarizerManager`, `SpeakerManager`)
  is already vendored alongside the Parakeet ASR used by
  `Transcription/FluidAudio/FluidAudioTranscriptionService.swift`. Its speaker-enrollment
  capability is intentionally deferred (see Out of Scope) to keep v1 per-transcript.
- **Alignment is the hard part of the fallback** — it needs transcript timestamps. Local Whisper
  exposes per-segment `start`/`end` (`Transcription/Whisper/LibWhisper.swift:24`); models that
  return only flat text cannot be aligned and hit the FR-10 degrade path in v1.
- **Anonymous + rename** (user decision): segments carry stable ids; a separate rename map keeps
  renaming a pure presentation concern (no re-transcription), and leaves room for future
  enrollment-based auto-naming.

## Acceptance Criteria

### AC-1: Diarization is off by default and inert
- **Given**: a fresh Recorder Mode with `diarizationEnabled = false`
- **When**: a recorder file is imported and transcribed
- **Then**: the transcript is produced exactly as today, `speakerLabeled = false`,
  `speakerSegmentsRaw = nil`, and no diarization work runs
- **Test**: `VoiceInkTests/DiarizationCoordinatorTests::skipsWhenDisabled`

### AC-2: ElevenLabs native diarization produces per-speaker segments
- **Given**: `diarizationEnabled = true`, the Recorder Mode model is ElevenLabs `scribe_v2`, and a
  two-speaker meeting file
- **When**: the recorder pipeline transcribes it
- **Then**: `ElevenLabsDiarizingClient` sent `diarize=true`, and the stored `speakerSegments`
  contain ≥2 distinct `speaker` ids with contiguous same-speaker words merged into segments whose
  `start`/`end` come from the API `words[]`
- **Test**: `VoiceInkTests/ElevenLabsDiarizingClientTests::mergesWordsIntoSpeakerSegments`

### AC-3: `expectedSpeakerCount` is forwarded
- **Given**: `diarizationEnabled = true` and `expectedSpeakerCount = 3`
- **When**: an ElevenLabs diarizing request is built
- **Then**: the request includes `num_speakers = 3` (and does not also send a conflicting
  `diarization_threshold`)
- **Test**: `VoiceInkTests/ElevenLabsDiarizingClientTests::forwardsExpectedSpeakerCount`

### AC-4: Local Whisper gets FluidAudio fallback aligned to segments
- **Given**: `diarizationEnabled = true`, the model is a local Whisper model (no native
  diarization), and a two-speaker file whose Whisper output has per-segment timestamps
- **When**: the pipeline runs
- **Then**: `FluidAudioDiarizer` produces a speaker timeline, each Whisper segment is assigned to
  the max-overlap speaker, and `speakerSegments` reflect ≥2 speakers; `speakerLabeled = true`
- **Test**: `VoiceInkTests/DiarizationAlignmentTests::assignsSegmentsByMaxOverlap`

### AC-5: Anonymous labels render, then rename applies transcript-wide
- **Given**: a diarized transcript with speakers "1" and "2" and no rename map
- **When**: the detail view renders, then the user renames "講者1" to "Logan"
- **Then**: before rename it shows "講者1 / 講者2"; after rename every segment previously shown as
  "講者1" shows "Logan", `speakerNamesRaw` persists `{"1":"Logan"}`, and no re-transcription occurred
- **Test**: `VoiceInkTests/SpeakerRenameTests::appliesNameAcrossAllSegments`

### AC-6: Failure degrades without losing the transcript
- **Given**: `diarizationEnabled = true` but diarization fails (native API error, or a
  flat-text model with no alignable timestamps)
- **When**: the pipeline runs
- **Then**: the plain transcript is still persisted and shown, `speakerLabeled = false`,
  `speakerSegmentsRaw = nil`, and a non-blocking notice explains diarization was skipped
- **Test**: `VoiceInkTests/DiarizationCoordinatorTests::degradesToPlainTranscriptOnFailure`

## Open Questions

- [ ] FluidAudio diarizer models: download size, first-run download UX, and whether to gate
  fallback behind an explicit "download diarization model" step (mirror existing model-download UX).
- [ ] Alignment granularity for the fallback — segment-level (available from Whisper) vs word-level
  (would need word timestamps VoiceInk doesn't currently extract). v1 targets segment-level.
- [ ] `diarization_threshold` default vs `num_speakers`: when the user leaves `expectedSpeakerCount`
  empty, rely on ElevenLabs' model default (~0.22) or expose the threshold in advanced settings?
- [ ] Which native providers to enable beyond ElevenLabs in v1 (Deepgram / AssemblyAI already
  return diarization cheaply) vs deferring to a follow-up.
- [ ] Rendering: inline speaker prefixes vs a grouped/threaded layout in Recording Management, and
  how the raw-transcript Markdown export represents speakers.
