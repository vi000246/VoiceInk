import XCTest
@testable import VoiceInk

@MainActor
final class RecorderDiarizationM2Tests: XCTestCase {

    func testNonNativeModelStaysNonNativeAndElevenLabsNative() {
        XCTAssertFalse(DiarizationCoordinator.supportsNativeDiarization(modelName: "large-v3-turbo"))
        XCTAssertTrue(DiarizationCoordinator.supportsNativeDiarization(modelName: "scribe_v2"))
    }

    /// Regression: the transcription pipeline stores `model.displayName` ("Scribe V2"), not the
    /// internal id, so native diarization must resolve by displayName too — otherwise it silently
    /// skips diarization.
    func testNativeResolvesByDisplayNameAndYieldsApiModelId() {
        XCTAssertTrue(DiarizationCoordinator.supportsNativeDiarization(modelName: "Scribe V2"))
        // The resolved model must expose the API's model_id ("scribe_v2"), never the displayName.
        XCTAssertEqual(DiarizationCoordinator.nativeModel(matching: "Scribe V2")?.name, "scribe_v2")
        XCTAssertEqual(DiarizationCoordinator.nativeModel(matching: "scribe_v2")?.name, "scribe_v2")
        XCTAssertNil(DiarizationCoordinator.nativeModel(matching: "large-v3-turbo"))
    }

    /// The recorder is hardcoded to ElevenLabs Scribe V2, which diarizes natively — so the single
    /// source-of-truth constant must resolve to a native-diarization model.
    func testRecorderFixedModelIsNativeDiarizing() {
        XCTAssertEqual(RecorderTranscriptionConfig.transcriptionModelName, "scribe_v2")
        XCTAssertTrue(DiarizationCoordinator.supportsNativeDiarization(
            modelName: RecorderTranscriptionConfig.transcriptionModelName))
    }

    /// detect_speaker_roles is only emitted when explicitly enabled (default off = no surcharge).
    func testMultipartBodyEmitsDetectSpeakerRolesOnlyWhenEnabled() {
        func bodyString(detectRoles: Bool) -> String {
            let data = ElevenLabsDiarizingClient.multipartBody(
                boundary: "b", audio: Data([0x1]), fileName: "a.wav",
                model: "scribe_v2", language: nil, numSpeakers: nil, detectSpeakerRoles: detectRoles)
            return String(data: data, encoding: .utf8) ?? ""
        }
        XCTAssertTrue(bodyString(detectRoles: true).contains("detect_speaker_roles"))
        XCTAssertFalse(bodyString(detectRoles: false).contains("detect_speaker_roles"))
    }

    /// no_verbatim is emitted only when enabled, and the plain client never sends diarize.
    func testScribeClientEmitsNoVerbatimOnlyWhenEnabled() {
        func bodyString(noVerbatim: Bool) -> String {
            let data = ElevenLabsScribeClient.multipartBody(
                boundary: "b", audio: Data([0x1]), fileName: "a.wav",
                model: "scribe_v2", language: nil, noVerbatim: noVerbatim)
            return String(data: data, encoding: .utf8) ?? ""
        }
        XCTAssertTrue(bodyString(noVerbatim: true).contains("no_verbatim"))
        XCTAssertFalse(bodyString(noVerbatim: false).contains("no_verbatim"))
        XCTAssertFalse(bodyString(noVerbatim: true).contains("diarize"))
    }
}
