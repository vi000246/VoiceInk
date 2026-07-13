import XCTest
import AVFoundation
@testable import VoiceInk

/// FR-25 接點:local 聲道的 RMS 經 onLocalLevel 回報(給 overlay 淡出用)。
/// 沿用 M1 replay harness——不開 Teams、不碰 CoreAudio。
@MainActor
final class MeetingLocalLevelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingLocalLevelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeSineWAV(named name: String, amplitude: Float, seconds: Double = 0.5) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let rate = 16_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = amplitude * Float(sin(2.0 * .pi * 440.0 * Double(i) / rate))
        }
        try file.write(from: buffer)
        return url
    }

    /// local 有聲音 → onLocalLevel 回報正能量(可觸發淡出)。
    func testOnLocalLevelReportsPositiveRMSWhileSpeaking() async throws {
        let remoteWAV = try writeSineWAV(named: "remote.wav", amplitude: 0.0)
        let localWAV  = try writeSineWAV(named: "local.wav",  amplitude: 0.5)

        let source = ReplayMeetingAudioSource(remoteURL: remoteWAV, localURL: localWAV, speed: 50.0, chunkFrames: 1600)
        let transcriber = MeetingLiveTranscriber(
            source: source,
            remoteStream: FakeMeetingTranscriptStream(),
            localStream: FakeMeetingTranscriptStream()
        )

        let levels = LevelCollector()
        transcriber.onLocalLevel = { levels.append($0) }

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(800))
        await transcriber.stop()

        XCTAssertFalse(levels.values.isEmpty, "local 有聲道,必須有 RMS 回報")
        XCTAssertGreaterThan(levels.values.max() ?? 0, 0.1)
    }

    /// local 靜音 + localStream=nil(ASR 關) → RMS 回報照常,且全低於門檻。
    func testSilentLocalReportsNearZeroRMS() async throws {
        let remoteWAV = try writeSineWAV(named: "remote2.wav", amplitude: 0.5)
        let localWAV  = try writeSineWAV(named: "silent.wav",  amplitude: 0.0)

        let source = ReplayMeetingAudioSource(remoteURL: remoteWAV, localURL: localWAV, speed: 50.0, chunkFrames: 1600)
        let transcriber = MeetingLiveTranscriber(
            source: source,
            remoteStream: FakeMeetingTranscriptStream(),
            localStream: nil          // ASR 關閉 —— RMS 回報必須照常
        )

        let levels = LevelCollector()
        transcriber.onLocalLevel = { levels.append($0) }

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(800))
        await transcriber.stop()

        XCTAssertFalse(levels.values.isEmpty, "localStream=nil 時 RMS 回報必須照常(淡出與 ASR 解耦)")
        XCTAssertLessThan(levels.values.max() ?? 1, 0.02, "靜音不得超過淡出門檻")
    }
}

/// onLocalLevel 在 MainActor 上呼叫；收集器為 @MainActor 避免資料競爭。
@MainActor
private final class LevelCollector {
    private(set) var values: [Float] = []
    func append(_ v: Float) { values.append(v) }
}
