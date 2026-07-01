---
linear_issue: null
---
# Plan: Speaker Diarization — M2 (FluidAudio local fallback + alignment)

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type` (feature → `implementing-features`). Mode B — each task writes a failing test first, then the minimal implementation, then commits. Builds/tests go through the `voiceink-build-verify` skill.

## Summary
Complete "universal" speaker diarization: models that don't natively diarize (local Whisper, Native Apple, Groq/Mistral/xAI Whisper, Parakeet) now get speaker labels via an **on-device FluidAudio pass**. When diarization is enabled and the transcription model is non-native, the `DiarizationCoordinator` falls back to a new `FluidAudioDiarizer` that runs FluidAudio Parakeet ASR (token timings) + the FluidAudio diarizer (speaker timeline), then **aligns tokens to speaker time-ranges by overlap** → `[SpeakerSegment]`. Fully local, no API cost, no changes to the shared transcription pipeline. This is SRS **AC-4**.

## User Story
As someone who transcribes meetings with a local/offline model (privacy, no API key),
I want speaker labels on those transcripts too,
So that "who said what" works regardless of which transcription model I chose.

## Problem → Solution
M1 only labels speakers for ElevenLabs (native). Local/Apple/other models fall through to a plain transcript → a local FluidAudio diarization pass fills speaker segments for any non-native model, aligned to FluidAudio's own token timestamps, entirely on-device.

## Metadata
- **Module**: recorder-automation
- **Parent Plan**: `docs/plans/completed/recorder-automation-speaker-diarization-m1.plan.md`
- **Source PRD**: N/A
- **Source Feature SRS**: `docs/srs/recorder-automation-speaker-diarization.srs.md`
- **Source Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source Linear Issue**: N/A
- **Type**: feature
- **Size**: L
- **Complexity**: Large
- **Rigor**: balanced
- **Mode**: B — 任務先測
- **TDD**: on
- **Commit cadence**: per-task (may consolidate at user request)
- **Estimated Files**: ~5 (3 create / 2 update)

---

## UX Design

### Before (post-M1)
```
Recorder Mode 語者辨識 = ON, model = 本地 Whisper / Parakeet / Apple
→ 逐字稿 sheet: 一整塊純文字 + info 通知「此轉錄模型尚不支援語者辨識」
```
### After (M2)
```
Recorder Mode 語者辨識 = ON, model = 本地 Whisper / Parakeet / Apple
→ 第一次: 下載語者模型通知; 之後每筆匯入本地跑一次 diarization
→ 逐字稿 sheet: 講者1 / 講者2 分段（同 M1 UI，含改名）
   （語者分段文字來自 FluidAudio 本地辨識；上方純文字仍是你所選模型的輸出）
```

### Interaction Changes
| Touchpoint | Before (M1) | After (M2) | Notes |
|---|---|---|---|
| Non-native model + diarization on | info notice, plain transcript | local FluidAudio diarization → speaker blocks | AC-4 |
| First diarization run | — | one-time model download notice | diarizer models auto-download |
| 逐字稿 sheet | M1 speaker UI only for ElevenLabs | same speaker UI for any model | unchanged UI (M1 Task 10) |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/recorder-automation-speaker-diarization.srs.md` | FR-5,6 / AC-4 | The requirement this plan fulfils |
| P0 | `VoiceInk/Services/RecorderAutomation/DiarizationCoordinator.swift` | 25-52 | Add the `else { fallback }` branch after the native guard |
| P0 | `VoiceInk/Models/SpeakerSegment.swift` | 1-45 | Output type + `merge`; alignment reuses `SpeakerSegment` |
| P0 | `VoiceInk/Transcription/FluidAudio/FluidAudioTranscriptionService.swift` | 50,82,131-197,232 | MIRROR: AsrManager creation, model load dedup, `transcribe`→`ASRResult`, audio decode |
| P1 | `VoiceInk/Transcription/FluidAudio/FluidAudioModelManager.swift` | 377 | Models cache dir pattern (`fluidAudioModelsRootDirectory`) |
| P1 | `VoiceInk/Transcription/Engine/AudioFileProcessor.swift` | 37 | `processAudioToSamples(_:) -> [Float]` (16kHz) to feed the diarizer |
| P1 | `.local-build/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift` | 15,19,29,94,112 | `init`, `initialize`, `prepareModels`, `process(audio:)`, `process(_ url:)` |
| P1 | `.local-build/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerModels.swift` | 78 | `OfflineDiarizerModels.load(...)` (auto-download) |
| P1 | `.local-build/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift` | 134-162 | `TimedSpeakerSegment {speakerId, startTimeSeconds, endTimeSeconds}` + `DiarizationResult.segments` |
| P1 | `.local-build/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/AsrTypes.swift` | 89-147 | `ASRResult.tokenTimings: [TokenTiming]?`; `TokenTiming {token,startTime,endTime}` |
| P2 | `VoiceInkTests/RecorderDiarizationTests.swift` | all | Pure-seam XCTest style (extend or add a sibling test file) |

## External Documentation
No external research needed — FluidAudio is an already-linked local dependency; ElevenLabs path is done in M1.

---

## Patterns to Mirror

### FLUIDAUDIO_ASR_MODEL_LOAD_AND_TRANSCRIBE
```swift
// SOURCE: VoiceInk/Transcription/FluidAudio/FluidAudioTranscriptionService.swift:50,191-197
let manager = AsrManager(config: .default)                 // create
// … load models (mirror getOrLoadModels dedup at :82) …
let result = try await asrManager.transcribe(samples, ...) // ASRResult
_ = result.text                                            // M2 also reads result.tokenTimings
```

### FLUIDAUDIO_AUDIO_DECODE
```swift
// SOURCE: VoiceInk/Transcription/Engine/AudioFileProcessor.swift:37
// (type may be `AudioProcessor` / `AudioFileProcessor` — verify at read time)
let samples: [Float] = try await AudioProcessor().processAudioToSamples(url)  // 16kHz mono
```

### DIARIZER_MODEL_LOAD_AND_PROCESS
```swift
// SOURCE: FluidAudio OfflineDiarizerManager.swift:15,29,94
let diarizer = OfflineDiarizerManager(config: .default)
try await diarizer.prepareModels()                         // auto-downloads if missing
let result: DiarizationResult = try await diarizer.process(audio: samples)
// result.segments: [TimedSpeakerSegment] → {speakerId, startTimeSeconds, endTimeSeconds}
```

### SPEAKER_SEGMENT_OUTPUT
```swift
// SOURCE: VoiceInk/Models/SpeakerSegment.swift:19-24
struct SpeakerSegment: Codable, Equatable {
    var speaker: String; var text: String; var start: TimeInterval; var end: TimeInterval
}
```

### COORDINATOR_NATIVE_GUARD (where the fallback branch goes)
```swift
// SOURCE: VoiceInk/Services/RecorderAutomation/DiarizationCoordinator.swift:27-28
guard supportsNativeDiarization(modelName: transcriptionModelName),
      let modelName = transcriptionModelName else { return nil }  // ← M2: replace `return nil` with fallback
```

### PURE_SEAM_TEST
```swift
// SOURCE: VoiceInkTests/RecorderDiarizationTests.swift:4,44-51
@MainActor final class …: XCTestCase {
    func testX() { XCTAssertEqual(Pure.fn(input), expected) }
}
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/RecorderAutomation/DiarizationAlignment.swift` | CREATE | Pure token↔timeline max-overlap alignment → `[SpeakerSegment]` |
| `VoiceInk/Services/RecorderAutomation/FluidAudioDiarizer.swift` | CREATE | Lazy-loads FluidAudio ASR + diarizer; runs both on the audio, returns aligned `[SpeakerSegment]` |
| `VoiceInk/Services/RecorderAutomation/DiarizationCoordinator.swift` | UPDATE | Add non-native → `FluidAudioDiarizer` fallback branch; keep graceful degrade |
| `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | UPDATE | Drop/relax the "not supported" notice now that fallback exists; add first-run download notice |
| `VoiceInkTests/RecorderDiarizationM2Tests.swift` | CREATE | Pure tests: alignment overlap, token cleaning, empty/degenerate inputs |

## NOT Building (deferred to M3)
- Native diarization for other cloud providers (Deepgram / AssemblyAI / Speechmatics / Soniox).
- Folding diarization into the main transcription call (still a dedicated pass).
- Speaker labels in the Obsidian Markdown export.
- Cross-recording speaker identity / voiceprint enrollment auto-naming.
- Reusing the app's already-loaded Parakeet `AsrManager` instance (M2 loads its own inside `FluidAudioDiarizer` for isolation; a shared instance is an optimization).

---

## Step-by-Step Tasks

### Task 1: Pure alignment — assign tokens to speaker time-ranges
**Files:**
- Create: `VoiceInk/Services/RecorderAutomation/DiarizationAlignment.swift`
- Test:   `VoiceInkTests/RecorderDiarizationM2Tests.swift`

- [ ] **Step 1: Write the failing test**
  ```swift
  import XCTest
  @testable import VoiceInk

  @MainActor
  final class RecorderDiarizationM2Tests: XCTestCase {
      typealias Tok = DiarizationAlignment.Token
      typealias Range = DiarizationAlignment.SpeakerRange

      func testAlignAssignsTokensToMaxOverlapSpeaker() {
          let tokens = [
              Tok(text: "今天", start: 0.0, end: 0.4),
              Tok(text: "開會", start: 0.5, end: 0.9),
              Tok(text: "好的", start: 1.1, end: 1.5),
          ]
          let timeline = [
              Range(speaker: "S1", start: 0.0, end: 1.0),
              Range(speaker: "S2", start: 1.0, end: 2.0),
          ]
          let segs = DiarizationAlignment.align(tokens: tokens, timeline: timeline)
          XCTAssertEqual(segs.count, 2)
          XCTAssertEqual(segs[0].speaker, "S1")
          XCTAssertEqual(segs[0].text, "今天開會")
          XCTAssertEqual(segs[0].start, 0.0, accuracy: 0.0001)
          XCTAssertEqual(segs[0].end, 1.0, accuracy: 0.0001)
          XCTAssertEqual(segs[1].speaker, "S2")
          XCTAssertEqual(segs[1].text, "好的")
      }

      func testAlignCleansParakeetWordMarkersAndSkipsEmpty() {
          let tokens = [
              Tok(text: "▁hello", start: 0.0, end: 0.3),
              Tok(text: "▁world", start: 0.3, end: 0.6),
          ]
          let timeline = [Range(speaker: "S1", start: 0.0, end: 1.0)]
          let segs = DiarizationAlignment.align(tokens: tokens, timeline: timeline)
          XCTAssertEqual(segs.count, 1)
          XCTAssertEqual(segs[0].text, "hello world")
      }

      func testAlignEmptyInputs() {
          XCTAssertTrue(DiarizationAlignment.align(tokens: [], timeline: []).isEmpty)
          let t = [Tok(text: "hi", start: 0, end: 1)]
          XCTAssertTrue(DiarizationAlignment.align(tokens: t, timeline: []).isEmpty)
      }
  }
  ```
  Run: expect FAIL (types don't exist).

- [ ] **Step 2: Run test** — Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**
  ```swift
  import Foundation

  /// Pure alignment of ASR token timings against a speaker timeline → speaker-labelled segments.
  /// Inputs are plain tuples (not FluidAudio types) so this stays unit-testable without models.
  enum DiarizationAlignment {
      struct Token: Equatable { let text: String; let start: TimeInterval; let end: TimeInterval }
      struct SpeakerRange: Equatable { let speaker: String; let start: TimeInterval; let end: TimeInterval }

      /// Assign each token to the timeline range with the greatest temporal overlap of the token's
      /// [start,end]; group contiguous same-speaker tokens (in timeline order) into segments.
      /// Parakeet word markers ("▁") become spaces; empty segments are dropped.
      static func align(tokens: [Token], timeline: [SpeakerRange]) -> [SpeakerSegment] {
          guard !timeline.isEmpty else { return [] }
          // token → assigned range index (max overlap; ties → earliest range)
          func overlap(_ t: Token, _ r: SpeakerRange) -> Double {
              max(0, min(t.end, r.end) - max(t.start, r.start))
          }
          var out: [SpeakerSegment] = []
          for t in tokens {
              guard let best = timeline.enumerated().max(by: { overlap(t, $0.element) < overlap(t, $1.element) })?.element,
                    overlap(t, best) > 0 || timeline.count == 1 else { continue }
              let piece = t.text.replacingOccurrences(of: "▁", with: " ")
              if var last = out.last, last.speaker == best.speaker {
                  last.text += piece
                  last.end = max(last.end, t.end)
                  out[out.count - 1] = last
              } else {
                  out.append(SpeakerSegment(speaker: best.speaker, text: piece, start: t.start, end: t.end))
              }
          }
          // Snap each segment's bounds to its speaker range and tidy whitespace.
          return out.compactMap { seg in
              let text = seg.text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
              guard !text.isEmpty else { return nil }
              let r = timeline.first { $0.speaker == seg.speaker }
              return SpeakerSegment(speaker: seg.speaker, text: text,
                                    start: r?.start ?? seg.start, end: r?.end ?? seg.end)
          }
      }
  }
  ```
  GOTCHA: the `overlap > 0 || timeline.count == 1` guard lets a single-speaker timeline absorb tokens that don't strictly overlap (rounding). Bounds are snapped to the matched speaker's range so segment start/end are stable.

- [ ] **Step 4: Run test** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(recorder): pure token↔speaker-timeline alignment`

### Task 2: `FluidAudioDiarizer` — local ASR + diarizer, aligned
**Files:**
- Create: `VoiceInk/Services/RecorderAutomation/FluidAudioDiarizer.swift`
- (No unit test — model I/O; the alignment seam is tested in Task 1, integration via manual validation.)

- [ ] **Step 1: (No test-first — model/IO orchestration.)**

- [ ] **Step 2: Write minimal implementation**
  ```swift
  import Foundation
  import FluidAudio
  import os

  /// On-device diarization fallback for models without native diarization.
  /// Runs FluidAudio Parakeet ASR (token timings) + the FluidAudio diarizer (speaker timeline)
  /// on the recorder audio, then aligns them into speaker segments. Lazy-loads + caches models.
  @MainActor
  final class FluidAudioDiarizer {
      static let shared = FluidAudioDiarizer()
      private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
      private var diarizer: OfflineDiarizerManager?
      private var asr: AsrManager?
      private init() {}

      /// True once models exist on disk (so callers can post a first-run download notice).
      private var loaded: Bool { diarizer != nil && asr != nil }

      private func ensureLoaded() async throws {
          if diarizer == nil {
              let d = OfflineDiarizerManager(config: .default)
              try await d.prepareModels()          // auto-downloads on first run
              diarizer = d
          }
          if asr == nil {
              // MIRROR FluidAudioTranscriptionService.swift:50,82 — create + load Parakeet models.
              let m = AsrManager(config: .default)
              let models = try await AsrModels.downloadAndLoad()   // verify exact API at read time
              try await m.initialize(models: models)
              asr = m
          }
      }

      /// Returns aligned speaker segments, or nil on any failure (caller degrades to plain transcript).
      /// `onFirstDownload` fires once if models had to be fetched (for a UI notice).
      func diarize(audioURL: URL, expectedSpeakers: Int?, onFirstDownload: () -> Void) async -> [SpeakerSegment]? {
          do {
              let needsDownload = !loaded
              if needsDownload { onFirstDownload() }
              try await ensureLoaded()
              guard let diarizer, let asr else { return nil }

              let samples = try await AudioProcessor().processAudioToSamples(audioURL)  // 16kHz [Float]
              async let asrResult = asr.transcribe(samples)                              // ASRResult
              async let diaResult = diarizer.process(audio: samples)                     // DiarizationResult
              let (a, d) = try await (asrResult, diaResult)

              let tokens = (a.tokenTimings ?? []).map {
                  DiarizationAlignment.Token(text: $0.token, start: $0.startTime, end: $0.endTime)
              }
              let timeline = d.segments.map {
                  DiarizationAlignment.SpeakerRange(speaker: $0.speakerId,
                                                    start: $0.startTimeSeconds, end: $0.endTimeSeconds)
              }
              guard !tokens.isEmpty, !timeline.isEmpty else {
                  logger.notice("FluidAudio diarization produced no tokens/timeline"); return nil
              }
              let segs = DiarizationAlignment.align(tokens: tokens, timeline: timeline)
              logger.notice("FluidAudio diarization → \(segs.count, privacy: .public) segments")
              return segs.isEmpty ? nil : segs
          } catch {
              logger.error("FluidAudio diarization failed: \(error.localizedDescription, privacy: .public)")
              return nil
          }
      }
  }
  ```
  GOTCHA: verify the exact `AsrModels.downloadAndLoad()` / `AsrManager.initialize(models:)` / `asr.transcribe(_:)` signatures against `FluidAudioTranscriptionService.swift:50,82,131-197` (the service already does this; mirror it exactly). `expectedSpeakers` is accepted for parity with the native path; wire it into `OfflineDiarizerConfig` if the config exposes a speaker-count/threshold field, otherwise ignore for M2 and note it.
  GOTCHA: `AudioProcessor` type name — confirm at `AudioFileProcessor.swift:37` (may be `AudioProcessor` or `AudioFileProcessor`).

- [ ] **Step 3: Manual validation** — see Manual Validation.
- [ ] **Step 4: Commit** — `feat(recorder): FluidAudioDiarizer — local ASR+diarizer aligned`

### Task 3: Coordinator fallback branch
**Files:**
- Modify: `VoiceInk/Services/RecorderAutomation/DiarizationCoordinator.swift:27-28`
- Test:   `VoiceInkTests/RecorderDiarizationM2Tests.swift`

- [ ] **Step 1: Write the failing test** (capability routing still holds; add a fallback-eligibility check)
  ```swift
  func testNonNativeModelIsFallbackEligible() {
      // native check stays false for local models; coordinator will route them to the fallback.
      XCTAssertFalse(DiarizationCoordinator.supportsNativeDiarization(modelName: "large-v3-turbo"))
      XCTAssertTrue(DiarizationCoordinator.supportsNativeDiarization(modelName: "scribe_v2"))
  }
  ```
  Run: expect PASS already for supportsNativeDiarization (from M1) — this test guards the routing contract; the behavior change is verified manually + by the fallback call being reachable.

- [ ] **Step 2: Run test** — Expected: PASS (guard test).

- [ ] **Step 3: Write minimal implementation** — change the M1 early-return into a fallback:
  ```swift
  static func diarize(audioURL: URL, transcriptionModelName: String?,
                      language: String?, expectedSpeakers: Int?) async -> [SpeakerSegment]? {
      if supportsNativeDiarization(modelName: transcriptionModelName), let modelName = transcriptionModelName {
          // …existing M1 ElevenLabs native path unchanged…
          // (returns segments or nil)
          if let native = await nativeElevenLabs(audioURL: audioURL, modelName: modelName,
                                                 language: language, expectedSpeakers: expectedSpeakers) {
              return native
          }
          // native failed → still try the local fallback below rather than giving up
      }
      // M2: universal local fallback for any non-native (or native-failed) model.
      return await FluidAudioDiarizer.shared.diarize(
          audioURL: audioURL, expectedSpeakers: expectedSpeakers,
          onFirstDownload: {
              NotificationManager.shared.showNotification(
                  title: "首次語者辨識：正在下載本地模型…", type: .info, duration: 4)
          })
  }
  ```
  Refactor the M1 ElevenLabs body into a `private static func nativeElevenLabs(...) async -> [SpeakerSegment]?` so the top stays readable. Keep all M1 behavior (missing key / HTTP error → nil) inside it.
  GOTCHA: `FluidAudioDiarizer` is `@MainActor`; `DiarizationCoordinator` is already `@MainActor`, so the call is direct.

- [ ] **Step 4: Run test** — Expected: PASS; build green.
- [ ] **Step 5: Commit** — `feat(recorder): coordinator falls back to FluidAudio for non-native models`

### Task 4: Update the post-processor notice
**Files:**
- Modify: `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` (the M1 diarization block)

- [ ] **Step 1: (No test — glue.)**

- [ ] **Step 2: Write minimal implementation** — the M1 block showed a "此轉錄模型尚不支援語者辨識" notice for non-native models. Now that a fallback exists, remove that `else if` notice (non-native now diarizes locally). Keep the success path (`transcription.speakerSegments = segments; try? modelContext.save()`). Optionally, when `diarize` returns nil, show a softer "語者辨識未產生結果（保留純文字）" info notice.
  ```swift
  if let segments = await DiarizationCoordinator.diarize(
      audioURL: url,
      transcriptionModelName: transcription.transcriptionModelName,
      language: store.recorderLanguage,
      expectedSpeakers: store.recorderExpectedSpeakerCount) {
      transcription.speakerSegments = segments
      try? modelContext.save()
  }
  // (drop the M1 non-native info notice; fallback now covers those models)
  ```

- [ ] **Step 3: Manual validation.**
- [ ] **Step 4: Commit** — `feat(recorder): drop non-native diarization notice now fallback exists`

---

## Testing Strategy

### Unit Tests (`VoiceInkTests/RecorderDiarizationM2Tests.swift`, pure-seam)

| Test | Input | Expected | Edge Case? |
|---|---|---|---|
| align max-overlap | 3 tokens, 2 ranges | 2 segments, correct speaker+text+bounds | — |
| align cleans ▁ markers | `▁hello ▁world` tokens | "hello world" | — |
| align empty inputs | `[]` / tokens+no timeline | `[]` | ✅ empty |
| supportsNativeDiarization contract | scribe_v2 / local | true / false | ✅ routing guard |

### Edge Cases Checklist
- [ ] Token with no overlapping range (multi-speaker timeline) → dropped, not misattributed
- [ ] Single-speaker timeline → all tokens absorbed
- [ ] Diarizer returns 1 speaker → one segment (still "講者1")
- [ ] ASR returns nil `tokenTimings` → nil (degrade, plain transcript kept)
- [ ] Models not yet downloaded → first-run notice, then proceeds
- [ ] Native ElevenLabs still works unchanged (M1 regression)

---

## Validation Commands

> Use the `voiceink-build-verify` skill. Host-app test bundle needs the `make local` signing settings.

### Build
```bash
cd "/Users/logan/Projects/Archive Project/VoiceInk"
make local
```
EXPECT: BUILD SUCCEEDED (into `.local-build`, no ghost app).

### Unit tests
```bash
cd "/Users/logan/Projects/Archive Project/VoiceInk"
SWIFT_ENABLE_EXPLICIT_MODULES=NO xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk \
  -configuration Debug -derivedDataPath ./.local-build -xcconfig LocalBuild.xcconfig \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:VoiceInkTests/RecorderDiarizationM2Tests \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD'
```
EXPECT: `RecorderDiarizationM2Tests` + `RecorderDiarizationTests` (M1) all pass.

### Manual Validation
- [ ] Recorder Mode → 語者辨識 ON, model = a **local Whisper** model. Import a 2-speaker clip.
- [ ] First run: "正在下載本地模型" notice; subsequent runs skip it.
- [ ] 逐字稿 sheet shows 講者1 / 講者2 blocks (text from FluidAudio); rename works (M1 UI).
- [ ] Switch model to **ElevenLabs** → native path still used (M1 unchanged).
- [ ] Model = local, no diarizer models + offline → degrades to plain transcript, no crash.

---

## Acceptance Criteria (maps to SRS)
- [ ] **AC-4** local Whisper (non-native) → FluidAudio timeline aligned to tokens → ≥2 speakers; `speakerLabeled = true` (Tasks 1,2,3)
- [ ] **AC-6** any failure (no models / offline / nil timings) → plain transcript kept, no crash (Tasks 2,3)
- [ ] **AC-2 regression** ElevenLabs native still works (Task 3 keeps M1 path)

## Completion Checklist
- [ ] Alignment is a pure, tested function (no FluidAudio types leak into it)
- [ ] Fallback never throws out of the coordinator (returns nil → degrade)
- [ ] Logging via `os.Logger` category `RecorderAutomation`
- [ ] No shared transcription-pipeline / protocol changes
- [ ] `make local` builds; M1 + M2 tests green
- [ ] Docs: mark AC-4 shipped in SRS; Module Spec Change History row

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Fallback re-runs Parakeet ASR (extra local compute) | H | M | Local only, no API cost; runs once per import when diarization on |
| Parakeet token text (subword ▁) joins imperfectly for CJK | M | M | ▁→space + whitespace tidy; text is the speaker-view only, plain `text` unchanged |
| Diarizer/ASR model download size + first-run latency | M | M | One-time; first-run notice; auto-download via `prepareModels()` |
| Loading a 2nd AsrManager doubles model memory | M | L | Isolated for M2; sharing the app's instance is a noted M3 optimization |
| FluidAudio API drift (`downloadAndLoad`/`initialize`) | L | M | Mirror the exact calls in `FluidAudioTranscriptionService` (already compiles) |

## Notes
- **Design**: fully decoupled, on-device. `transcription.text` stays as the user's chosen model's output; the speaker view uses FluidAudio-derived segment text. Minor text divergence between the two is accepted (same tradeoff class as M1's ElevenLabs path) and documented for the user in the settings copy.
- **Why FluidAudio ASR for text (not the user's model)**: the user's model returns only a flat `String` (no timestamps) through the shared pipeline; extracting Whisper segment timestamps would require invasive protocol/pipeline changes. FluidAudio's `ASRResult.tokenTimings` gives timestamps locally with zero pipeline surgery, and works for every non-native model uniformly (incl. Apple Native).
- **M3 candidates**: share the app's loaded Parakeet `AsrManager`; other cloud providers' native diarize; speaker labels in the Obsidian export; wire `expectedSpeakers` into `OfflineDiarizerConfig` if it exposes a speaker-count constraint.
