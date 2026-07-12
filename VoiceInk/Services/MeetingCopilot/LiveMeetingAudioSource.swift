import Foundation
import os

/// 正式音源:從 `MeetingCaptureService` 的 realtime ring buffer 汲取,依 tap 聲道數切分。
///
/// **切分(`MeetingChannelSplitter`)與降頻(`PCMDownsampler`)都在這裡做——不在 realtime thread 上做。**
/// realtime 側(`MeetingCaptureContext.handleIO`)只負責 memcpy 進 ring slot。
final class LiveMeetingAudioSource: MeetingAudioSource {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private let ring: MeetingPCMRingBuffer
    private let tapChannelCount: Int
    private let idlePollInterval: Duration

    private var pumpTask: Task<Void, Never>?
    private let continuation: AsyncStream<MeetingAudioFrame>.Continuation
    let frames: AsyncStream<MeetingAudioFrame>

    /// - Parameters:
    ///   - ring: `MeetingCaptureService.copilotRingBuffer`(copilot 啟用時才非 nil)
    ///   - tapChannelCount: `MeetingCaptureService.copilotTapChannelCount`
    ///   - idlePollInterval: ring 空的時候的輪詢間隔。10ms 遠小於一輪 IOProc 的時間
    ///     (4096 frames @48k ≈ 85ms),不會成為延遲瓶頸。
    init(
        ring: MeetingPCMRingBuffer,
        tapChannelCount: Int,
        idlePollInterval: Duration = .milliseconds(10)
    ) {
        self.ring = ring
        self.tapChannelCount = tapChannelCount
        self.idlePollInterval = idlePollInterval

        var cont: AsyncStream<MeetingAudioFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        self.continuation = cont
    }

    func start() async throws {
        guard pumpTask == nil else { return }

        if !MeetingChannelLayout.isVerified {
            logger.warning("🎧 MeetingChannelLayout.tapFirst 尚未實機量測 — remote/local 可能顛倒。見 MeetingChannelLayout 的量測步驟。")
        }

        let ring = self.ring
        let tapCount = self.tapChannelCount
        let interval = self.idlePollInterval
        let cont = self.continuation
        let tapFirst = MeetingChannelLayout.tapFirst

        pumpTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                var drainedAny = false

                while let slot = ring.read() {
                    drainedAny = true

                    let split = MeetingChannelSplitter.split(
                        channelBuffers: slot.channelBuffers,
                        tapChannelCount: tapCount,
                        tapFirst: tapFirst
                    )

                    cont.yield(MeetingAudioFrame(
                        remote: split.remote,
                        local: split.local,
                        frameCount: slot.frameCount,
                        sampleRate: slot.sampleRate
                    ))
                }

                if !drainedAny {
                    try? await Task.sleep(for: interval)
                }
            }
            cont.finish()
        }
    }

    func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        continuation.finish()

        let drops = ring.droppedBreakdown
        if drops.backpressure > 0 || drops.capacity > 0 {
            logger.warning("🎧 copilot ring drops — backpressure=\(drops.backpressure, privacy: .public) capacity=\(drops.capacity, privacy: .public)")
        }
    }
}
