import Foundation
import AVFoundation

/// 測試／除錯音源:從預錄音檔重播,產出與 `LiveMeetingAudioSource` **完全相同形狀**的 frame。
///
/// # 完全不碰 CoreAudio
///
/// 這是它能在 XCTest(host-app,headless 下 CoreAudio 初始化脆弱)中執行的原因,
/// 也是「不開 Teams/Meet 也能端到端驗證」這個需求的實現方式。
///
/// `AVAudioFile` 只做檔案解碼,**不會**碰 device stack —— 刻意不用 `AVAudioEngine`(那會)。
final class ReplayMeetingAudioSource: MeetingAudioSource {

    enum ReplayError: Error, LocalizedError {
        case cannotOpen(URL)
        case emptyAudio(URL)

        var errorDescription: String? {
            switch self {
            case .cannotOpen(let u): return "無法開啟音檔:\(u.lastPathComponent)"
            case .emptyAudio(let u): return "音檔沒有內容:\(u.lastPathComponent)"
            }
        }
    }

    private let remoteURL: URL
    private let localURL: URL?
    private let speed: Double
    private let chunkFrames: Int

    private var pumpTask: Task<Void, Never>?
    private let continuation: AsyncStream<MeetingAudioFrame>.Continuation
    let frames: AsyncStream<MeetingAudioFrame>

    /// - Parameters:
    ///   - remoteURL: 對方的聲音(必要)
    ///   - localURL: 我的聲音(可選;nil = 我全程沒說話)
    ///   - speed: 1.0 = 實時;>1 = 加速(測試用,讓 E2E 在數百毫秒內跑完)
    ///   - chunkFrames: 每輪吐幾個 frame(模擬 IOProc 的 buffer 大小)
    init(remoteURL: URL, localURL: URL? = nil, speed: Double = 1.0, chunkFrames: Int = 4800) {
        self.remoteURL = remoteURL
        self.localURL = localURL
        self.speed = max(0.1, speed)
        self.chunkFrames = max(1, chunkFrames)

        var cont: AsyncStream<MeetingAudioFrame>.Continuation!
        self.frames = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    func start() async throws {
        guard pumpTask == nil else { return }

        let remote = try Self.readMono(remoteURL)
        let local = try localURL.map { try Self.readMono($0) }
        let rate = remote.sampleRate

        let cont = self.continuation
        let chunk = self.chunkFrames
        let speed = self.speed

        pumpTask = Task.detached(priority: .userInitiated) {
            var offset = 0
            let total = remote.samples.count

            while !Task.isCancelled, offset < total {
                let end = min(offset + chunk, total)
                let n = end - offset

                let remoteChunk = Array(remote.samples[offset..<end])

                // local 較短時補靜音,長度永遠對齊 remote —— 模擬真實 aggregate 的
                // sample-aligned 特性(tap 與 mic 在同一個 IOProc callback 裡等長)。
                let localChunk: [Float]
                if let l = local {
                    if offset < l.samples.count {
                        let lEnd = min(offset + n, l.samples.count)
                        var c = Array(l.samples[offset..<lEnd])
                        if c.count < n {
                            c.append(contentsOf: [Float](repeating: 0, count: n - c.count))
                        }
                        localChunk = c
                    } else {
                        localChunk = [Float](repeating: 0, count: n)
                    }
                } else {
                    localChunk = []
                }

                cont.yield(MeetingAudioFrame(
                    remote: [remoteChunk],
                    local: localChunk.isEmpty ? [] : [localChunk],
                    frameCount: n,
                    sampleRate: rate
                ))

                offset = end

                // wall-clock 節奏(speed 倍速)
                let seconds = Double(n) / rate / speed
                if seconds > 0.001 {
                    try? await Task.sleep(for: .seconds(seconds))
                }
            }

            cont.finish()
        }
    }

    func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        continuation.finish()
    }

    // MARK: - 音檔讀取

    private struct MonoAudio {
        let samples: [Float]
        let sampleRate: Double
    }

    /// 讀成 mono Float32。多聲道以等權平均混音(與 `MeetingAudioMixer` 同語意)。
    private static func readMono(_ url: URL) throws -> MonoAudio {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw ReplayError.cannotOpen(url)
        }

        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw ReplayError.emptyAudio(url) }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ReplayError.cannotOpen(url)
        }
        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw ReplayError.cannotOpen(url)
        }

        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard frames > 0, channels > 0 else { throw ReplayError.emptyAudio(url) }

        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let ch = channelData[c]
            for i in 0..<frames {
                mono[i] += ch[i]
            }
        }
        if channels > 1 {
            let divisor = Float(channels)
            for i in 0..<frames { mono[i] /= divisor }
        }

        return MonoAudio(samples: mono, sampleRate: format.sampleRate)
    }
}
