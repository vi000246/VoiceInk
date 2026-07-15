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

    /// partial 無變化達此秒數 → 視為一段結束。0.8s ≈ 句與句之間的自然停頓:比 1.5s 早約
    /// 0.7 秒把段落送去翻譯/抽 cue,即時字幕明顯更跟得上(M8 延遲優化)。代價是切得更碎、
    /// API 呼叫更多——搭配串流翻譯每段秒回即可接受。真正連續不停的講話仍需 provisional
    /// partial 翻譯(見 MeetingLiveTranslator)才追得上,停頓切段管不到「還沒停」的情況。
    var stallInterval: TimeInterval = 0.8
    /// 短於此字元數的 delta 不吐段(躲掉尾音修正、單字雜訊)。
    var minSegmentChars: Int = 4

    private var lastText: String = ""
    private var lastChangeAt: TimeInterval = -.infinity
    /// 已作為段落發出的**累積前綴文字**(不是字元偏移)。
    ///
    /// 為什麼存文字而不是 `Int` 偏移:雲端 ASR(ElevenLabs Scribe V2)會**修訂自己的
    /// partial 尾巴** —— 句尾常先放 `...` 佔位,下一輪把它換成實字(`"…resolve..."` →
    /// `"…resolve the conflict."`)。偏移會把被換掉的 `...` 位置當成「已發出」,於是
    /// `dropFirst(偏移)` 從替換文字的中間切下去,吐出 `"e conflict."` 這種斷詞碎片
    /// (2026-07-15 誤判事故)。改存文字後,`takeSegment` 以**共同前綴**重新錨定:
    /// 修訂只影響共同前綴之後的部分,替換進來的字完整保留,不吞詞、不重發已發過的字。
    private var emittedText: String = ""

    /// 每次 partial 更新時呼叫。
    mutating func observe(partial: String, at now: TimeInterval) {
        guard partial != lastText else { return }
        lastText = partial
        lastChangeAt = now
    }

    /// 週期呼叫:停頓達標 → 吐出未發出的新段落,否則 nil。
    mutating func poll(at now: TimeInterval) -> String? {
        guard now - lastChangeAt >= stallInterval else { return nil }
        return takeSegment(minChars: minSegmentChars)
    }

    /// 目前**還沒被切成 committed 的尾巴**(講者正在講、未定稿的那一段)。
    /// provisional 即時翻譯讀它,趁講者還沒停就先翻——這是「連續講話也追得上」的關鍵。
    /// **非 mutating**:只看不動 `emittedText`,不得干擾停頓切段的權威錨點。
    func provisionalTail() -> String {
        let anchor = Self.commonPrefixCount(emittedText, lastText)
        guard lastText.count > anchor else { return "" }
        return String(lastText.dropFirst(anchor))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 底層 ASR 真的 confirm 了一段(雲端 provider 每句觸發)→ 立即切段,不等停頓。
    mutating func forceSegment() -> String? {
        takeSegment(minChars: minSegmentChars)
    }

    /// 收尾:殘餘全部吐出(不受 minSegmentChars 限制)。
    mutating func flush() -> String? {
        takeSegment(minChars: 1)
    }

    /// 斷線重連後呼叫:新串流的累積全文從空字串重新長起來,舊的 `lastText`/`emittedText`
    /// 是另一條流的座標,清掉才乾淨。
    ///
    /// 共同前綴錨定本身已對「換流」穩健:新流開頭與舊 `emittedText` 幾乎沒有共同前綴,
    /// 不會被整段吞掉(舊的字元偏移設計才有這個吞頭陷阱)。reset 仍保留,避免新舊流恰好
    /// 共享前綴時的偶發漏字,並讓語意清楚。呼叫端負責在 reset 前先 `flush()` ——
    /// 斷線前真的聽到的殘餘字不該被丟掉。
    mutating func reset() {
        lastText = ""
        emittedText = ""
        lastChangeAt = -.infinity
    }

    private mutating func takeSegment(minChars: Int) -> String? {
        // 以共同前綴重新錨定:只發出「已發出前綴之後」新長出來的部分。ASR 修訂尾巴
        // (`...` → 實字)只改變共同前綴之後的字,替換進來的字完整落在 pending 裡。
        let anchor = Self.commonPrefixCount(emittedText, lastText)
        let pending = String(lastText.dropFirst(anchor))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending.count >= minChars else { return nil }
        emittedText = lastText
        return pending
    }

    /// 兩字串前綴相同的**字元(grapheme)數** —— 與 `dropFirst`/`count` 同一計數單位,
    /// 中英混合、emoji 都不會錯位。
    private static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var i = a.startIndex
        var j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            count += 1
            i = a.index(after: i)
            j = b.index(after: j)
        }
        return count
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

    func provisionalTail() -> String {
        lock.lock(); defer { lock.unlock() }
        return segmenter.provisionalTail()
    }

    func forceSegment() -> String? {
        lock.lock(); defer { lock.unlock() }
        return segmenter.forceSegment()
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        return segmenter.flush()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        segmenter.reset()
    }
}
