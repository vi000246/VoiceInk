import XCTest
@testable import VoiceInk

@MainActor
final class RecorderModeTests: XCTestCase {

    func testRecorderAutoExportDefaultsManual() {
        let s = RecorderConfigStore.shared
        s.setRecorderAutoExport(false)
        XCTAssertFalse(s.recorderAutoExportEnabled)
    }

    func testRecorderTranscriptionModelPersists() {
        let s = RecorderConfigStore.shared
        s.setRecorderTranscriptionModel("whisper-large-v3")
        XCTAssertEqual(s.recorderTranscriptionModelName, "whisper-large-v3")
        s.setRecorderTranscriptionModel(nil)
        XCTAssertNil(s.recorderTranscriptionModelName)
    }

    func testRecorderModeConfigUsesSelectedModelAndDisablesEnhancement() {
        let cfg = RecorderTranscriptionConfig.makeMode(
            transcriptionModelName: "whisper-large-v3", language: "auto", textFormatting: true)
        XCTAssertEqual(cfg.selectedTranscriptionModelName, "whisper-large-v3")
        XCTAssertFalse(cfg.isAIEnhancementEnabled)
        XCTAssertTrue(cfg.isTextFormattingEnabled)
        XCTAssertEqual(cfg.selectedLanguage, "auto")
    }

    func testRecorderModeConfigNilLanguageBecomesAuto() {
        let cfg = RecorderTranscriptionConfig.makeMode(
            transcriptionModelName: nil, language: nil, textFormatting: false)
        XCTAssertEqual(cfg.selectedLanguage, "auto")
        XCTAssertNil(cfg.selectedTranscriptionModelName)
    }
}
