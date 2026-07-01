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

    func testNonNativeModelStaysNonNativeAndElevenLabsNative() {
        XCTAssertFalse(DiarizationCoordinator.supportsNativeDiarization(modelName: "large-v3-turbo"))
        XCTAssertTrue(DiarizationCoordinator.supportsNativeDiarization(modelName: "scribe_v2"))
    }
}
