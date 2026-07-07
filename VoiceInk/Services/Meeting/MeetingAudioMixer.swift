import Accelerate

/// 等權平均把多聲道 Float32 樣本混成 mono。純函式,供 IOProc 與單元測試共用。
///
/// Pure helper shared by the realtime IOProc and unit tests: averages any number of
/// channel buffers (system-audio tap channels + optional mic channels) into one mono
/// buffer. Uses raw vDSP calls (vDSP_vadd / vDSP_vsdiv) — the classic C API compiles
/// unambiguously for [Float] and permits in-place accumulation without COW surprises.
enum MeetingAudioMixer {
    /// channelBuffers: 各聲道樣本(每個長度 == frameCount,較長時只取前 frameCount 個)。
    /// 空輸入回傳 [];任一聲道樣本數不足 frameCount 視為無效輸入,同樣回傳 []。
    static func mixToMono(channelBuffers: [[Float]], frameCount: Int) -> [Float] {
        guard frameCount > 0, !channelBuffers.isEmpty else { return [] }
        // 防守:長度不足會造成越界讀取,直接視為無效輸入。
        guard channelBuffers.allSatisfy({ $0.count >= frameCount }) else { return [] }

        var acc = [Float](repeating: 0, count: frameCount)
        for channel in channelBuffers {
            acc.withUnsafeMutableBufferPointer { accPtr in
                channel.withUnsafeBufferPointer { chPtr in
                    guard let accBase = accPtr.baseAddress, let chBase = chPtr.baseAddress else { return }
                    // acc += channel(vDSP_vadd 支援 in-place:C 與 A 同一塊緩衝)
                    vDSP_vadd(accBase, 1, chBase, 1, accBase, 1, vDSP_Length(frameCount))
                }
            }
        }

        var divisor = Float(channelBuffers.count)
        var out = [Float](repeating: 0, count: frameCount)
        acc.withUnsafeBufferPointer { accPtr in
            out.withUnsafeMutableBufferPointer { outPtr in
                guard let accBase = accPtr.baseAddress, let outBase = outPtr.baseAddress else { return }
                // out = acc / channelCount
                vDSP_vsdiv(accBase, 1, &divisor, outBase, 1, vDSP_Length(frameCount))
            }
        }
        return out
    }
}
