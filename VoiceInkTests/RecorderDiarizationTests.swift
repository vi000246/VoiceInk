import XCTest
@testable import VoiceInk

@MainActor
final class RecorderDiarizationTests: XCTestCase {

    // MARK: - Task 1: SpeakerSegment.merge
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

    // MARK: - Task 2: Transcription accessors + rename
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
        t.renameSpeaker("speaker_0", to: "   ")                    // blank clears the override
        XCTAssertEqual(t.displayName(for: "speaker_0"), "講者1")
    }

    // MARK: - Task 3: capability flag
    func testElevenLabsModelsDeclareNativeDiarization() {
        let models = ElevenLabsProvider().models
        XCTAssertFalse(models.isEmpty)
        XCTAssertTrue(models.allSatisfy { $0.supportsNativeDiarization })
    }

    func testOtherProvidersDefaultNoNativeDiarization() {
        XCTAssertFalse(GroqProvider().models.first?.supportsNativeDiarization ?? true)
    }

    // MARK: - Task 4: ElevenLabs diarized response parsing
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

    // MARK: - Task 5: multipart body builder
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

    func testBuildMultipartBodyOmitsSpeakerCountWhenNil() {
        let body = ElevenLabsDiarizingClient.multipartBody(
            boundary: "B", audio: Data("wav".utf8), fileName: "a.wav",
            model: "scribe_v2", language: nil, numSpeakers: nil)
        let s = String(data: body, encoding: .utf8)!
        XCTAssertFalse(s.contains("num_speakers"))
        XCTAssertFalse(s.contains("language_code"))
    }

    // MARK: - Task 6: config persistence
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

    // MARK: - Task 7: coordinator capability routing
    func testCoordinatorRecognizesNativeCapableModelByName() {
        XCTAssertTrue(DiarizationCoordinator.supportsNativeDiarization(modelName: "scribe_v2"))
        XCTAssertFalse(DiarizationCoordinator.supportsNativeDiarization(modelName: "whisper-large-v3"))
        XCTAssertFalse(DiarizationCoordinator.supportsNativeDiarization(modelName: nil))
    }
}
