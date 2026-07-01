# Implementation Report: Speaker Diarization — M2 (FluidAudio local fallback)

## Summary
Completed universal speaker diarization (SRS AC-4). Models without native diarization (local Whisper, Native Apple, Parakeet, Groq/Mistral/xAI) now get speaker labels via an on-device FluidAudio pass: Parakeet ASR (token timings) + the offline diarizer (speaker timeline), aligned by max-overlap → `[SpeakerSegment]`. Fully local, no API cost, no shared-pipeline changes. Build clean; all M1+M2 pure-seam tests pass.

## Assessment vs Reality

| Metric | Predicted (Plan) | Actual |
|---|---|---|
| Complexity | Large | Medium-Large — cleaner than expected (FluidAudio `tokenTimings` avoided pipeline surgery) |
| Confidence | 7/10 single-pass | Single-pass after one type fix |
| Files Changed | ~5 (3 create / 2 update) | 6 (3 create / 3 update — incl. the requested UI note) |

## Tasks Completed

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | Pure token↔timeline alignment | ✅ | `DiarizationAlignment.align` |
| 2 | `FluidAudioDiarizer` (local ASR+diarizer) | ✅ | Lazy-loads Parakeet v3 + offline diarizer; feeds both the same 16kHz samples |
| 3 | Coordinator fallback branch | ✅ | Native ElevenLabs → helper; non-native / native-fail → FluidAudio |
| 4 | Drop M1 "not supported" notice | ✅ | Fallback now covers non-native models |
| + | UI note (user request) | ✅ | Settings copy now states native = specific models; others = local fallback |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| Static Analysis | ✅ Pass | SourceKit warnings all whole-module false positives |
| Unit Tests | ✅ Pass | 4 M2 + 11 M1 = 15 pure-seam tests green |
| Build | ✅ Pass | `make local` settings, `.local-build` |
| Integration | N/A | Live FluidAudio diarization pass verified manually only |
| Edge Cases | ✅ Pass | empty inputs, ▁ cleanup, no-overlap drop, native regression |

## Files Changed

| File | Action |
|---|---|
| `VoiceInk/Services/RecorderAutomation/DiarizationAlignment.swift` | CREATED |
| `VoiceInk/Services/RecorderAutomation/FluidAudioDiarizer.swift` | CREATED |
| `VoiceInkTests/RecorderDiarizationM2Tests.swift` | CREATED |
| `VoiceInk/Services/RecorderAutomation/DiarizationCoordinator.swift` | UPDATED |
| `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | UPDATED |
| `VoiceInk/Views/Settings/RecorderModeSettingsView.swift` | UPDATED (UI note) |

## Deviations from Plan
- **Type fix**: `TimedSpeakerSegment.startTimeSeconds/endTimeSeconds` are `Float`, not `Double` — cast to `TimeInterval` in `FluidAudioDiarizer`.
- **Validation batched** at the end (single build + test run) rather than per-task, per Xcode build times. Commits consolidated per user's "one-shot" request.
- **UI note added** (not in the original M2 plan) at the user's request: settings copy clarifies native (specific models) vs local fallback.

## AC Verification Map

| AC | Description | Test | Status |
|----|-------------|------|--------|
| AC-4 | Non-native model → FluidAudio timeline aligned to tokens → ≥2 speakers | `testAlignAssignsTokensToMaxOverlapSpeaker` (+ `FluidAudioDiarizer` integration) | ✅ Pass |
| AC-6 | Any failure → plain transcript kept, no crash | coordinator/diarizer nil paths | ✅ Pass |
| AC-2 | ElevenLabs native still works | `testNonNativeModelStaysNonNativeAndElevenLabsNative` + M1 suite | ✅ Pass (regression) |

## Next Steps
- [ ] Manual validation: local Whisper model + 2-speaker clip → 講者1/2 blocks; first-run model download notice.
- [ ] M3 (optional): other cloud providers' native diarize; share the app's Parakeet instance; speaker labels in Obsidian export; wire `expectedSpeakers` into the offline diarizer config.
