import Foundation

/// Float32 多聲道 interleaved → **mono 16kHz Int16 LE**。
/// 純函式,由聽寫路徑（`CoreAudioRecorder`）與 meeting-copilot 共用。
///
/// # ⚠️ 行為逐字抽自 `CoreAudioRecorder.convertAndWriteToFile`
///
/// 包含它的線性插值寫法。**不要「順手修正」任何一行**——`PCMDownsamplerTests` 鎖的就是
/// 位元等價,而聽寫路徑依賴這個確切行為。
///
/// # 為什麼核心是 pointer-based
///
/// `CoreAudioRecorder` 在 `audioProcessingQueue` 上已經持有 `UnsafeMutablePointer<Float32>`
/// 與預配置的輸出緩衝。若核心只提供 `[Float]` 版,那條每個 buffer 都會多一次配置＋複製
/// （聽寫熱路徑上的真實回歸）。因此核心寫成零配置的指標版,array 版只是給
/// meeting consumer 與測試用的便利包裝。
///
/// # 執行緒
///
/// 這些函式**不是 realtime-safe**（array 版會配置）。
/// - `CoreAudioRecorder` 在 `audioProcessingQueue` 上呼叫（非 realtime）→ OK
/// - meeting-copilot 在 ring buffer 的 consumer task 上呼叫（非 realtime）→ OK
/// - **絕不可**在 HAL IOProc（`MeetingCaptureContext.handleIO`）上呼叫。
enum PCMDownsampler {

    /// 串流轉錄要求的取樣率（見 `StreamingTranscriptionProvider.sendAudioChunk` 的契約:
    /// 16-bit, 16kHz, mono, little-endian）。
    static let streamingSampleRate: Double = 16_000

    /// 零配置核心:寫進呼叫端提供的輸出緩衝,回傳實際寫入的 frame 數。
    ///
    /// - Parameters:
    ///   - interleaved: 輸入樣本（interleaved,`frameCount * channels` 個 Float32）
    ///   - frameCount: 輸入 frame 數
    ///   - channels: 輸入聲道數
    ///   - inputSampleRate: 輸入取樣率
    ///   - outputSampleRate: 輸出取樣率
    ///   - out: 輸出緩衝,容量至少 `outputFrameCount(...)`
    ///   - outCapacity: `out` 的容量（防越界）
    /// - Returns: 實際寫入的 frame 數;參數非法或容量不足時回傳 0。
    @discardableResult
    static func convert(
        interleaved: UnsafePointer<Float32>,
        frameCount: Int,
        channels: Int,
        inputSampleRate: Double,
        outputSampleRate: Double,
        out: UnsafeMutablePointer<Int16>,
        outCapacity: Int
    ) -> Int {
        guard frameCount > 0, channels > 0, inputSampleRate > 0, outputSampleRate > 0 else { return 0 }

        let ratio = outputSampleRate / inputSampleRate
        let outputFrameCount = Int(Double(frameCount) * ratio)
        guard outputFrameCount > 0, outputFrameCount <= outCapacity else { return 0 }

        if inputSampleRate == outputSampleRate {
            // SOURCE: CoreAudioRecorder.swift:940-952 —— 同取樣率,只做聲道混音 + Int16 轉換。
            for i in 0..<frameCount {
                var sample: Float32 = 0
                for ch in 0..<channels {
                    sample += interleaved[i * channels + ch]
                }
                sample /= Float32(channels)

                let scaled = sample * 32767.0
                let clipped = max(-32768.0, min(32767.0, scaled))
                out[i] = Int16(clipped)
            }
        } else {
            // SOURCE: CoreAudioRecorder.swift:955-977 —— 線性插值,逐字保留。
            for i in 0..<outputFrameCount {
                let inputIndex = Double(i) / ratio
                let inputIndexInt = Int(inputIndex)
                let frac = Float32(inputIndex - Double(inputIndexInt))

                var sample: Float32 = 0
                let idx1 = min(inputIndexInt, frameCount - 1)
                let idx2 = min(inputIndexInt + 1, frameCount - 1)

                for ch in 0..<channels {
                    let s1 = interleaved[idx1 * channels + ch]
                    let s2 = interleaved[idx2 * channels + ch]
                    sample += s1 + frac * (s2 - s1)
                }
                sample /= Float32(channels)

                let scaled = sample * 32767.0
                let clipped = max(-32768.0, min(32767.0, scaled))
                out[i] = Int16(clipped)
            }
        }

        return outputFrameCount
    }

    /// 給定輸入,輸出會有幾個 frame。（與核心的計算完全一致,供呼叫端配置緩衝。）
    static func outputFrameCount(
        frameCount: Int,
        inputSampleRate: Double,
        outputSampleRate: Double
    ) -> Int {
        guard frameCount > 0, inputSampleRate > 0, outputSampleRate > 0 else { return 0 }
        return Int(Double(frameCount) * (outputSampleRate / inputSampleRate))
    }

    // MARK: - Array 便利版（測試 / meeting consumer 用;會配置）

    static func toMono16kInt16(
        interleaved: [Float],
        frameCount: Int,
        channels: Int,
        inputSampleRate: Double,
        outputSampleRate: Double = streamingSampleRate
    ) -> [Int16] {
        guard frameCount > 0, channels > 0,
              interleaved.count >= frameCount * channels else { return [] }

        let outCount = outputFrameCount(
            frameCount: frameCount,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )
        guard outCount > 0 else { return [] }

        var out = [Int16](repeating: 0, count: outCount)
        let written = interleaved.withUnsafeBufferPointer { src -> Int in
            guard let base = src.baseAddress else { return 0 }
            return out.withUnsafeMutableBufferPointer { dst -> Int in
                guard let dstBase = dst.baseAddress else { return 0 }
                return convert(
                    interleaved: base,
                    frameCount: frameCount,
                    channels: channels,
                    inputSampleRate: inputSampleRate,
                    outputSampleRate: outputSampleRate,
                    out: dstBase,
                    outCapacity: outCount
                )
            }
        }
        guard written == outCount else { return [] }
        return out
    }

    /// 直接產出串流 provider 要的 `Data`（16-bit little-endian）。
    static func pcm16Data(
        interleaved: [Float],
        frameCount: Int,
        channels: Int,
        inputSampleRate: Double,
        outputSampleRate: Double = streamingSampleRate
    ) -> Data {
        let samples = toMono16kInt16(
            interleaved: interleaved,
            frameCount: frameCount,
            channels: channels,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )
        guard !samples.isEmpty else { return Data() }

        var le = samples.map { $0.littleEndian }
        return le.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    }

    /// 從**逐聲道**（deinterleave 後）的緩衝直接產出 —— meeting-copilot 的 consumer 用這個,
    /// 因為 `MeetingChannelSplitter` 給的是 `[[Float]]` 而非 interleaved。
    static func pcm16Data(
        channelBuffers: [[Float]],
        frameCount: Int,
        inputSampleRate: Double,
        outputSampleRate: Double = streamingSampleRate
    ) -> Data {
        guard !channelBuffers.isEmpty, frameCount > 0 else { return Data() }

        let channels = channelBuffers.count
        var interleaved = [Float](repeating: 0, count: frameCount * channels)
        for c in 0..<channels {
            let ch = channelBuffers[c]
            guard ch.count >= frameCount else { return Data() }
            for i in 0..<frameCount {
                interleaved[i * channels + c] = ch[i]
            }
        }

        return pcm16Data(
            interleaved: interleaved,
            frameCount: frameCount,
            channels: channels,
            inputSampleRate: inputSampleRate,
            outputSampleRate: outputSampleRate
        )
    }
}
