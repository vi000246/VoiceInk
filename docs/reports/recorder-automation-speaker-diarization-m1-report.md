# Implementation Report: Speaker Diarization — M1 (native ElevenLabs)

## Summary
Implemented the M1 vertical slice of universal speaker diarization for recorder transcripts: the data model, the native ElevenLabs diarization path (in-repo `diarize=true` client), Recorder Mode settings, and a speaker-grouped transcript view with manual rename. Built clean and all pure-seam tests pass. FluidAudio local fallback + Whisper alignment (SRS AC-4) remain deferred to M2.

## Assessment vs Reality

| Metric | Predicted (Plan) | Actual |
|---|---|---|
| Complexity | Large | Large — as predicted |
| Confidence | 8/10 single-pass | Single-pass achieved; one plan bug caught by SourceKit |
| Files Changed | ~11 (5 create / 6 update) | 11 (4 create / 7 update) |

## Tasks Completed

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | SpeakerSegment + merge | ✅ | Plan used `w.speaker`; actual field is `w.speakerId` — fixed |
| 2 | Transcription fields + accessors + rename | ✅ | |
| 3 | supportsNativeDiarization capability | ✅ | Protocol default false; CloudModel stored field; ElevenLabs true |
| 4 | ElevenLabs diarized response parse | ✅ | |
| 5 | Diarizing network call + multipart builder | ✅ | `URLSession.upload(for:from:)` |
| 6 | RecorderConfigStore diarization settings | ✅ | |
| 7 | DiarizationCoordinator | ✅ | Native routing + graceful degrade (never throws) |
| 8 | Wire into RecorderPostProcessor.process() | ✅ | Runs before classification; non-native → info notice |
| 9 | Recorder Mode settings UI | ✅ | Toggle + expected-speakers stepper |
| 10 | Speaker-grouped view + rename | ✅ | Passed `transcription` into TranscriptSheet |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| Static Analysis | ✅ Pass | SourceKit warnings were whole-module false positives; clean compile |
| Unit Tests | ✅ Pass | 11 pure-seam tests in `RecorderDiarizationTests` |
| Build | ✅ Pass | `make local` signing settings, `.local-build` (no ghost app) |
| Integration | N/A | Live ElevenLabs diarize call verified manually only |
| Edge Cases | ✅ Pass | empty words, nil speaker count, non-native degrade, blank rename |

## Files Changed

| File | Action |
|---|---|
| `VoiceInk/Models/SpeakerSegment.swift` | CREATED |
| `VoiceInk/Transcription/Cloud/ElevenLabsDiarizingClient.swift` | CREATED |
| `VoiceInk/Services/RecorderAutomation/DiarizationCoordinator.swift` | CREATED |
| `VoiceInkTests/RecorderDiarizationTests.swift` | CREATED |
| `VoiceInk/Models/Transcription.swift` | UPDATED |
| `VoiceInk/Models/TranscriptionModel.swift` | UPDATED |
| `VoiceInk/Transcription/Cloud/ElevenLabsProvider.swift` | UPDATED |
| `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` | UPDATED |
| `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | UPDATED |
| `VoiceInk/Views/Settings/RecorderModeSettingsView.swift` | UPDATED |
| `VoiceInk/Views/History/RecorderHistoryView.swift` | UPDATED |

## Deviations from Plan
- **Plan code bug**: Task 1's `merge` compared `w.speaker` but `DiarizedWord`'s field is `speakerId`. SourceKit flagged it immediately; fixed before build.
- **Validation batching**: builds/tests were run once at the end (single consolidated `xcodebuild`) rather than per-task, because each Xcode build is minutes-long. Per-task commits were also consolidated into one feature commit at the user's request ("do it all at once, then commit").

## AC Verification Map

| AC | Description | Test | Status |
|----|-------------|------|--------|
| AC-1 | Diarization off by default → transcript unchanged | `testDiarizationSettingPersists` + degrade path | ✅ Pass |
| AC-2 | ElevenLabs native → ≥2 merged speaker segments | `testMergeGroupsConsecutiveSameSpeakerWords`, `testParseDiarizedResponseToSegments` | ✅ Pass |
| AC-3 | `expectedSpeakerCount` → `num_speakers` forwarded | `testBuildMultipartBodyIncludesDiarizeAndSpeakerCount` | ✅ Pass |
| AC-5 | Anonymous 講者N render + rename transcript-wide | `testDisplayNameResolvesThroughRenameMap` | ✅ Pass |
| AC-6 | Failure/non-native degrades, transcript preserved | `testCoordinatorRecognizesNativeCapableModelByName` + coordinator nil path | ✅ Pass |
| AC-4 | FluidAudio local fallback aligned to segments | — | ⏭ Deferred to M2 |

## Next Steps
- [ ] Manual validation on a real 2-speaker meeting clip with ElevenLabs `scribe_v2`
- [ ] M2 plan: FluidAudio local fallback + Whisper alignment (AC-4), other native providers
- [ ] Optional: `/code-review` on the branch
