import XCTest
@testable import VoiceInk

/// AC-3:realtime thread 不得被阻塞;滿溢時丟棄並計數。
final class MeetingPCMRingBufferTests: XCTestCase {

    // MARK: - 基本往返

    func testWriteThenReadRoundTrips() {
        let ring = MeetingPCMRingBuffer(slotCount: 4, maxChannels: 3, maxFrames: 8)

        ring.write(
            channelBuffers: [[1, 2], [3, 4], [5, 6]],
            channelCount: 3, frameCount: 2, sampleRate: 48_000
        )

        let slot = ring.read()
        XCTAssertNotNil(slot)
        XCTAssertEqual(slot?.channelCount, 3)
        XCTAssertEqual(slot?.frameCount, 2)
        XCTAssertEqual(slot?.sampleRate, 48_000)
        XCTAssertEqual(slot?.channelBuffers, [[1, 2], [3, 4], [5, 6]])

        XCTAssertNil(ring.read(), "讀完之後應為空")
        XCTAssertEqual(ring.droppedCallbacks, 0)
    }

    /// FIFO 順序必須維持。
    func testPreservesFIFOOrder() {
        let ring = MeetingPCMRingBuffer(slotCount: 8, maxChannels: 1, maxFrames: 4)

        for i in 1...5 {
            ring.write(channelBuffers: [[Float(i)]], channelCount: 1, frameCount: 1, sampleRate: 16_000)
        }

        for i in 1...5 {
            XCTAssertEqual(ring.read()?.channelBuffers, [[Float(i)]], "第 \(i) 筆順序錯誤")
        }
        XCTAssertNil(ring.read())
    }

    /// 環繞（write index 超過 slotCount）之後仍正確。
    func testWrapsAroundCorrectly() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 1, maxFrames: 4)

        // 寫滿讀空，重複三輪 → writeIndex 會繞過 slotCount
        for round in 0..<3 {
            ring.write(channelBuffers: [[Float(round * 2)]], channelCount: 1, frameCount: 1, sampleRate: 16_000)
            ring.write(channelBuffers: [[Float(round * 2 + 1)]], channelCount: 1, frameCount: 1, sampleRate: 16_000)

            XCTAssertEqual(ring.read()?.channelBuffers, [[Float(round * 2)]])
            XCTAssertEqual(ring.read()?.channelBuffers, [[Float(round * 2 + 1)]])
        }
        XCTAssertEqual(ring.droppedCallbacks, 0)
    }

    // MARK: - AC-3:滿溢

    /// 背壓:ring 滿時丟棄**這一輪**（不是最舊的——見 MeetingPCMRingBuffer 的說明）,
    /// 並計數,**不阻塞**。已在 ring 裡的資料必須完好。
    func testOverflowDropsNewestAndCountsWithoutBlocking() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 1, maxFrames: 4)

        ring.write(channelBuffers: [[1]], channelCount: 1, frameCount: 1, sampleRate: 16_000)
        ring.write(channelBuffers: [[2]], channelCount: 1, frameCount: 1, sampleRate: 16_000)
        // 第 3 次:ring 已滿（尚未讀取）→ 丟棄這一輪
        ring.write(channelBuffers: [[3]], channelCount: 1, frameCount: 1, sampleRate: 16_000)

        XCTAssertEqual(ring.droppedCallbacks, 1)
        XCTAssertEqual(ring.droppedBreakdown.backpressure, 1)
        XCTAssertEqual(ring.droppedBreakdown.capacity, 0)

        // 先寫進去的兩筆必須完好無損
        XCTAssertEqual(ring.read()?.channelBuffers, [[1]])
        XCTAssertEqual(ring.read()?.channelBuffers, [[2]])
        XCTAssertNil(ring.read())
    }

    /// 讀走一筆之後空出 slot,又可以寫入。
    func testRecoversAfterConsumerDrains() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 1, maxFrames: 4)

        ring.write(channelBuffers: [[1]], channelCount: 1, frameCount: 1, sampleRate: 16_000)
        ring.write(channelBuffers: [[2]], channelCount: 1, frameCount: 1, sampleRate: 16_000)
        ring.write(channelBuffers: [[3]], channelCount: 1, frameCount: 1, sampleRate: 16_000)   // dropped
        XCTAssertEqual(ring.droppedCallbacks, 1)

        _ = ring.read()   // 空出一個 slot
        ring.write(channelBuffers: [[4]], channelCount: 1, frameCount: 1, sampleRate: 16_000)   // 應該成功

        XCTAssertEqual(ring.droppedCallbacks, 1, "不應再有新的丟棄")
        XCTAssertEqual(ring.read()?.channelBuffers, [[2]])
        XCTAssertEqual(ring.read()?.channelBuffers, [[4]])
    }

    // MARK: - 容量防守（不得越界寫入）

    /// frame 數超出 slot 容量 → 丟棄並計入 capacity,**不得越界**。
    func testOversizedFrameCountIsDropped() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 1, maxFrames: 4)

        ring.write(
            channelBuffers: [[1, 2, 3, 4, 5, 6]],
            channelCount: 1, frameCount: 6, sampleRate: 16_000
        )

        XCTAssertEqual(ring.droppedCallbacks, 1)
        XCTAssertEqual(ring.droppedBreakdown.capacity, 1)
        XCTAssertNil(ring.read())
    }

    /// 聲道數超出 maxChannels → 丟棄,不得越界。
    func testTooManyChannelsIsDropped() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 2, maxFrames: 4)

        ring.write(
            channelBuffers: [[1], [2], [3]],
            channelCount: 3, frameCount: 1, sampleRate: 16_000
        )

        XCTAssertEqual(ring.droppedCallbacks, 1)
        XCTAssertEqual(ring.droppedBreakdown.capacity, 1)
        XCTAssertNil(ring.read())
    }

    /// channelCount 宣稱比實際 buffer 數多 → 丟棄,不得越界讀取。
    func testChannelCountExceedingBuffersIsDropped() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 4, maxFrames: 4)

        ring.write(
            channelBuffers: [[1]],          // 只有 1 個聲道
            channelCount: 3,                // 卻宣稱 3 個
            frameCount: 1, sampleRate: 16_000
        )

        XCTAssertEqual(ring.droppedCallbacks, 1)
        XCTAssertNil(ring.read())
    }

    func testZeroFramesOrChannelsIsDropped() {
        let ring = MeetingPCMRingBuffer(slotCount: 2, maxChannels: 2, maxFrames: 4)

        ring.write(channelBuffers: [[1]], channelCount: 1, frameCount: 0, sampleRate: 16_000)
        ring.write(channelBuffers: [], channelCount: 0, frameCount: 1, sampleRate: 16_000)

        XCTAssertEqual(ring.droppedCallbacks, 2)
        XCTAssertNil(ring.read())
    }

    // MARK: - AC-2 的另一半:sink 不得改動來源緩衝

    /// seam 只讀不寫:把 `channelScratch` 餵給 sink **不得**改變它,
    /// 因此 `mixToMono`（seam 之後才跑）的結果必須完全不受影響。
    func testSinkDoesNotMutateSourceBuffers() {
        let channels: [[Float]] = [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]]

        let before = MeetingAudioMixer.mixToMono(channelBuffers: channels, frameCount: 2)

        let ring = MeetingPCMRingBuffer(slotCount: 8, maxChannels: 4, maxFrames: 512)
        ring.write(channelBuffers: channels, channelCount: 3, frameCount: 2, sampleRate: 48_000)

        let after = MeetingAudioMixer.mixToMono(channelBuffers: channels, frameCount: 2)

        XCTAssertEqual(before, after, "sink 不得改動 channelScratch —— 落檔的樣本必須完全不變")
        XCTAssertEqual(channels, [[0.1, 0.2], [0.3, 0.4], [0.5, 0.6]], "來源陣列本身不得被改動")
    }

    // MARK: - 併發（SPSC）

    /// 生產者與消費者並行:所有寫入的資料都必須被讀到,順序正確,無資料損毀。
    func testConcurrentProducerConsumerSPSC() {
        let ring = MeetingPCMRingBuffer(slotCount: 64, maxChannels: 1, maxFrames: 16)
        let total = 2_000

        let produced = expectation(description: "producer done")
        let consumed = expectation(description: "consumer done")

        DispatchQueue.global(qos: .userInitiated).async {
            var i = 0
            while i < total {
                ring.write(
                    channelBuffers: [[Float(i)]],
                    channelCount: 1, frameCount: 1, sampleRate: 16_000
                )
                i += 1
            }
            produced.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var seen: [Float] = []
            let deadline = Date().addingTimeInterval(10)
            while seen.count < total, Date() < deadline {
                if let slot = ring.read() {
                    seen.append(slot.channelBuffers[0][0])
                }
            }
            // 讀到的必須是嚴格遞增的子序列（丟棄只會造成缺號,不會亂序/損毀）
            for i in 1..<seen.count {
                XCTAssertGreaterThan(seen[i], seen[i - 1], "順序損毀:index \(i)")
            }
            // 讀到的 + 丟棄的 == 全部
            XCTAssertEqual(seen.count + ring.droppedCallbacks, total)
            consumed.fulfill()
        }

        wait(for: [produced, consumed], timeout: 15)
    }
}
