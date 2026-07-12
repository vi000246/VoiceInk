import XCTest
@testable import VoiceInk

/// `PCMDownsampler` 是從 `CoreAudioRecorder.convertAndWriteToFile` **逐字抽出**的。
/// 這些測試鎖住它的位元等價行為——聽寫路徑依賴它,任何「順手修正」都會被抓到。
final class PCMDownsamplerTests: XCTestCase {

    // MARK: - 同取樣率（只混音 + Int16 轉換）

    func testSameRateMixesChannelsAndConvertsToInt16() {
        // 立體聲 2 frame,interleaved:[L0, R0, L1, R1]
        let input: [Float] = [1.0, 0.0, -1.0, 0.0]

        let out = PCMDownsampler.toMono16kInt16(
            interleaved: input, frameCount: 2, channels: 2,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )

        // frame0 = (1.0 + 0.0) / 2 =  0.5 →  0.5 * 32767 =  16383.5 → Int16(16383)
        // frame1 = (-1.0 + 0.0) / 2 = -0.5 → -16383.5 → Int16(-16383)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], 16383)
        XCTAssertEqual(out[1], -16383)
    }

    func testMonoSameRatePassesThrough() {
        let out = PCMDownsampler.toMono16kInt16(
            interleaved: [0.0, 1.0, -1.0], frameCount: 3, channels: 1,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )
        XCTAssertEqual(out, [0, 32767, -32767])
    }

    // MARK: - 降頻

    /// 48k → 16k:輸出 frame 數 = frameCount / 3。
    func testDownsamples48kTo16k() {
        let frames = 300
        let input = [Float](repeating: 0.5, count: frames)

        let out = PCMDownsampler.toMono16kInt16(
            interleaved: input, frameCount: frames, channels: 1,
            inputSampleRate: 48_000, outputSampleRate: 16_000
        )

        XCTAssertEqual(out.count, 100)
        // 定值訊號 → 線性插值後仍是定值
        XCTAssertEqual(out[0], 16383)
        XCTAssertEqual(out[50], 16383)
        XCTAssertEqual(out[99], 16383)
    }

    /// 44.1k → 16k（非整數倍）也不能崩,且輸出長度符合公式。
    func testDownsamples44_1kTo16k() {
        let frames = 441
        let input = [Float](repeating: 0.25, count: frames)

        let out = PCMDownsampler.toMono16kInt16(
            interleaved: input, frameCount: frames, channels: 1,
            inputSampleRate: 44_100, outputSampleRate: 16_000
        )

        XCTAssertEqual(out.count, PCMDownsampler.outputFrameCount(
            frameCount: frames, inputSampleRate: 44_100, outputSampleRate: 16_000
        ))
        XCTAssertEqual(out.count, 160)
    }

    /// 立體聲 48k → mono 16k:聲道混音與降頻同時發生。
    func testStereo48kToMono16k() {
        let frames = 96
        var input = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            input[i * 2] = 1.0       // L
            input[i * 2 + 1] = 0.0   // R
        }

        let out = PCMDownsampler.toMono16kInt16(
            interleaved: input, frameCount: frames, channels: 2,
            inputSampleRate: 48_000, outputSampleRate: 16_000
        )

        XCTAssertEqual(out.count, 32)
        // (1.0 + 0.0) / 2 = 0.5 → 16383
        XCTAssertEqual(out[0], 16383)
        XCTAssertEqual(out[16], 16383)
    }

    // MARK: - 削波

    /// 超出 ±1.0 的樣本必須夾到 Int16 範圍,不得溢位（Int16(clipped) 會 trap）。
    func testClipsOutOfRangeSamples() {
        let out = PCMDownsampler.toMono16kInt16(
            interleaved: [2.0, -2.0, 100.0, -100.0], frameCount: 4, channels: 1,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )
        XCTAssertEqual(out, [32767, -32768, 32767, -32768])
    }

    // MARK: - Data 封裝

    func testPCM16DataIsLittleEndian() {
        let data = PCMDownsampler.pcm16Data(
            interleaved: [1.0], frameCount: 1, channels: 1,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )
        // 32767 = 0x7FFF → little-endian bytes = FF 7F
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual([UInt8](data), [0xFF, 0x7F])
    }

    func testPCM16DataByteCountMatchesFrames() {
        // 0.5 秒 @16kHz mono Int16 = 8000 frames * 2 bytes = 16000 bytes
        let frames = 8_000
        let data = PCMDownsampler.pcm16Data(
            interleaved: [Float](repeating: 0.1, count: frames), frameCount: frames, channels: 1,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )
        XCTAssertEqual(data.count, 16_000)
    }

    // MARK: - 逐聲道版（meeting-copilot 的 consumer 走這條）

    /// `[[Float]]`（splitter 的輸出）→ Data。內部會 interleave 再走同一條核心。
    func testChannelBuffersOverloadMatchesInterleaved() {
        let chL: [Float] = [1.0, -1.0]
        let chR: [Float] = [0.0, 0.0]

        let fromChannels = PCMDownsampler.pcm16Data(
            channelBuffers: [chL, chR], frameCount: 2,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )
        let fromInterleaved = PCMDownsampler.pcm16Data(
            interleaved: [1.0, 0.0, -1.0, 0.0], frameCount: 2, channels: 2,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )

        XCTAssertEqual(fromChannels, fromInterleaved, "兩個入口必須產出完全相同的位元組")
    }

    /// 單聲道 remote（會議中最常見:mono tap 或 splitter 給單聲道）。
    func testSingleChannelBuffer() {
        let data = PCMDownsampler.pcm16Data(
            channelBuffers: [[0.5, -0.5]], frameCount: 2,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        )
        XCTAssertEqual(data.count, 4)
    }

    // MARK: - 邊界

    func testEmptyAndInvalidInput() {
        XCTAssertTrue(PCMDownsampler.toMono16kInt16(
            interleaved: [], frameCount: 0, channels: 1,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        ).isEmpty)

        XCTAssertTrue(PCMDownsampler.toMono16kInt16(
            interleaved: [1.0], frameCount: 1, channels: 0,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        ).isEmpty)

        // 輸入樣本數不足 frameCount * channels → 不得越界讀取
        XCTAssertTrue(PCMDownsampler.toMono16kInt16(
            interleaved: [1.0], frameCount: 4, channels: 2,
            inputSampleRate: 16_000, outputSampleRate: 16_000
        ).isEmpty)

        XCTAssertTrue(PCMDownsampler.pcm16Data(
            channelBuffers: [[1.0]], frameCount: 5,
            inputSampleRate: 16_000
        ).isEmpty, "聲道長度不足 frameCount → 空,不得越界")
    }

    /// 容量不足時核心必須拒絕寫入（回傳 0),不得越界。
    func testConvertRejectsInsufficientOutputCapacity() {
        let input: [Float] = [1.0, 1.0, 1.0, 1.0]
        var out = [Int16](repeating: 0, count: 1)   // 容量只有 1,但需要 4

        let written = input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                PCMDownsampler.convert(
                    interleaved: src.baseAddress!,
                    frameCount: 4, channels: 1,
                    inputSampleRate: 16_000, outputSampleRate: 16_000,
                    out: dst.baseAddress!, outCapacity: 1
                )
            }
        }
        XCTAssertEqual(written, 0, "容量不足時必須拒絕,不得越界寫入")
    }

    func testOutputFrameCountFormula() {
        XCTAssertEqual(PCMDownsampler.outputFrameCount(frameCount: 300, inputSampleRate: 48_000, outputSampleRate: 16_000), 100)
        XCTAssertEqual(PCMDownsampler.outputFrameCount(frameCount: 100, inputSampleRate: 16_000, outputSampleRate: 16_000), 100)
        XCTAssertEqual(PCMDownsampler.outputFrameCount(frameCount: 0, inputSampleRate: 48_000, outputSampleRate: 16_000), 0)
    }
}
