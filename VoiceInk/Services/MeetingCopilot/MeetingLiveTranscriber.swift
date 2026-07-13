import Foundation
import os

/// 把一個 `MeetingAudioSource` 接到**兩條**轉錄流:remote(對方)與 local(我)。
///
/// # 這是 M1 的交付核心
///
/// **講者歸屬 = 事件從哪條流出來。** 零 diarization、零成本、100% 準確。
///
/// 資料流:
/// ```
/// MeetingAudioSource.frames        (已由 MeetingChannelSplitter 切好)
///   ├─ frame.remote → PCMDownsampler → 16k mono Int16 → remoteStream.send()
///   └─ frame.local  → PCMDownsampler → 16k mono Int16 → localStream.send()
///
/// remoteStream.events → .committed → remoteTranscript += …
///                                  → onRemoteCommitted(text)   ← M2 的 cue 抽取掛這裡
/// localStream.events  → .committed → localTranscript += …
/// ```
@MainActor
final class MeetingLiveTranscriber: ObservableObject {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private let source: MeetingAudioSource
    private let remoteStream: MeetingTranscriptStream
    private let localStream: MeetingTranscriptStream?

    private var pumpTask: Task<Void, Never>?
    private var remoteEventTask: Task<Void, Never>?
    private var localEventTask: Task<Void, Never>?
    private var isRunning = false

    // MARK: - 觀察狀態

    /// 對方的逐字稿(累積的 committed)。
    @Published private(set) var remoteTranscript: String = ""
    /// 我的逐字稿(累積的 committed)。
    @Published private(set) var localTranscript: String = ""
    /// 對方的未定稿(partial),供 UI 即時顯示。
    @Published private(set) var remotePartial: String = ""
    /// 我的未定稿(partial)。
    @Published private(set) var localPartial: String = ""

    /// 每當**對方**有一段 committed 文字時呼叫。
    ///
    /// **這是 M2 的接點** —— `ResponseCueExtractor`(偵測「需要我回應的東西」)直接掛在這裡。
    var onRemoteCommitted: ((String) -> Void)?

    /// 每個含 local 聲道的音訊 frame 的 RMS。**M4 overlay 說話淡出的接點**(FR-25)。
    ///
    /// - 在 `start()` **之前**設定(pump 啟動時拷貝一份 closure)。
    /// - 與 `localStream`(ASR)無關:`transcribeLocalMic` 關閉時照樣回報——
    ///   淡出保護不因省 ASR 而失效。
    /// - 於 MainActor 上呼叫。
    var onLocalLevel: ((Float) -> Void)?

    // MARK: - Init

    init(
        source: MeetingAudioSource,
        remoteStream: MeetingTranscriptStream,
        localStream: MeetingTranscriptStream?
    ) {
        self.source = source
        self.remoteStream = remoteStream
        self.localStream = localStream
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        try await remoteStream.start()
        try await localStream?.start()

        startEventConsumers()

        try await source.start()
        startAudioPump()
    }

    private func startAudioPump() {
        let source = self.source
        let remote = self.remoteStream
        let local = self.localStream
        let onLocalLevel = self.onLocalLevel

        pumpTask = Task.detached(priority: .userInitiated) {
            for await frame in source.frames {
                if Task.isCancelled { break }

                // 我在說話的能量 → overlay 淡出(M4)。與 local ASR 是否啟用無關。
                if let onLocalLevel, !frame.local.isEmpty {
                    let rms = OverlayDimmingModel.rms(
                        channelBuffers: frame.local,
                        frameCount: frame.frameCount)
                    Task { @MainActor in onLocalLevel(rms) }
                }

                // 對方 → 降頻 → 送 remote ASR
                if !frame.remote.isEmpty {
                    let data = PCMDownsampler.pcm16Data(
                        channelBuffers: frame.remote,
                        frameCount: frame.frameCount,
                        inputSampleRate: frame.sampleRate
                    )
                    if !data.isEmpty {
                        remote.send(data)
                    }
                }

                // 我 → 降頻 → 送 local ASR(若啟用)
                if let local, !frame.local.isEmpty {
                    let data = PCMDownsampler.pcm16Data(
                        channelBuffers: frame.local,
                        frameCount: frame.frameCount,
                        inputSampleRate: frame.sampleRate
                    )
                    if !data.isEmpty {
                        local.send(data)
                    }
                }
            }
        }
    }

    private func startEventConsumers() {
        remoteEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.remoteStream.events {
                switch event {
                case .sessionStarted:
                    break

                case .partial(let text):
                    self.remotePartial = text

                case .committed(let text):
                    guard !text.isEmpty else { continue }
                    self.remoteTranscript += (self.remoteTranscript.isEmpty ? "" : " ") + text
                    self.remotePartial = ""
                    self.onRemoteCommitted?(text)     // ← M2 的接點

                case .error(let error):
                    // 失敗必須靜默 —— 分享螢幕時任何 modal / 系統通知都會暴露本功能的存在。
                    self.logger.error("🎧 remote ASR error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        guard let localStream else { return }
        localEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in localStream.events {
                switch event {
                case .sessionStarted:
                    break

                case .partial(let text):
                    self.localPartial = text

                case .committed(let text):
                    guard !text.isEmpty else { continue }
                    self.localTranscript += (self.localTranscript.isEmpty ? "" : " ") + text
                    self.localPartial = ""

                case .error(let error):
                    self.logger.error("🎧 local ASR error: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        await source.stop()

        pumpTask?.cancel()
        pumpTask = nil

        // finish() 會吐出最後一則 committed(若有)—— 必須在取消 event consumer **之前**,
        // 否則最後一段逐字稿會被丟掉。
        await remoteStream.finish()
        await localStream?.finish()

        // 給 event consumer 一點時間把 finish() 吐出的 committed 收完。
        try? await Task.sleep(for: .milliseconds(50))

        remoteEventTask?.cancel()
        remoteEventTask = nil
        localEventTask?.cancel()
        localEventTask = nil
    }
}
