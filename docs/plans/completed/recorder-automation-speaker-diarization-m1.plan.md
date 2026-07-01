---
linear_issue: null
---
# Plan: Speaker Diarization — M1 (native ElevenLabs vertical slice)

> **For agentic workers:** `/prp-implement` routes this by `Metadata.Type` (feature → `implementing-features`). Steps use `- [ ]` checkboxes. Mode B — each task writes a failing test first, then the minimal implementation, then commits.

## Summary
Give recorder-imported meeting transcripts per-speaker segments ("講者1 / 講者2 …") so the user can tell who said what. This M1 slice implements the **data model**, the **native ElevenLabs diarization path** (in-repo client calling `diarize=true`), the **Recorder Mode settings**, and the **speaker-grouped UI with manual rename**. The FluidAudio local fallback and Whisper alignment are deferred to M2.

## User Story
As someone who records meetings and imports them via VoiceInk,
I want the transcript split by speaker with editable speaker names,
So that I can read who said what instead of one undifferentiated wall of text.

## Problem → Solution
Recorder transcripts are a single flat `text` string with no speaker attribution → recorder transcripts made with a diarization-capable model (ElevenLabs Scribe) are stored as per-speaker segments, rendered grouped by speaker, with anonymous labels the user can rename transcript-wide.

## Metadata
- **Module**: recorder-automation
- **Parent Plan**: N/A
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
- **Commit cadence**: per-task
- **Estimated Files**: ~11 (5 create, 6 update)

---

## UX Design

### Before
```
┌────────────────────────────────────────────┐
│ Recording Management → 逐字稿 sheet          │
│                                              │
│ 今天我們要討論第三季的預算，首先請財務部…        │
│ 好的，第三季我們預估營收成長百分之十二…          │
│ （整段沒有分講者，一整塊文字）                    │
└────────────────────────────────────────────┘
```

### After
```
┌────────────────────────────────────────────┐
│ Recording Management → 逐字稿 sheet          │
│                                              │
│ 講者1  ✎                                     │
│   今天我們要討論第三季的預算，首先請財務部…       │
│                                              │
│ 講者2  ✎                                     │
│   好的，第三季我們預估營收成長百分之十二…         │
│                                              │
│ (tap ✎ on 講者1 → rename to "老闆" →          │
│  every 講者1 block re-labels to 老闆)          │
└────────────────────────────────────────────┘
```

### Interaction Changes
| Touchpoint | Before | After | Notes |
|---|---|---|---|
| Recorder Mode settings | model/language/formatting only | + "啟用語者辨識" toggle + optional "預期人數" | Off by default |
| 逐字稿 sheet (`RecorderHistoryView.TranscriptSheet`) | one Markdown blob | speaker-grouped blocks when `speakerLabeled`, else unchanged | Falls back to flat text when not diarized |
| Speaker label | none | tap ✎ to rename; applies to all that speaker's segments | Persisted per-transcript |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/recorder-automation-speaker-diarization.srs.md` | all | Feature scope, FRs, ACs (M1 covers AC-1,2,3,5,6; AC-4 is M2) |
| P0 | `VoiceInk/Models/Transcription.swift` | 41-50 | `speakerLabeled` + `audioChunkURLs`/`audioChunkPathsRaw` accessor pattern to mirror |
| P0 | `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | 78-106 | `process()` — the per-item post-transcription entry where diarization hooks in |
| P0 | `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` | 19,38,65,95-97 | Recorder-setting property/key/load/setter pattern to mirror |
| P0 | `.local-build/SourcePackages/checkouts/LLMkit/Sources/LLMkit/Transcription/ElevenLabsClient.swift` | 18-53 | The (remote, non-editable) client to re-implement in-repo with `diarize=true` |
| P1 | `VoiceInk/Transcription/Cloud/ElevenLabsProvider.swift` | 21-54 | CloudModel definitions to flag `supportsNativeDiarization`; API-key provider key `"ElevenLabs"` |
| P1 | `VoiceInk/Models/TranscriptionModel.swift` | 4-33,47-59,115-139 | `ModelProvider`, `TranscriptionModel` protocol, `CloudModel` — add capability flag |
| P1 | `VoiceInk/Services/APIKeyManager.swift` | 45 | `getAPIKey(forProvider:)` |
| P1 | `VoiceInk/Views/Settings/RecorderModeSettingsView.swift` | 19-33,83-95 | Section + Toggle + Binding pattern; add diarization controls |
| P1 | `VoiceInk/Views/History/RecorderHistoryView.swift` | 219-221,456-502 | `displayText` + `TranscriptSheet` rendering; add speaker grouping + rename |
| P1 | `VoiceInkTests/RecorderPipelineTests.swift` | 1-70 | Pure-seam XCTest style to mirror for all M1 tests |
| P2 | `VoiceInk/Transcription/Cloud/CloudTranscriptionService.swift` | 66-90 | How provider + API key + audio bytes are assembled (reference for the coordinator) |

## External Documentation

| Topic | Source | Key Takeaway |
|---|---|---|
| ElevenLabs STT diarization | https://elevenlabs.io/docs/api-reference/speech-to-text/convert | `diarize=true` (multipart field) → each `words[]` item gains `speaker_id`; optional `num_speakers` (int) or `diarization_threshold` (0.1–0.4, only when `num_speakers` unset). Response: `{ text, language_code, words: [{ text, start, end, type, speaker_id }] }`. `type` ∈ {`word`,`spacing`,`audio_event`}. |

---

## Patterns to Mirror

### CONFIG_STORE_SETTING
```swift
// SOURCE: VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift:19,38,65,95-97
@Published private(set) var recorderTranscriptionModelName: String?   // nil = auto
private let recTranscriptionKey = "recorderTranscriptionModelV1"
// in load(): recorderTranscriptionModelName = UserDefaults.standard.string(forKey: recTranscriptionKey)
func setRecorderTranscriptionModel(_ name: String?) {
    recorderTranscriptionModelName = name; persistString(name, recTranscriptionKey)
}
// Bool example already in file (line 66/104): UserDefaults.standard.bool(forKey:) + UserDefaults.standard.set(_,forKey:)
```

### JSON_RAW_FIELD_ACCESSOR
```swift
// SOURCE: VoiceInk/Models/Transcription.swift:44-50
var audioChunkPathsRaw: String?
var audioChunkURLs: [URL] {
    guard let raw = audioChunkPathsRaw, !raw.isEmpty else { return [] }
    return raw.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
}
```

### SETTINGS_TOGGLE_BINDING
```swift
// SOURCE: VoiceInk/Views/Settings/RecorderModeSettingsView.swift:27-32,83-85
Toggle(isOn: formattingBinding) { Text("段落分隔（自動分段）") }
private var formattingBinding: Binding<Bool> {
    Binding(get: { store.recorderTextFormattingEnabled }, set: { store.setRecorderTextFormatting($0) })
}
```

### PURE_SEAM_TEST
```swift
// SOURCE: VoiceInkTests/RecorderPipelineTests.swift:4,20-28
@MainActor
final class RecorderPipelineTests: XCTestCase {
    func testParseResolvesKnownCategoryId() {
        let raw = #"{"categoryId": "…", "confidence": 0.83}"#
        let result = TranscriptClassificationService.shared.parse(raw, categories: all)
        XCTAssertEqual(result.confidence, 0.83, accuracy: 0.0001)
    }
}
```

### MULTIPART_REQUEST (re-implement in-repo; LLMkit's MultipartFormData is not visible outside the package)
```swift
// SOURCE (shape to reproduce): LLMkit ElevenLabsClient.swift:28-52
// POST https://api.elevenlabs.io/v1/speech-to-text ; header xi-api-key: <key> ; multipart/form-data
// fields: file (audio/wav bytes), model_id, temperature=0.0, tag_audio_events=false,
//         [language_code], diarize=true, [num_speakers]
```

### NOTIFICATION (degrade notice)
```swift
// SOURCE: VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift:100-103
NotificationManager.shared.showNotification(title: "…", type: .info, duration: 3)
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Models/SpeakerSegment.swift` | CREATE | The `SpeakerSegment` value type + a pure `merge(words:)` helper |
| `VoiceInk/Models/Transcription.swift` | UPDATE | Add `speakerSegmentsRaw`/`speakerNamesRaw` + computed accessors + display-name resolver |
| `VoiceInk/Models/TranscriptionModel.swift` | UPDATE | Add `supportsNativeDiarization` to protocol (default false) + `CloudModel` stored field |
| `VoiceInk/Transcription/Cloud/ElevenLabsProvider.swift` | UPDATE | Flag scribe models `supportsNativeDiarization: true` |
| `VoiceInk/Transcription/Cloud/ElevenLabsDiarizingClient.swift` | CREATE | In-repo `diarize=true` client → `(text, [SpeakerSegment])` |
| `VoiceInk/Services/RecorderAutomation/DiarizationCoordinator.swift` | CREATE | Route native-capable model → native diarize; else nil (M1 no fallback); catch → nil (degrade) |
| `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` | UPDATE | Add `recorderDiarizationEnabled` + `recorderExpectedSpeakerCount` (property/key/load/setter) |
| `VoiceInk/Views/Settings/RecorderModeSettingsView.swift` | UPDATE | "啟用語者辨識" toggle + "預期人數" field + bindings |
| `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | UPDATE | Call the coordinator at the top of `process()`; write segments + `speakerLabeled` |
| `VoiceInk/Views/History/RecorderHistoryView.swift` | UPDATE | Speaker-grouped rendering in `TranscriptSheet` + per-speaker rename |
| `VoiceInkTests/RecorderDiarizationTests.swift` | CREATE | Pure-seam tests: word→segment merge, accessor round-trip, rename resolution, coordinator routing |

## NOT Building (deferred to M2 / out of scope)

- FluidAudio local diarization fallback (`FluidAudioDiarizer`) and Whisper segment-timestamp **alignment** — local/Apple/Groq models get no speaker labels in M1 (they hit the graceful-degrade path). SRS **AC-4** is M2.
- Native diarization for providers other than ElevenLabs (Deepgram / AssemblyAI / Speechmatics / Soniox).
- Folding diarization into the main transcription call to avoid a second API call (SRS NFR "no extra call"). **M1 deviation**: M1 runs a dedicated diarize call on the original audio file (see Decisions/Notes).
- Cross-recording / cross-chunk speaker identity, voiceprint enrollment auto-naming.
- Streaming (real-time) diarization.
- Speaker labels inside the exported Obsidian Markdown (export continues to use flat `text`).

---

## Step-by-Step Tasks

### Task 1: `SpeakerSegment` value type + word→segment merge
**Files:**
- Create: `VoiceInk/Models/SpeakerSegment.swift`
- Test:   `VoiceInkTests/RecorderDiarizationTests.swift`

- [ ] **Step 1: Write the failing test**
  ```swift
  import XCTest
  @testable import VoiceInk

  @MainActor
  final class RecorderDiarizationTests: XCTestCase {
      // MARK: - SpeakerSegment.merge
      func testMergeGroupsConsecutiveSameSpeakerWords() {
          let words = [
              DiarizedWord(text: "今天", start: 0.0, end: 0.4, speakerId: "speaker_0", type: "word"),
              DiarizedWord(text: " ",   start: 0.4, end: 0.5, speakerId: "speaker_0", type: "spacing"),
              DiarizedWord(text: "開會", start: 0.5, end: 0.9, speakerId: "speaker_0", type: "word"),
              DiarizedWord(text: "好的", start: 1.0, end: 1.4, speakerId: "speaker_1", type: "word"),
          ]
          let segs = SpeakerSegment.merge(words: words)
          XCTAssertEqual(segs.count, 2)
          XCTAssertEqual(segs[0].speaker, "speaker_0")
          XCTAssertEqual(segs[0].text, "今天 開會")
          XCTAssertEqual(segs[0].start, 0.0, accuracy: 0.0001)
          XCTAssertEqual(segs[0].end, 0.9, accuracy: 0.0001)
          XCTAssertEqual(segs[1].speaker, "speaker_1")
          XCTAssertEqual(segs[1].text, "好的")
      }

      func testMergeSkipsAudioEventsAndEmptyInput() {
          XCTAssertTrue(SpeakerSegment.merge(words: []).isEmpty)
          let words = [DiarizedWord(text: "(laughter)", start: 0, end: 1, speakerId: "speaker_0", type: "audio_event")]
          XCTAssertTrue(SpeakerSegment.merge(words: words).isEmpty)
      }
  }
  ```
  Run: expect FAIL (types `SpeakerSegment`, `DiarizedWord` don't exist).

- [ ] **Step 2: Run test to verify it fails**
  Run: (see Validation Commands) — Expected: compile error / FAIL.

- [ ] **Step 3: Write minimal implementation**
  ```swift
  import Foundation

  /// One diarized word as returned by a native STT diarization API.
  struct DiarizedWord: Equatable {
      let text: String
      let start: TimeInterval
      let end: TimeInterval
      let speakerId: String
      let type: String            // "word" | "spacing" | "audio_event"
  }

  /// A contiguous run of speech by one speaker. `speaker` is a stable anonymous id
  /// (e.g. "speaker_0"); display names are resolved separately via Transcription.speakerNames.
  struct SpeakerSegment: Codable, Equatable {
      var speaker: String
      var text: String
      var start: TimeInterval
      var end: TimeInterval

      /// Merge consecutive same-speaker words into segments. `spacing` words keep the current
      /// speaker; `audio_event` words are dropped. Whitespace-only leading/trailing is trimmed.
      static func merge(words: [DiarizedWord]) -> [SpeakerSegment] {
          var out: [SpeakerSegment] = []
          for w in words where w.type != "audio_event" {
              if var last = out.last, last.speaker == w.speaker {
                  last.text += w.text
                  last.end = w.end
                  out[out.count - 1] = last
              } else if w.type == "spacing", out.isEmpty {
                  continue // leading spacing with no owner
              } else if w.type == "spacing" {
                  var last = out[out.count - 1]; last.text += w.text; last.end = w.end
                  out[out.count - 1] = last
              } else {
                  out.append(SpeakerSegment(speaker: w.speaker, text: w.text, start: w.start, end: w.end))
              }
          }
          return out.map { var s = $0; s.text = s.text.trimmingCharacters(in: .whitespaces); return s }
                    .filter { !$0.text.isEmpty }
      }
  }
  ```

- [ ] **Step 4: Run test to verify it passes** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(recorder): SpeakerSegment type + word→segment merge`

### Task 2: `Transcription` diarization fields + accessors + rename resolver
**Files:**
- Modify: `VoiceInk/Models/Transcription.swift:41-50`
- Test:   `VoiceInkTests/RecorderDiarizationTests.swift`

- [ ] **Step 1: Write the failing test**
  ```swift
  func testSpeakerSegmentsRoundTripThroughRawField() {
      let t = Transcription(text: "x", duration: 1)
      t.speakerSegments = [SpeakerSegment(speaker: "speaker_0", text: "hi", start: 0, end: 1)]
      XCTAssertNotNil(t.speakerSegmentsRaw)
      XCTAssertEqual(t.speakerSegments.first?.speaker, "speaker_0")
      XCTAssertTrue(t.speakerLabeled)
  }

  func testDisplayNameResolvesThroughRenameMap() {
      let t = Transcription(text: "x", duration: 1)
      t.speakerSegments = [SpeakerSegment(speaker: "speaker_0", text: "hi", start: 0, end: 1)]
      XCTAssertEqual(t.displayName(for: "speaker_0"), "講者1")   // anonymous default
      t.renameSpeaker("speaker_0", to: "老闆")
      XCTAssertEqual(t.displayName(for: "speaker_0"), "老闆")
      XCTAssertEqual(t.speakerNames["speaker_0"], "老闆")
  }
  ```
  Run: expect FAIL.

- [ ] **Step 2: Run test** — Expected: FAIL (members don't exist).

- [ ] **Step 3: Write minimal implementation** — add after `audioChunkURLs` (line 50):
  ```swift
  /// JSON-encoded [SpeakerSegment] when the transcript was diarized; nil otherwise.
  var speakerSegmentsRaw: String?
  /// JSON-encoded [speakerId: displayName] rename map; nil = all anonymous.
  var speakerNamesRaw: String?

  var speakerSegments: [SpeakerSegment] {
      get {
          guard let raw = speakerSegmentsRaw, let data = raw.data(using: .utf8) else { return [] }
          return (try? JSONDecoder().decode([SpeakerSegment].self, from: data)) ?? []
      }
      set {
          speakerSegmentsRaw = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
          speakerLabeled = !newValue.isEmpty
      }
  }

  var speakerNames: [String: String] {
      get {
          guard let raw = speakerNamesRaw, let data = raw.data(using: .utf8) else { return [:] }
          return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
      }
      set {
          speakerNamesRaw = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
      }
  }

  /// Ordered distinct speaker ids as they first appear — index drives the "講者N" fallback label.
  var orderedSpeakerIds: [String] {
      var seen: [String] = []
      for s in speakerSegments where !seen.contains(s.speaker) { seen.append(s.speaker) }
      return seen
  }

  /// Display name for a speaker id: the rename map wins; otherwise "講者N" by first-appearance order.
  func displayName(for speakerId: String) -> String {
      if let name = speakerNames[speakerId], !name.isEmpty { return name }
      let idx = orderedSpeakerIds.firstIndex(of: speakerId) ?? 0
      return "講者\(idx + 1)"
  }

  func renameSpeaker(_ speakerId: String, to name: String) {
      var map = speakerNames
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { map.removeValue(forKey: speakerId) } else { map[speakerId] = trimmed }
      speakerNames = map
  }
  ```
  GOTCHA: SwiftData `@Model` — new stored props must be optional (or defaulted) for lightweight migration; `speakerSegmentsRaw`/`speakerNamesRaw` are `String?`. Do NOT add them to `init(...)`; they default to nil.

- [ ] **Step 4: Run test** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(recorder): Transcription speaker segments + rename map accessors`

### Task 3: `supportsNativeDiarization` capability flag
**Files:**
- Modify: `VoiceInk/Models/TranscriptionModel.swift:47-59,115-139`
- Modify: `VoiceInk/Transcription/Cloud/ElevenLabsProvider.swift:22-42`
- Test:   `VoiceInkTests/RecorderDiarizationTests.swift`

- [ ] **Step 1: Write the failing test**
  ```swift
  func testElevenLabsModelsDeclareNativeDiarization() {
      let models = ElevenLabsProvider().models
      XCTAssertTrue(models.allSatisfy { $0.supportsNativeDiarization })
  }
  func testOtherProvidersDefaultNoNativeDiarization() {
      XCTAssertFalse(GroqProvider().models.first?.supportsNativeDiarization ?? true)
  }
  ```
  Run: expect FAIL.

- [ ] **Step 2: Run test** — Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**
  - In `TranscriptionModel` protocol (after `var supportsStreaming: Bool { get }`, line 58):
    ```swift
    var supportsNativeDiarization: Bool { get }
    ```
  - Add a default in the existing protocol extension (near line 61):
    ```swift
    extension TranscriptionModel { var supportsNativeDiarization: Bool { false } }
    ```
  - In `CloudModel` (struct fields ~line 116-125 + memberwise init ~line 127): add a stored `let supportsNativeDiarization: Bool` with an init parameter defaulting to `false`, so existing call sites compile unchanged.
  - In `ElevenLabsProvider.models` (lines 22-42): pass `supportsNativeDiarization: true` to both `CloudModel(...)` inits.
  GOTCHA: `LocalModel` and any other `TranscriptionModel` conformers inherit the extension default — no edits needed there.

- [ ] **Step 4: Run test** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(transcription): supportsNativeDiarization capability flag (ElevenLabs)`

### Task 4: ElevenLabs diarization response parsing (pure)
**Files:**
- Create: `VoiceInk/Transcription/Cloud/ElevenLabsDiarizingClient.swift` (response model + parser only in this task)
- Test:   `VoiceInkTests/RecorderDiarizationTests.swift`

- [ ] **Step 1: Write the failing test**
  ```swift
  func testParseDiarizedResponseToSegments() throws {
      let json = #"""
      { "text": "今天 開會 好的",
        "language_code": "zh",
        "words": [
          {"text":"今天","start":0.0,"end":0.4,"type":"word","speaker_id":"speaker_0"},
          {"text":" ","start":0.4,"end":0.5,"type":"spacing","speaker_id":"speaker_0"},
          {"text":"開會","start":0.5,"end":0.9,"type":"word","speaker_id":"speaker_0"},
          {"text":"好的","start":1.0,"end":1.4,"type":"word","speaker_id":"speaker_1"}
        ] }
      """#
      let parsed = try ElevenLabsDiarizingClient.parse(Data(json.utf8))
      XCTAssertEqual(parsed.text, "今天 開會 好的")
      XCTAssertEqual(parsed.segments.count, 2)
      XCTAssertEqual(parsed.segments[1].speaker, "speaker_1")
  }
  ```
  Run: expect FAIL.

- [ ] **Step 2: Run test** — Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**
  ```swift
  import Foundation

  enum ElevenLabsDiarizingError: Error { case missingAPIKey, http(Int, String), noWords }

  struct ElevenLabsDiarizingClient {
      struct Result { let text: String; let segments: [SpeakerSegment] }

      private struct Response: Decodable {
          let text: String
          let words: [Word]?
          struct Word: Decodable { let text: String; let start: Double?; let end: Double?; let type: String?; let speaker_id: String? }
      }

      /// Pure: decode the ElevenLabs diarized JSON → text + merged speaker segments.
      static func parse(_ data: Data) throws -> Result {
          let r = try JSONDecoder().decode(Response.self, from: data)
          let words = (r.words ?? []).map {
              DiarizedWord(text: $0.text, start: $0.start ?? 0, end: $0.end ?? ($0.start ?? 0),
                           speakerId: $0.speaker_id ?? "speaker_0", type: $0.type ?? "word")
          }
          return Result(text: r.text, segments: SpeakerSegment.merge(words: words))
      }
  }
  ```

- [ ] **Step 4: Run test** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(recorder): parse ElevenLabs diarized response into speaker segments`

### Task 5: ElevenLabs diarizing network call (multipart, `diarize=true`)
**Files:**
- Modify: `VoiceInk/Transcription/Cloud/ElevenLabsDiarizingClient.swift`
- (No unit test — network I/O; covered by the pure `parse` test in Task 4 and the request-builder test below.)

- [ ] **Step 1: Write the failing test** (request builder is pure → test it)
  ```swift
  func testBuildMultipartBodyIncludesDiarizeAndSpeakerCount() {
      let body = ElevenLabsDiarizingClient.multipartBody(
          boundary: "B", audio: Data("wav".utf8), fileName: "a.wav",
          model: "scribe_v2", language: "zh", numSpeakers: 3)
      let s = String(data: body, encoding: .utf8)!
      XCTAssertTrue(s.contains("name=\"diarize\"\r\n\r\ntrue"))
      XCTAssertTrue(s.contains("name=\"num_speakers\"\r\n\r\n3"))
      XCTAssertTrue(s.contains("name=\"model_id\"\r\n\r\nscribe_v2"))
      XCTAssertTrue(s.contains("name=\"language_code\"\r\n\r\nzh"))
  }
  ```
  Run: expect FAIL.

- [ ] **Step 2: Run test** — Expected: FAIL.

- [ ] **Step 3: Write minimal implementation** — add to `ElevenLabsDiarizingClient`:
  ```swift
  /// Pure multipart body builder (so it is unit-testable). `numSpeakers` nil → let the model decide.
  static func multipartBody(boundary: String, audio: Data, fileName: String,
                            model: String, language: String?, numSpeakers: Int?) -> Data {
      var body = Data()
      func field(_ name: String, _ value: String) {
          body.append("--\(boundary)\r\n".data(using: .utf8)!)
          body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
      }
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
      body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
      body.append(audio)
      body.append("\r\n".data(using: .utf8)!)
      field("model_id", model)
      field("temperature", "0.0")
      field("tag_audio_events", "false")
      field("diarize", "true")
      if let numSpeakers { field("num_speakers", String(numSpeakers)) }
      if let language, !language.isEmpty { field("language_code", language) }
      body.append("--\(boundary)--\r\n".data(using: .utf8)!)
      return body
  }

  /// Transcribe with diarization. Throws on missing key / HTTP error / empty words (→ caller degrades).
  static func transcribeDiarized(audioData: Data, fileName: String, apiKey: String,
                                 model: String, language: String?, numSpeakers: Int?,
                                 timeout: TimeInterval) async throws -> Result {
      guard !apiKey.isEmpty else { throw ElevenLabsDiarizingError.missingAPIKey }
      let boundary = "voiceink-\(UUID().uuidString)"
      var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
      req.httpMethod = "POST"
      req.timeoutInterval = timeout
      req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      req.setValue("application/json", forHTTPHeaderField: "Accept")
      req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
      let body = multipartBody(boundary: boundary, audio: audioData, fileName: fileName,
                               model: model, language: language, numSpeakers: numSpeakers)
      let (data, response) = try await URLSession.shared.upload(for: req, from: body)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          throw ElevenLabsDiarizingError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
      }
      let result = try parse(data)
      guard !result.segments.isEmpty else { throw ElevenLabsDiarizingError.noWords }
      return result
  }
  ```
  GOTCHA: `URLSession.upload(for:from:)` is async and available on macOS 12+. Match the deployment target used elsewhere; `CloudTranscriptionService` already uses async URLSession.

- [ ] **Step 4: Run test** — Expected: PASS (builder test; network path exercised manually).
- [ ] **Step 5: Commit** — `feat(recorder): in-repo ElevenLabs diarize=true client`

### Task 6: Recorder Mode diarization settings
**Files:**
- Modify: `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` (mirror lines 19,38,65,95-97 pattern)
- Test:   `VoiceInkTests/RecorderDiarizationTests.swift`

- [ ] **Step 1: Write the failing test**
  ```swift
  func testDiarizationSettingPersists() {
      let store = RecorderConfigStore.shared
      store.setRecorderDiarizationEnabled(true)
      XCTAssertTrue(store.recorderDiarizationEnabled)
      store.setRecorderExpectedSpeakerCount(3)
      XCTAssertEqual(store.recorderExpectedSpeakerCount, 3)
      store.setRecorderExpectedSpeakerCount(nil)
      XCTAssertNil(store.recorderExpectedSpeakerCount)
      store.setRecorderDiarizationEnabled(false)   // reset shared singleton
  }
  ```
  Run: expect FAIL.

- [ ] **Step 2: Run test** — Expected: FAIL.

- [ ] **Step 3: Write minimal implementation** — mirror the config-store pattern:
  ```swift
  // properties (near line 22)
  @Published private(set) var recorderDiarizationEnabled: Bool = false
  @Published private(set) var recorderExpectedSpeakerCount: Int?      // nil = let the model decide
  // keys (near line 39)
  private let recDiarizationKey = "recorderDiarizationEnabledV1"
  private let recExpectedSpeakersKey = "recorderExpectedSpeakerCountV1"
  // in load() (near line 66)
  recorderDiarizationEnabled = UserDefaults.standard.bool(forKey: recDiarizationKey)
  let sc = UserDefaults.standard.integer(forKey: recExpectedSpeakersKey)   // 0 when unset
  recorderExpectedSpeakerCount = sc > 0 ? sc : nil
  // setters (near line 104)
  func setRecorderDiarizationEnabled(_ on: Bool) {
      recorderDiarizationEnabled = on; UserDefaults.standard.set(on, forKey: recDiarizationKey)
  }
  func setRecorderExpectedSpeakerCount(_ n: Int?) {
      recorderExpectedSpeakerCount = n
      UserDefaults.standard.set(n ?? 0, forKey: recExpectedSpeakersKey)
  }
  ```

- [ ] **Step 4: Run test** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(recorder): Recorder Mode diarization settings (enable + expected speakers)`

### Task 7: `DiarizationCoordinator` (native routing + degrade)
**Files:**
- Create: `VoiceInk/Services/RecorderAutomation/DiarizationCoordinator.swift`
- Test:   `VoiceInkTests/RecorderDiarizationTests.swift`

- [ ] **Step 1: Write the failing test** (test the pure capability lookup — the network branch is not unit-tested)
  ```swift
  func testCoordinatorRecognizesNativeCapableModelByName() {
      XCTAssertTrue(DiarizationCoordinator.supportsNativeDiarization(modelName: "scribe_v2"))
      XCTAssertFalse(DiarizationCoordinator.supportsNativeDiarization(modelName: "whisper-large-v3"))
      XCTAssertFalse(DiarizationCoordinator.supportsNativeDiarization(modelName: nil))
  }
  ```
  Run: expect FAIL.

- [ ] **Step 2: Run test** — Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**
  ```swift
  import Foundation
  import os

  /// Provider-agnostic diarization entry. M1: native ElevenLabs only; non-native models return nil
  /// (graceful skip). Never throws — a failure yields nil so the plain transcript is preserved.
  @MainActor
  enum DiarizationCoordinator {
      private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")

      /// Pure lookup: is there a cloud model with this name whose provider natively diarizes?
      static func supportsNativeDiarization(modelName: String?) -> Bool {
          guard let modelName else { return false }
          for provider in CloudProviderRegistry.allProviders {
              if let m = provider.models.first(where: { $0.name == modelName }) {
                  return m.supportsNativeDiarization
              }
          }
          return false
      }

      /// Returns merged speaker segments for the audio, or nil when diarization is unavailable
      /// (non-native model in M1) or failed (API/network error → degrade to plain transcript).
      static func diarize(audioURL: URL, transcriptionModelName: String?,
                          language: String?, expectedSpeakers: Int?) async -> [SpeakerSegment]? {
          guard supportsNativeDiarization(modelName: transcriptionModelName),
                let modelName = transcriptionModelName else { return nil }
          guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: "ElevenLabs"), !apiKey.isEmpty else {
              logger.notice("Diarization skipped — no ElevenLabs API key"); return nil
          }
          guard let audioData = try? Data(contentsOf: audioURL) else { return nil }
          do {
              let result = try await ElevenLabsDiarizingClient.transcribeDiarized(
                  audioData: audioData, fileName: audioURL.lastPathComponent, apiKey: apiKey,
                  model: modelName, language: (language == "auto" ? nil : language),
                  numSpeakers: expectedSpeakers,
                  timeout: CloudTranscriptionTimeout.forAudio(audioData))
              return result.segments
          } catch {
              logger.error("Diarization failed: \(error.localizedDescription, privacy: .public)")
              return nil
          }
      }
  }
  ```
  GOTCHA: `CloudTranscriptionTimeout.forAudio` lives in `CloudProvider.swift` (already in target). `CloudProviderRegistry` too.

- [ ] **Step 4: Run test** — Expected: PASS.
- [ ] **Step 5: Commit** — `feat(recorder): DiarizationCoordinator — native routing + graceful degrade`

### Task 8: Wire diarization into `RecorderPostProcessor.process()`
**Files:**
- Modify: `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift:85-88`
- (No new unit test — orchestration; behavior covered by Tasks 1–7 seams. Manual validation below.)

- [ ] **Step 1: (No test-first — orchestration glue.)** Proceed to implement.

- [ ] **Step 2: Write minimal implementation** — at the very start of `process(...)`, before `suggestCategory`:
  ```swift
  let store = RecorderConfigStore.shared
  if store.recorderDiarizationEnabled, transcription.audioFileURL != nil {
      let url = URL(fileURLWithPath: transcription.audioFileURL!)
      if let segments = await DiarizationCoordinator.diarize(
          audioURL: url,
          transcriptionModelName: transcription.transcriptionModelName,
          language: store.recorderLanguage,
          expectedSpeakers: store.recorderExpectedSpeakerCount) {
          transcription.speakerSegments = segments   // also sets speakerLabeled = true
          try? modelContext.save()
      } else if !DiarizationCoordinator.supportsNativeDiarization(modelName: transcription.transcriptionModelName) {
          NotificationManager.shared.showNotification(
              title: "此轉錄模型尚不支援語者辨識（本地補齊為後續版本）", type: .info, duration: 4)
      }
  }
  ```
  GOTCHA: `process()` already declares `let store = RecorderConfigStore.shared` at line 86 — reuse it; don't redeclare. Insert the diarization block right after that existing line.

- [ ] **Step 3: Manual validation** — see Manual Validation checklist.
- [ ] **Step 4: Commit** — `feat(recorder): run diarization in post-processor when enabled`

### Task 9: Recorder Mode settings UI
**Files:**
- Modify: `VoiceInk/Views/Settings/RecorderModeSettingsView.swift` (add to 語音轉文字 Section ~line 32; bindings ~line 85)
- (No unit test — SwiftUI view; manual validation.)

- [ ] **Step 1: (No test-first — view code.)**

- [ ] **Step 2: Write minimal implementation** — inside the `Section("語音轉文字")` after the formatting toggle:
  ```swift
  Toggle(isOn: diarizationBinding) { Text("啟用語者辨識") }
  if store.recorderDiarizationEnabled {
      Stepper(value: expectedSpeakersBinding, in: 0...12) {
          Text(store.recorderExpectedSpeakerCount.map { "預期人數：\($0)" } ?? "預期人數：自動")
      }
      Text("僅雲端 ElevenLabs 等原生支援的模型有效；其他模型會維持純文字（本地補齊為後續版本）。")
          .font(.caption).foregroundStyle(.secondary)
  }
  ```
  and the bindings (mirror `formattingBinding`):
  ```swift
  private var diarizationBinding: Binding<Bool> {
      Binding(get: { store.recorderDiarizationEnabled }, set: { store.setRecorderDiarizationEnabled($0) })
  }
  private var expectedSpeakersBinding: Binding<Int> {
      Binding(get: { store.recorderExpectedSpeakerCount ?? 0 },
              set: { store.setRecorderExpectedSpeakerCount($0 == 0 ? nil : $0) })
  }
  ```

- [ ] **Step 3: Manual validation** — toggle appears; stepper shows 自動 at 0.
- [ ] **Step 4: Commit** — `feat(recorder): Recorder Mode diarization UI (toggle + expected speakers)`

### Task 10: Speaker-grouped rendering + rename in `RecorderHistoryView`
**Files:**
- Modify: `VoiceInk/Views/History/RecorderHistoryView.swift:456-502` (TranscriptSheet)
- (No unit test — SwiftUI; rename logic already tested in Task 2. Manual validation.)

- [ ] **Step 1: (No test-first — view code; the pure rename/display logic is covered by Task 2.)**

- [ ] **Step 2: Write minimal implementation** — in `TranscriptSheet`, branch on `transcription.speakerLabeled`:
  ```swift
  if transcription.speakerLabeled, !transcription.speakerSegments.isEmpty {
      ScrollView {
          VStack(alignment: .leading, spacing: 14) {
              ForEach(Array(transcription.speakerSegments.enumerated()), id: \.offset) { _, seg in
                  VStack(alignment: .leading, spacing: 4) {
                      HStack(spacing: 6) {
                          Text(transcription.displayName(for: seg.speaker))
                              .font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.Text.secondary)
                          Button { renameSpeakerId = seg.speaker; renameSpeakerText = transcription.displayName(for: seg.speaker); showSpeakerRename = true } label: {
                              Image(systemName: "pencil").font(.system(size: 10))
                          }.buttonStyle(.plain)
                      }
                      Text(seg.text).font(.system(size: 14)).textSelection(.enabled)
                          .frame(maxWidth: .infinity, alignment: .leading)
                  }
              }
          }.padding()
      }
      // .alert("重新命名講者", ...) with a TextField bound to renameSpeakerText;
      // on submit: transcription.renameSpeaker(renameSpeakerId, to: renameSpeakerText); try? modelContext.save()
  } else {
      MarkdownContentView(text, fontSize: 14, foregroundColor: AppTheme.Text.primary)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
  }
  ```
  Add `@State private var showSpeakerRename = false`, `@State private var renameSpeakerId = ""`, `@State private var renameSpeakerText = ""` to `TranscriptSheet`, and inject `@Environment(\.modelContext)` (or pass the existing context) for the save. MIRROR the existing rename affordance at `RecorderHistoryView.swift:360-362`.
  GOTCHA: `id: \.offset` because `SpeakerSegment` isn't `Identifiable`; two segments can share a speaker so don't key on speaker.

- [ ] **Step 3: Manual validation** — diarized transcript shows grouped blocks; rename updates all blocks of that speaker.
- [ ] **Step 4: Commit** — `feat(recorder): speaker-grouped transcript view + rename`

---

## Testing Strategy

### Unit Tests (all in `VoiceInkTests/RecorderDiarizationTests.swift`, pure-seam)

| Test | Input | Expected Output | Edge Case? |
|---|---|---|---|
| merge groups consecutive | 3×speaker_0 + 1×speaker_1 words | 2 segments, texts joined, start/end spanned | — |
| merge skips audio_event/empty | `[]`, `[audio_event]` | `[]` | ✅ empty |
| segments raw round-trip | set `speakerSegments` | decodes back; `speakerLabeled == true` | — |
| displayName rename | rename speaker_0→老闆 | "講者1" then "老闆" | — |
| capability flag | ElevenLabs vs Groq | true / false | — |
| parse diarized response | ElevenLabs JSON | text + 2 segments | — |
| multipart body | numSpeakers=3 | contains `diarize=true`, `num_speakers=3` | ✅ optional field |
| coordinator capability | "scribe_v2" / "whisper…" / nil | true / false / false | ✅ nil |
| config persist | set enabled + count | persists; nil clears | ✅ nil |

### Edge Cases Checklist
- [ ] Empty words array → no segments, `speakerLabeled` stays false
- [ ] `expectedSpeakerCount` nil → `num_speakers` omitted from request
- [ ] Non-native model + diarization on → coordinator returns nil, plain transcript kept, info notice shown (AC-6)
- [ ] Missing ElevenLabs API key → nil (degrade), no crash
- [ ] Rename to empty string → removes the override (falls back to 講者N)
- [ ] Existing (pre-migration) transcriptions → nil raw fields, render unchanged

---

## Validation Commands

> Per project memory: the host-app XCTest bundle crashes when unsigned. Build with the `make local` signing settings and disable explicit modules for the test build.

### Build (compile check)
```bash
cd "/Users/logan/Projects/Archive Project/VoiceInk"
make local
```
EXPECT: build succeeds (uses the ghost-app-safe `.local-build` dir per the `voiceink-build-verify` skill).

### Unit tests (pure-seam bundle)
```bash
cd "/Users/logan/Projects/Archive Project/VoiceInk"
xcodebuild test -scheme VoiceInk -destination 'platform=macOS' \
  -only-testing:VoiceInkTests/RecorderDiarizationTests \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO CODE_SIGNING_ALLOWED=NO | xcpretty
```
EXPECT: all `RecorderDiarizationTests` pass. (Invoke the `voiceink-build-verify` skill if signing/ghost-app issues arise.)

### Manual Validation
- [ ] Recorder Mode → enable 語者辨識, set model to ElevenLabs `scribe_v2`, import a 2-speaker meeting clip.
- [ ] 逐字稿 sheet shows 講者1 / 講者2 grouped blocks.
- [ ] Rename 講者1 → 老闆; all 講者1 blocks re-label; reopen sheet → name persists.
- [ ] Switch model to a local Whisper model, re-import → plain transcript + "尚不支援語者辨識" info notice (AC-6).

---

## Acceptance Criteria (maps to SRS)
- [ ] **AC-1** diarization off by default → transcript unchanged, `speakerLabeled == false` (Tasks 6,8)
- [ ] **AC-2** ElevenLabs native → ≥2 speakers, merged segments with start/end (Tasks 1,4,5,7,8)
- [ ] **AC-3** `expectedSpeakerCount` → `num_speakers` forwarded (Task 5)
- [ ] **AC-5** anonymous 講者N render + rename applies transcript-wide, no re-transcribe (Tasks 2,10)
- [ ] **AC-6** failure/non-native → plain transcript kept + notice, no crash (Tasks 7,8)
- [ ] **AC-4** (FluidAudio local fallback) — **deferred to M2, not in this plan**

## Completion Checklist
- [ ] Code follows discovered patterns (config store, accessor, toggle binding, pure-seam tests)
- [ ] Error handling degrades to plain transcript (never throws out of `process()`)
- [ ] Logging via `os.Logger` category `RecorderAutomation`
- [ ] New SwiftData fields optional → lightweight migration verified (old rows load)
- [ ] No hardcoded API keys; key via `APIKeyManager`
- [ ] `make local` builds; `RecorderDiarizationTests` green
- [ ] Docs: update SRS FR checkboxes for M1; note M2 (AC-4) remains

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Dedicated diarize call doubles ElevenLabs cost for diarized imports | M | M | Documented M1 deviation; M2 folds into the single transcription call |
| Long recording audio > ElevenLabs 25MB limit → diarize call fails | M | M | Coordinator catches → degrade to plain transcript + notice (AC-6) |
| `transcription.text` (main call) vs diarize call text may differ slightly | L | L | Plain view uses `text`; speaker view uses segment text; both ElevenLabs, near-identical |
| SwiftData migration on new optional fields | L | H | Fields optional + not in `init`; verify old-row load in manual test |
| ElevenLabs `words[]` schema drift (field names) | L | M | `Response.Word` fields all optional with defaults; empty → degrade |

## Notes
- **M1 deviation from SRS NFR "no extra API call"**: diarization runs as a dedicated `ElevenLabsDiarizingClient` call on the original audio file, decoupled from the (possibly chunked) main transcription. Rationale: avoids surgery on the shared chunked `AudioFileTranscriptionManager.transcribeSamples` path and cross-chunk speaker-id stitching. Folding diarization into the transcribe call is an M2 optimization. Recorded here as the plan's single deliberate deviation.
- **M2 follow-up plan** should cover: `FluidAudioDiarizer` (`OfflineDiarizerManager.process(_:)` → `DiarizationResult.segments` of `TimedSpeakerSegment{speakerId,startTimeSeconds,endTimeSeconds}`), Whisper segment-timestamp alignment (max-overlap), other native providers, and optionally single-call native folding + speaker labels in the Obsidian export.
