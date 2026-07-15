import XCTest
import AVFoundation
@testable import VoiceInk

/// **M1 的驗收**:不開 Teams/Meet、不碰 CoreAudio,用預錄 WAV 端到端驅動整條 pipeline。
///
/// 驗的是**接線正確性**:
///   ReplayMeetingAudioSource → (切分好的 remote/local) → PCMDownsampler → 雙路 ASR
///   → 講者歸屬 → 逐字稿
///
/// ASR 用 `FakeMeetingTranscriptStream`(腳本化事件)。**為什麼不用真的 FluidAudio**:
/// 見 `FakeMeetingTranscriptStream` 的說明——host-app 測試 + CoreAudio headless 脆弱 +
/// CoreML 模型需下載 + 全 repo 無 Bundle fixture 先例。真實 ASR 的驗證在 `#if DEBUG`
/// 選單(Task 13),由人工執行。
@MainActor
final class MeetingCopilotReplayTests: XCTestCase {

    /// 每個測試一份 in-memory 設定後端（見 TestDefaults.swift）——測試不得碰 `.standard`。
    private let defaultsSuite = InMemoryDefaults()

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCopilotReplayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    // MARK: - Fixtures(合成,不進 bundle)

    /// 合成一個 WAV:指定取樣率的 mono 正弦波。
    ///
    /// 測試不需要「真的語音」—— ASR 是 fake,要驗的是**接線**,不是辨識準確度。
    @discardableResult
    private func writeSineWAV(
        named name: String,
        hz: Double = 440,
        seconds: Double,
        sampleRate: Double = 16_000,
        amplitude: Float = 0.5
    ) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw XCTSkip("無法建立 AVAudioFormat")
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frames = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw XCTSkip("無法建立 AVAudioPCMBuffer")
        }
        buffer.frameLength = frames

        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = amplitude * Float(sin(2.0 * .pi * hz * Double(i) / sampleRate))
        }

        try file.write(from: buffer)
        return url
    }

    // MARK: - AC-14(音訊半部):講者歸屬

    /// **M1 的核心斷言**:remote 與 local 兩條音訊各自流到**自己的**轉錄流,
    /// committed 文字落到**正確的講者欄位**。
    ///
    /// 這就是「講者歸屬零成本、免 diarization」的證明。
    func testEndToEndReplayRoutesRemoteAndLocalToSeparateStreams() async throws {
        let remoteWAV = try writeSineWAV(named: "remote.wav", hz: 440, seconds: 0.5)
        let localWAV = try writeSineWAV(named: "local.wav", hz: 880, seconds: 0.5)

        let source = ReplayMeetingAudioSource(
            remoteURL: remoteWAV,
            localURL: localWAV,
            speed: 50.0,        // 加速 —— 0.5s 音檔在 ~10ms 內跑完
            chunkFrames: 1600   // 0.1s @16kHz
        )

        let remoteASR = FakeMeetingTranscriptStream(finalText: "你會怎麼設計一個短網址服務？")
        let localASR = FakeMeetingTranscriptStream(finalText: "我先釐清一下需求。")

        let transcriber = MeetingLiveTranscriber(
            source: source,
            remoteStream: remoteASR,
            localStream: localASR
        )

        // M2 的接點:每則 remote committed 都會觸發。
        var cues: [String] = []
        transcriber.onRemoteCommitted = { cues.append($0) }

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(800))
        await transcriber.stop()

        // 1. 兩條流都真的收到音訊
        XCTAssertGreaterThan(remoteASR.receivedBytes, 0, "remote 音訊沒有流到 ASR")
        XCTAssertGreaterThan(localASR.receivedBytes, 0, "local 音訊沒有流到 ASR")

        // 2. 位元組量級正確:0.5s @16kHz mono Int16 = 8000 frames × 2 bytes = 16000 bytes
        XCTAssertEqual(Double(remoteASR.receivedBytes), 16_000, accuracy: 2_000)
        XCTAssertEqual(Double(localASR.receivedBytes), 16_000, accuracy: 2_000)

        // 3. ★ 講者歸屬正確 —— M1 的全部意義
        XCTAssertEqual(transcriber.remoteTranscript, "你會怎麼設計一個短網址服務？")
        XCTAssertEqual(transcriber.localTranscript, "我先釐清一下需求。")

        // 4. remote committed 觸發了回呼(M2 的 cue 抽取會掛在這)
        XCTAssertEqual(cues, ["你會怎麼設計一個短網址服務？"])
    }

    /// 兩條流不得互相污染:remote 的文字絕不能出現在 localTranscript,反之亦然。
    func testStreamsDoNotCrossContaminate() async throws {
        let remoteWAV = try writeSineWAV(named: "r.wav", seconds: 0.3)
        let localWAV = try writeSineWAV(named: "l.wav", seconds: 0.3)

        let source = ReplayMeetingAudioSource(
            remoteURL: remoteWAV, localURL: localWAV, speed: 50.0, chunkFrames: 1600
        )
        let remoteASR = FakeMeetingTranscriptStream(finalText: "REMOTE_ONLY")
        let localASR = FakeMeetingTranscriptStream(finalText: "LOCAL_ONLY")

        let transcriber = MeetingLiveTranscriber(
            source: source, remoteStream: remoteASR, localStream: localASR
        )

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(600))
        await transcriber.stop()

        XCTAssertFalse(transcriber.remoteTranscript.contains("LOCAL_ONLY"), "local 文字污染了 remote")
        XCTAssertFalse(transcriber.localTranscript.contains("REMOTE_ONLY"), "remote 文字污染了 local")
        XCTAssertEqual(transcriber.remoteTranscript, "REMOTE_ONLY")
        XCTAssertEqual(transcriber.localTranscript, "LOCAL_ONLY")
    }

    // MARK: - 麥克風關閉

    /// `transcribeLocalMic = false`(localStream = nil)→ 只有 remote 流,不崩。
    func testReplayWithoutLocalStream() async throws {
        let remoteWAV = try writeSineWAV(named: "remote_only.wav", seconds: 0.3)

        let source = ReplayMeetingAudioSource(
            remoteURL: remoteWAV, localURL: nil, speed: 50.0, chunkFrames: 1600
        )
        let remoteASR = FakeMeetingTranscriptStream(finalText: "只有對方在說話")

        let transcriber = MeetingLiveTranscriber(
            source: source, remoteStream: remoteASR, localStream: nil
        )

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(600))
        await transcriber.stop()

        XCTAssertGreaterThan(remoteASR.receivedBytes, 0)
        XCTAssertEqual(transcriber.remoteTranscript, "只有對方在說話")
        XCTAssertTrue(transcriber.localTranscript.isEmpty)
    }

    // MARK: - 降頻

    /// 48kHz 來源 → 送給 ASR 的必須是 16kHz 的量(1 秒 = 32000 bytes)。
    func testDownsamplesFrom48kSource() async throws {
        let remoteWAV = try writeSineWAV(
            named: "remote48k.wav", seconds: 1.0, sampleRate: 48_000
        )

        let source = ReplayMeetingAudioSource(
            remoteURL: remoteWAV, localURL: nil, speed: 100.0, chunkFrames: 4800
        )
        let remoteASR = FakeMeetingTranscriptStream()

        let transcriber = MeetingLiveTranscriber(
            source: source, remoteStream: remoteASR, localStream: nil
        )

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(700))
        await transcriber.stop()

        // 1 秒 @16kHz mono Int16 = 16000 frames × 2 bytes = 32000 bytes
        // (線性插值在每個 chunk 的邊界會有些微出入,故給容忍)
        XCTAssertEqual(Double(remoteASR.receivedBytes), 32_000, accuracy: 3_000)
    }

    // MARK: - 事件轉發

    /// partial 事件必須即時反映到 `remotePartial`,並在 committed 後清空。
    func testPartialEventsAreForwardedThenClearedOnCommit() async throws {
        let remoteWAV = try writeSineWAV(named: "partials.wav", seconds: 0.5)

        let source = ReplayMeetingAudioSource(
            remoteURL: remoteWAV, localURL: nil, speed: 50.0, chunkFrames: 1600
        )
        // 第 2 個 chunk 時吐一則 partial
        let remoteASR = FakeMeetingTranscriptStream(
            script: [2: .partial(text: "你會怎麼設計")],
            finalText: "你會怎麼設計一個短網址服務？"
        )

        let transcriber = MeetingLiveTranscriber(
            source: source, remoteStream: remoteASR, localStream: nil
        )

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(800))
        await transcriber.stop()

        // committed 之後 partial 必須被清空(否則 UI 會同時顯示兩份)
        XCTAssertTrue(transcriber.remotePartial.isEmpty, "committed 後 partial 應清空")
        XCTAssertEqual(transcriber.remoteTranscript, "你會怎麼設計一個短網址服務？")
    }

    /// 多則 committed 必須以空白串接累積。
    func testMultipleCommitsAccumulate() async throws {
        let remoteWAV = try writeSineWAV(named: "multi.wav", seconds: 0.5)

        let source = ReplayMeetingAudioSource(
            remoteURL: remoteWAV, localURL: nil, speed: 50.0, chunkFrames: 800
        )
        let remoteASR = FakeMeetingTranscriptStream(
            script: [
                2: .committed(text: "第一句。"),
                4: .committed(text: "第二句。"),
            ],
            finalText: "第三句。"
        )

        let transcriber = MeetingLiveTranscriber(
            source: source, remoteStream: remoteASR, localStream: nil
        )

        var cues: [String] = []
        transcriber.onRemoteCommitted = { cues.append($0) }

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(800))
        await transcriber.stop()

        XCTAssertEqual(transcriber.remoteTranscript, "第一句。 第二句。 第三句。")
        XCTAssertEqual(cues, ["第一句。", "第二句。", "第三句。"])
    }

    // MARK: - 音源錯誤

    /// 檔案不存在 → start() 拋錯,不崩。
    func testMissingFileThrows() async throws {
        let missing = tmpDir.appendingPathComponent("does_not_exist.wav")
        let source = ReplayMeetingAudioSource(remoteURL: missing)

        do {
            try await source.start()
            XCTFail("應該要拋錯")
        } catch {
            // 預期
        }
    }

    // MARK: - 設定

    /// copilot 總開關**預設開啟**(2026-07-13 依使用者要求翻轉,見 `MeetingCopilotConfigStore`
    /// 的 `copilotEnabled` 註解:「會議錄製時預設就開啟即時監聽,不必每次手動開」)。
    ///
    /// FR-3 的「零影響」保證不靠這個預設值成立,而是靠 **關閉時的路徑**:`copilotEnabled == false`
    /// 時 `MeetingCaptureService` 不建 ring buffer、`pcmSink` 為 nil,realtime thread 的 seam
    /// 只剩一次 nil 檢查 —— 零 ASR、零 LLM、零成本。所以預設開不開是產品取捨,不是安全紅線。
    func testConfigStoreDefaultsToEnabled() {
        // 後端是 in-memory（起點必定空）→ 不必再手動備份/清掉 `.standard` 的 key。
        // 原本那套 bracket 反而是紅燈的來源:它**寫**全域 domain，會跨 process 汙染其他測試。
        let key = "meetingCopilotEnabledV1"
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)

        XCTAssertTrue(store.copilotEnabled, "未設定 → 預設開啟")
        XCTAssertTrue(store.transcribeLocalMic, "預設轉錄我的麥克風")
        XCTAssertFalse(store.asrModelName.isEmpty)

        // 寫**與預設相反**的值才鎖得住 persist:寫 true 再讀 true,連「根本沒寫進去」都會通過。
        store.setCopilotEnabled(false)
        XCTAssertEqual(defaultsSuite.object(forKey: key) as? Bool, false,
                       "關閉必須寫進設定後端(而不是退回預設的 true)")
    }
}
