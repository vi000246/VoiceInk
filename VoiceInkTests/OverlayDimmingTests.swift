import XCTest
@testable import VoiceInk

/// AC-17:我說話時淡出至 speakingOpacity;停止說話 1.5 秒後恢復 1.0。
/// 以合成 RMS 序列驅動,不碰 UI、不碰 timer。
final class OverlayDimmingTests: XCTestCase {

    func testDimsWhileLocalStreamActive() {
        var model = OverlayDimmingModel(speakingOpacity: 0.35)
        XCTAssertEqual(model.update(rms: 0.5, at: 0.0), 0.35, accuracy: 1e-9)
        XCTAssertEqual(model.update(rms: 0.3, at: 0.5), 0.35, accuracy: 1e-9)
    }

    func testRecoversAfterOnePointFiveSecondsOfSilence() {
        var model = OverlayDimmingModel(speakingOpacity: 0.35)
        _ = model.update(rms: 0.5, at: 0.0)
        XCTAssertEqual(model.update(rms: 0.0, at: 1.49), 0.35, accuracy: 1e-9)
        XCTAssertEqual(model.update(rms: 0.0, at: 1.51), 1.0, accuracy: 1e-9)
    }

    func testContinuedSpeechKeepsResettingTheClock() {
        var model = OverlayDimmingModel(speakingOpacity: 0.35)
        _ = model.update(rms: 0.5, at: 0.0)
        _ = model.update(rms: 0.5, at: 1.4)
        XCTAssertEqual(model.update(rms: 0.0, at: 2.8), 0.35, accuracy: 1e-9, "距最後說話 1.4s,未滿 1.5s")
        XCTAssertEqual(model.update(rms: 0.0, at: 3.0), 1.0, accuracy: 1e-9, "距最後說話 1.6s,恢復")
    }

    func testBelowThresholdNoiseDoesNotDim() {
        var model = OverlayDimmingModel(speakingOpacity: 0.35)
        XCTAssertEqual(model.update(rms: 0.005, at: 0.0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(model.update(rms: 0.019, at: 1.0), 1.0, accuracy: 1e-9)
    }

    func testRMSOfKnownSignal() {
        let rms = OverlayDimmingModel.rms(channelBuffers: [[0.5, 0.5, 0.5, 0.5]], frameCount: 4)
        XCTAssertEqual(rms, 0.5, accuracy: 1e-5)
    }

    func testRMSOfSilenceAndEmptyInput() {
        XCTAssertEqual(OverlayDimmingModel.rms(channelBuffers: [[0, 0, 0]], frameCount: 3), 0.0, accuracy: 1e-9)
        XCTAssertEqual(OverlayDimmingModel.rms(channelBuffers: [], frameCount: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(OverlayDimmingModel.rms(channelBuffers: [[1]], frameCount: 4), 0.0, accuracy: 1e-9, "frameCount 超出樣本數 → 0,不越界")
    }
}
