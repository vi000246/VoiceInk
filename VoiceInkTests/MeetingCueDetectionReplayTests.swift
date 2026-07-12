import XCTest
import AVFoundation
import SwiftData
@testable import VoiceInk

/// AC-8(M2 的驗收):WAV → 分流 → fake ASR(腳本化三種 committed)→ onRemoteCommitted
/// → MeetingCopilotController → ResponseCueExtractor(fake LLM) → meeting.store。
/// 不開 Teams/Meet、不碰 CoreAudio、不打真 LLM。
/// (真實 fast model 的品質驗證在 Task 8 的 DEBUG 選單,人工執行。)
@MainActor
final class MeetingCueDetectionReplayTests: XCTestCase {

    private var tmpDir: URL!
    private let keys = ["meetingCopilotEnabledV1", "meetingCopilotShowInformationalCuesV1"]
    private var saved: [String: Any?] = [:]

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCueDetectionReplayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    /// 合成 WAV(照抄 M1 MeetingCopilotReplayTests——ASR 是 fake,要驗的是接線)。
    private func writeSineWAV(named name: String, hz: Double, seconds: Double) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let rate = 16_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = 0.5 * Float(sin(2.0 * .pi * hz * Double(i) / rate))
        }
        try file.write(from: buffer)
        return url
    }

    func testEndToEndFromWavPersistsClassifiedCues() async throws {
        let wav = try writeSineWAV(named: "remote.wav", hz: 440, seconds: 0.5)

        // 三種 committed:直接問句 / 陳述句質疑(無問號) / 純資訊。
        // 0.5s @16k、chunkFrames=1600 → 約 5 個 chunk;script 掛第 1、3 個,第三句走 finish()。
        let remoteASR = FakeMeetingTranscriptStream(
            script: [
                1: .committed(text: "你會怎麼設計一個短網址服務？"),
                3: .committed(text: "我對這個寫入效能有點擔心"),
            ],
            finalText: "我們上週上線了 v2")
        let source = ReplayMeetingAudioSource(
            remoteURL: wav, localURL: nil, speed: 50.0, chunkFrames: 1600)
        let transcriber = MeetingLiveTranscriber(
            source: source, remoteStream: remoteASR, localStream: nil)

        // fake LLM 依 user prompt 內容路由(不吃併發時序)。
        let fake = KeyedFakeChatCompleting(routes: [
            ("短網址", #"{"cues":[{"text":"你會怎麼設計一個短網址服務？","kind":"directQuestion"}]}"#),
            ("寫入效能", #"{"cues":[{"text":"我對這個寫入效能有點擔心","kind":"impliedChallenge"}]}"#),
            ("上線了 v2", #"{"cues":[{"text":"我們上週上線了 v2","kind":"informational"}]}"#),
        ])

        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(true)
        config.setShowInformationalCues(false)
        defer { config.setCopilotEnabled(false) }

        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: context)
        controller.attach(to: transcriber, appName: "replay-test")

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(800))   // replay 0.5s/50x + 餘裕(M1 同預算)
        await transcriber.stop()
        await controller.drainInflight()

        // 1. 三種 cue 全部抽出且 persist(informational 也 persist——FR-11 只是不暴露)。
        let persisted = try context.fetch(FetchDescriptor<MeetingLiveCue>())
        XCTAssertEqual(persisted.count, 3)
        XCTAssertEqual(Set(persisted.map(\.kind)),
                       [.directQuestion, .impliedChallenge, .informational])

        // 2. 陳述句質疑被偵測——umbrella AC-4 的核心。
        XCTAssertTrue(persisted.contains { $0.kind == .impliedChallenge && $0.text.contains("寫入效能") },
                      "無問號的陳述句質疑不得漏抓")

        // 3. 暴露面:informational 預設隱藏。
        XCTAssertEqual(controller.cues.count, 2)
        XCTAssertFalse(controller.cues.contains { $0.kind == .informational })

        // 4. 全部掛在同一 session(cascade 已由 MeetingLiveModelsTests 覆蓋)。
        XCTAssertTrue(persisted.allSatisfy { $0.session != nil })
        XCTAssertEqual(try context.fetch(FetchDescriptor<MeetingLiveSession>()).count, 1)

        // 5. 抽取每 committed 恰一次(三次呼叫,非串流)。
        XCTAssertEqual(fake.callCount, 3)
    }
}
