import Foundation
import Atomics

/// 單一生產者（HAL realtime thread）／單一消費者（copilot consumer task）的 **lock-free slot ring**。
///
/// # 形狀完全照抄 `CoreAudioRecorder` 的 input ring
///
/// 見 `CoreAudioRecorder.swift:68-77`（欄位）與 `:822-888`（讀寫）。同樣的
/// `ManagedAtomic<UInt64>` 讀寫索引、同樣的 `.relaxed` / `.acquiring` / `.releasing`
/// 記憶體序、同樣的背壓語意。**不要自創記憶體序**——這類程式碼寫錯不會當場爆炸,
/// 只會在幾小時後掉一段音訊。
///
/// # 滿溢時丟「新的」而不是「舊的」
///
/// SRS 原本寫「滿溢時丟棄最舊」。**做不到,而且不該做**:在 SPSC 環形緩衝裡,
/// 「丟棄最舊」需要推進 `readIndex`——那是**消費者的**變數。從生產者去動它會直接
/// 破壞 SPSC 不變式（兩個執行緒同時寫同一個索引）。
///
/// `CoreAudioRecorder` 的做法（也是唯一 lock-free 安全的做法）是**背壓**:
/// 滿了就拒絕寫入這一輪,並計數。本實作照做。
///
/// 實務上這無所謂:預設 96 slot × 4096 frame @48kHz ≈ **8 秒**的緩衝。
/// 真的滿溢代表 consumer 嚴重卡住,那時丟哪一端都已經是降級狀態了——
/// 重要的是**不阻塞 realtime thread**（阻塞會直接造成錄音爆音）。
final class MeetingPCMRingBuffer: MeetingPCMSink, @unchecked Sendable {

    /// 一輪音訊（consumer 側的視圖）。
    struct Slot {
        let channelBuffers: [[Float]]
        let channelCount: Int
        let frameCount: Int
        let sampleRate: Double
    }

    /// 預先配置的 slot 儲存體（flat, channel-major:第 c 聲道位於 `samples + c * maxFrames`）。
    private final class Storage {
        let samples: UnsafeMutablePointer<Float>
        var channelCount: Int = 0
        var frameCount: Int = 0
        var sampleRate: Double = 0

        init(capacity: Int) {
            samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            samples.initialize(repeating: 0, count: capacity)
        }

        deinit {
            samples.deallocate()
        }
    }

    private let slots: [Storage]
    private let slotCount: Int
    private let maxChannels: Int
    private let maxFrames: Int

    private let writeIndex = ManagedAtomic<UInt64>(0)
    private let readIndex = ManagedAtomic<UInt64>(0)

    /// 因背壓（ring 滿）而被丟棄的 callback 數。
    private let droppedBackpressure = ManagedAtomic<UInt64>(0)
    /// 因超出 slot 容量（聲道數 / frame 數過大）而被丟棄的 callback 數。
    private let droppedCapacity = ManagedAtomic<UInt64>(0)

    /// 觀測用:被丟棄的 **callback** 總數（不是 frame 數——一個 callback 帶多個 frame）。
    var droppedCallbacks: Int {
        Int(droppedBackpressure.load(ordering: .relaxed) + droppedCapacity.load(ordering: .relaxed))
    }

    /// 分項計數,用於診斷:背壓（consumer 太慢）vs 容量（格式超出預期）是兩種完全不同的病。
    var droppedBreakdown: (backpressure: Int, capacity: Int) {
        (
            Int(droppedBackpressure.load(ordering: .relaxed)),
            Int(droppedCapacity.load(ordering: .relaxed))
        )
    }

    /// - Parameters:
    ///   - slotCount: 環形緩衝的 slot 數。預設 96（同 `CoreAudioRecorder.inputRingSlotCount`）。
    ///   - maxChannels: 單輪最大聲道數。tap(stereo) + mic(mono) = 3 是典型值;留 8 的餘裕。
    ///   - maxFrames: 單輪最大 frame 數。同 `CoreAudioRecorder.maxFramesPerRender`。
    init(slotCount: Int = 96, maxChannels: Int = 8, maxFrames: Int = 4096) {
        precondition(slotCount > 0 && maxChannels > 0 && maxFrames > 0)
        self.slotCount = slotCount
        self.maxChannels = maxChannels
        self.maxFrames = maxFrames
        self.slots = (0..<slotCount).map { _ in Storage(capacity: maxChannels * maxFrames) }
    }

    // MARK: - Producer（realtime thread — 無鎖、無配置）

    func write(channelBuffers: [[Float]], channelCount: Int, frameCount: Int, sampleRate: Double) {
        // 容量檢查（照抄 CoreAudioRecorder:822-825）
        guard channelCount > 0, channelCount <= maxChannels,
              frameCount > 0, frameCount <= maxFrames,
              channelBuffers.count >= channelCount else {
            droppedCapacity.wrappingIncrement(ordering: .relaxed)
            return
        }

        // 背壓檢查（照抄 CoreAudioRecorder:827-832）——滿了就丟這一輪,**絕不阻塞**。
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        guard w - r < UInt64(slotCount) else {
            droppedBackpressure.wrappingIncrement(ordering: .relaxed)
            return
        }

        let slot = slots[Int(w % UInt64(slotCount))]
        slot.channelCount = channelCount
        slot.frameCount = frameCount
        slot.sampleRate = sampleRate

        // memcpy,無配置（照抄 CoreAudioRecorder:840 的 slot.samples.update(from:count:)）
        for c in 0..<channelCount {
            channelBuffers[c].withUnsafeBufferPointer { src in
                guard let base = src.baseAddress, src.count >= frameCount else { return }
                (slot.samples + c * maxFrames).update(from: base, count: frameCount)
            }
        }

        // release:確保上面的資料寫入對 consumer 的 acquiring load 可見。
        writeIndex.store(w + 1, ordering: .releasing)
    }

    // MARK: - Consumer（一般執行緒 — 可配置）

    /// 取出下一輪。空的時候回傳 nil。
    func read() -> Slot? {
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        guard r < w else { return nil }

        let slot = slots[Int(r % UInt64(slotCount))]
        let ch = slot.channelCount
        let fr = slot.frameCount

        var buffers: [[Float]] = []
        buffers.reserveCapacity(ch)
        for c in 0..<ch {
            let base = slot.samples + c * maxFrames
            buffers.append(Array(UnsafeBufferPointer(start: base, count: fr)))
        }

        let out = Slot(
            channelBuffers: buffers,
            channelCount: ch,
            frameCount: fr,
            sampleRate: slot.sampleRate
        )

        readIndex.store(r + 1, ordering: .releasing)
        return out
    }
}
