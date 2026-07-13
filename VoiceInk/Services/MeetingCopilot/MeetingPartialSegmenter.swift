import Foundation

/// 從**累積 partial** 切出 committed 段落的純狀態機:「partial 停止變化達 stallInterval
/// = 講者說完一段」。
///
/// # 為什麼不用底層 ASR 的 committed 事件當唯一來源
///
/// FluidAudio 的 `WordAgreementEngine` confirm 條件極保守(agreed prefix 要有 3 個以上
/// 句尾標點、永遠保留最後 2 句當 hypothesis、共同前綴 ≥5 個「詞」——中文常被合併成
/// 單一巨型詞永遠不達標)。實測(2026-07-13,build 253)整場 31 秒會議**零次**
/// mid-stream confirm,第一個 committed 出現在 stop 之後 —— cue 偵測形同失效。
///
/// 停頓切段對語言、標點、provider 都不敏感:`StreamingTranscriptionService` 已把所有
/// provider 的 partial 正規化成「累積全文」(它的 partial case 會補上 committed prefix),
/// 所以這裡只需對同一條累積文字做 delta。
///
/// # 執行緒
///
/// 純狀態機不含鎖;`MeetingPartialSegmenterBox` 提供 lock 包裝(observe 來自 service 的
/// MainActor closure、poll 來自 wrapper 的 tick task)。
struct MeetingPartialSegmenter {

    /// partial 無變化達此秒數 → 視為一段結束。1.5s ≈ 問完問題後的自然停頓,
    /// 遠小於 FluidAudio 每 1s 一輪的轉錄節奏所能感知的最短靜默。
    var stallInterval: TimeInterval = 1.5
    /// 短於此字元數的 delta 不吐段(躲掉尾音修正、單字雜訊)。
    var minSegmentChars: Int = 4

    private var lastText: String = ""
    private var lastChangeAt: TimeInterval = -.infinity
    /// `lastText` 前綴中已作為段落發出的字元數。
    private var emittedCount: Int = 0

    /// 每次 partial 更新時呼叫。
    mutating func observe(partial: String, at now: TimeInterval) {
        guard partial != lastText else { return }
        // hypothesis 修正可能讓累積文縮短:已發出的偏移不再可信,
        // 退回目前長度(寧可漏掉一小段,不重複發同一段)。
        if partial.count < emittedCount { emittedCount = partial.count }
        lastText = partial
        lastChangeAt = now
    }

    /// 週期呼叫:停頓達標 → 吐出未發出的新段落,否則 nil。
    mutating func poll(at now: TimeInterval) -> String? {
        guard now - lastChangeAt >= stallInterval else { return nil }
        return takeSegment(minChars: minSegmentChars)
    }

    /// 底層 ASR 真的 confirm 了一段(雲端 provider 每句觸發)→ 立即切段,不等停頓。
    mutating func forceSegment() -> String? {
        takeSegment(minChars: minSegmentChars)
    }

    /// 收尾:殘餘全部吐出(不受 minSegmentChars 限制)。
    mutating func flush() -> String? {
        takeSegment(minChars: 1)
    }

    private mutating func takeSegment(minChars: Int) -> String? {
        guard lastText.count - emittedCount >= minChars else { return nil }
        let segment = String(lastText.dropFirst(emittedCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        emittedCount = lastText.count
        return segment.isEmpty ? nil : segment
    }
}

/// lock 包裝:observe 由 `StreamingTranscriptionService` 的 MainActor closure 呼叫,
/// poll 由 `LiveMeetingTranscriptStream` 的 tick task 呼叫。
final class MeetingPartialSegmenterBox: @unchecked Sendable {

    private var segmenter = MeetingPartialSegmenter()
    private let lock = NSLock()

    func observe(partial: String, at now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        segmenter.observe(partial: partial, at: now)
    }

    func poll(at now: TimeInterval) -> String? {
        lock.lock(); defer { lock.unlock() }
        return segmenter.poll(at: now)
    }

    func forceSegment() -> String? {
        lock.lock(); defer { lock.unlock() }
        return segmenter.forceSegment()
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        return segmenter.flush()
    }
}
