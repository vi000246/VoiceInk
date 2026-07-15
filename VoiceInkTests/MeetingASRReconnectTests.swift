import XCTest
@testable import VoiceInk

/// 2026-07-14 事故的回歸測試:整場會議 0 cue、0 segment,逐字稿卻錄到了。
///
/// # 事故鏈(unified log 佐證)
///
/// 1. 會議 19:52:54 開始,兩條 Scribe V2 串流 19:52:55 連上。
/// 2. process tap 在對方 app 真的出聲前不給任何 IO callback → **前 30 秒零音訊送出**。
/// 3. ElevenLabs 在閒置 **15.0 秒**後關掉 socket(兩條流都是「連上後 15.0s」報錯)。
/// 4. 19:53:25 TTS 開始播,音訊全送進死掉的 socket —— **9,640 次** send 失敗,
///    沒有任何一層知道要重連(`.error` 事件只被 log 掉)。
/// 5. 沒有 partial → 沒有 committed → cue 抽取從未被觸發。
///
/// 修復是兩道防線:**keepalive**(閒置時補靜音,socket 不會 idle 死)+
/// **reconnect**(還是死了就重建串流)。這裡鎖住兩者的純邏輯與切段器的重連語意。
final class MeetingASRReconnectTests: XCTestCase {

    // MARK: - keepalive

    /// 靜音塊必須符合送進 ASR 的格式契約:16kHz mono Int16 LE 的 200ms = 6,400 bytes 的 0。
    ///
    /// 大小不能亂改:太短伺服器可能不當成一次有效的 audio chunk,太長就是白付 ASR 的錢。
    func testSilenceChunkIs200msOf16kHzMonoInt16() {
        let chunk = LiveMeetingTranscriptStream.silenceChunk

        // 200ms @ 16kHz = 3,200 samples;Int16 = 2 bytes/sample。
        XCTAssertEqual(chunk.count, 6_400)
        XCTAssertTrue(chunk.allSatisfy { $0 == 0 }, "keepalive 送的必須是純靜音,不能夾帶任何樣本")
    }

    /// 保活門檻必須遠小於伺服器的 15s idle timeout —— 這是整個修復的前提。
    /// 留足夠餘裕:2s 門檻 + 0.5s 輪詢,最壞情況 2.5s 就會補上一段靜音。
    func testKeepAliveThresholdIsWellUnderServerIdleTimeout() {
        let observedServerIdleTimeout: TimeInterval = 15.0
        let worstCaseGap = LiveMeetingTranscriptStream.keepAliveIdleThreshold + 0.5

        XCTAssertLessThan(worstCaseGap, observedServerIdleTimeout / 2,
                          "保活間隔必須有數倍餘裕,否則一次排程延遲就讓 socket 死掉")
    }

    // MARK: - 休眠(「會議忘了關」的保險)

    /// 休眠判斷**不能**拿「有沒有 frame 進來」當訊號:對方 app 佔住音訊裝置時,沒人說話
    /// 也會有源源不絕的 0 樣本 frame(事故 log 裡那些 `REMOTE[0.0000]`)。所以要看能量。
    func testHasSignalDistinguishesSilenceFromSpeech() {
        // 純靜音(keepalive 送的就是這個)→ 不算活躍,否則保活本身會讓會議永遠不休眠。
        XCTAssertFalse(LiveMeetingTranscriptStream.hasSignal(LiveMeetingTranscriptStream.silenceChunk))

        // 麥克風底噪 ≈ 0.004(事故 log 的 LOCAL[0.0043])→ 不該把會議一直撐醒。
        XCTAssertFalse(LiveMeetingTranscriptStream.hasSignal(pcm16(amplitude: 0.004)))

        // 說話 ≈ 0.05~0.25(事故 log 的 REMOTE[0.1484])→ 必須觸發。
        XCTAssertTrue(LiveMeetingTranscriptStream.hasSignal(pcm16(amplitude: 0.15)))
    }

    /// 空資料不該炸,也不該被當成有聲音。
    func testHasSignalOnEmptyDataIsFalse() {
        XCTAssertFalse(LiveMeetingTranscriptStream.hasSignal(Data()))
    }

    /// 休眠門檻必須遠大於保活門檻 —— 否則會在「保活」與「休眠」之間來回抖動。
    func testDormancyThresholdIsFarAboveKeepAliveThreshold() {
        XCTAssertGreaterThan(LiveMeetingTranscriptStream.idleDormancyThreshold,
                             LiveMeetingTranscriptStream.keepAliveIdleThreshold * 10)
    }

    /// 休眠空窗期的暫存要蓋得住喚醒(~0.5s tick)+ 重連(~0.3s),對方第一句話才不會缺頭。
    func testDormantBufferCoversWakeAndReconnectGap() {
        let bytesPerSecond = 16_000 * MemoryLayout<Int16>.size
        let bufferedSeconds = Double(LiveMeetingTranscriptStream.maxBufferedBytes) / Double(bytesPerSecond)

        XCTAssertGreaterThanOrEqual(bufferedSeconds, 2.0,
                                    "暫存要撐得過喚醒 + 重連的空窗,否則喚醒後第一句話會缺頭")
    }

    /// 產一段固定振幅的 16kHz mono Int16 音訊(200ms)。
    private func pcm16(amplitude: Float, samples: Int = 3_200) -> Data {
        let value = Int16(amplitude * Float(Int16.max))
        var buffer = [Int16](repeating: value, count: samples)
        return buffer.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - reconnect backoff

    /// 指數退避:0.5 → 1 → 2 → 4 → 封頂 5。封頂是為了長會議 —— 網路斷 5 分鐘後回來,
    /// 重連間隔不該已經退避到好幾分鐘一次。
    func testReconnectDelayBacksOffExponentiallyThenCaps() {
        XCTAssertEqual(LiveMeetingTranscriptStream.reconnectDelay(attempt: 1), 0.5, accuracy: 0.001)
        XCTAssertEqual(LiveMeetingTranscriptStream.reconnectDelay(attempt: 2), 1.0, accuracy: 0.001)
        XCTAssertEqual(LiveMeetingTranscriptStream.reconnectDelay(attempt: 3), 2.0, accuracy: 0.001)
        XCTAssertEqual(LiveMeetingTranscriptStream.reconnectDelay(attempt: 4), 4.0, accuracy: 0.001)
        XCTAssertEqual(LiveMeetingTranscriptStream.reconnectDelay(attempt: 5), 5.0, accuracy: 0.001)
        XCTAssertEqual(LiveMeetingTranscriptStream.reconnectDelay(attempt: 99), 5.0, accuracy: 0.001)
    }

    /// 第一次重連要夠快 —— 對方可能正在講話。
    func testFirstReconnectIsFast() {
        XCTAssertLessThanOrEqual(LiveMeetingTranscriptStream.reconnectDelay(attempt: 1), 1.0)
    }

    // MARK: - 切段器的重連語意

    /// 重連後新串流的累積全文**從空字串重新長起來**。
    /// 最危險的失效模式是:舊的 `emittedCount` 留著 → 新流的字被當成「已經發過」而被吞掉,
    /// 或反過來把舊文重發一次(cue 被重複抽取)。reset 之後兩者都不該發生。
    func testResetLetsNewStreamEmitFromScratch() {
        var segmenter = MeetingPartialSegmenter()

        segmenter.observe(partial: "你會怎麼設計一個短網址服務", at: 0)
        XCTAssertEqual(segmenter.poll(at: 2.0), "你會怎麼設計一個短網址服務")

        // 斷線 → 重連。新流從頭開始。
        segmenter.reset()
        segmenter.observe(partial: "那快取要怎麼處理", at: 10.0)

        XCTAssertEqual(segmenter.poll(at: 12.0), "那快取要怎麼處理",
                       "重連後的第一段不該被舊的 emittedCount 吞掉")
    }

    /// 斷線前 ASR 真的聽到、但還沒因停頓切出來的殘餘字,必須先 flush 再 reset ——
    /// 否則對方講到一半斷線,那半句就永遠消失了。
    func testFlushBeforeResetKeepsResidualSpeech() {
        var segmenter = MeetingPartialSegmenter()

        // 對方講到一半,還沒停頓滿 1.5s 就斷線了。
        segmenter.observe(partial: "我對這個寫入效能有點擔心", at: 0)
        XCTAssertNil(segmenter.poll(at: 0.5), "還沒停頓夠久,不該切段")

        // 重連流程:先 flush 殘餘,再 reset。
        XCTAssertEqual(segmenter.flush(), "我對這個寫入效能有點擔心")
        segmenter.reset()

        // reset 之後不該再把同一段吐第二次(cue 會被重複抽取)。
        XCTAssertNil(segmenter.flush())
    }

    /// 共同前綴錨定讓「換流」天然安全:新流開頭與舊 `emittedText` 幾乎沒有共同前綴,
    /// 不會被當成已發出而吞掉。這是相對舊「字元偏移 + shrink-clamp」設計的關鍵改善
    /// —— 舊設計下沒 reset 會把新流第一句整句吞掉(2026-07-15 前的行為)。
    ///
    /// reset 仍保留(見 `MeetingPartialSegmenter.reset` 註解),但即使漏叫,開頭也不再消失。
    func testStreamReplacementDoesNotSwallowOpeningEvenWithoutReset() {
        var segmenter = MeetingPartialSegmenter()

        segmenter.observe(partial: "第一段很長的問題內容在這裡", at: 0)
        _ = segmenter.poll(at: 2.0)

        // 沒 reset,新流吐一段共同前綴為 0 的累積文 → 完整發得出來,不再被吞。
        segmenter.observe(partial: "新的一句", at: 3.0)
        XCTAssertEqual(segmenter.poll(at: 5.0), "新的一句",
                       "共同前綴錨定下,換流的開頭不該被吞掉")
    }

    // MARK: - partial 尾巴修訂(2026-07-15 "e conflict." 斷詞碎片事故)

    /// 雲端 ASR 會修訂自己的 partial 尾巴:句尾先放 `...` 佔位,下一輪換成實字。
    /// 舊「字元偏移」設計把 `...` 位置當成已發出,`dropFirst(偏移)` 從替換文字中間切下去,
    /// 吐出 `"e conflict."` 這種斷詞碎片,再被 fast model 腦補成問題。
    /// 共同前綴錨定後,修訂只影響共同前綴之後的字,替換進來的字**完整保留、不吞詞**。
    func testTailRevisionKeepsReplacedWordsIntact() {
        var segmenter = MeetingPartialSegmenter()

        // 第一段:句尾是 "..." 佔位符,停頓後被切出去。
        segmenter.observe(partial: "efforts to resolve...", at: 0)
        XCTAssertEqual(segmenter.poll(at: 1.0), "efforts to resolve...")

        // ASR 把尾巴 "..." 修訂成實字 " the conflict."(共同前綴 = "efforts to resolve")。
        segmenter.observe(partial: "efforts to resolve the conflict.", at: 2.0)

        // 舊設計會吐 "e conflict."(吞掉 " th");錨定後完整保留替換進來的字。
        XCTAssertEqual(segmenter.poll(at: 3.0), "the conflict.",
                       "尾巴修訂不該把替換進來的字切在詞中間")
    }

    /// partial 縮短再重長(hypothesis 修正)不該重發已發出的完整字、也不該吞字。
    func testShrinkThenRegrowDoesNotDuplicateEmittedPrefix() {
        var segmenter = MeetingPartialSegmenter()

        segmenter.observe(partial: "the space of a week", at: 0)
        XCTAssertEqual(segmenter.poll(at: 1.0), "the space of a week")

        // 縮短(ASR 收回假設)→ 再長出新內容。共同前綴 = "the space of a week"。
        segmenter.observe(partial: "the space of a", at: 2.0)
        segmenter.observe(partial: "the space of a week. US Central Command", at: 3.0)

        XCTAssertEqual(segmenter.poll(at: 4.0), ". US Central Command",
                       "只發共同前綴之後的新內容,不重發已發過的前綴")
    }

    // MARK: - provisionalTail(Stage B:未定稿尾巴)

    /// `provisionalTail` 回目前還沒切成 committed 的尾巴;切段後尾巴變空,且**不動** emitted 偏移。
    func testProvisionalTailReturnsUnemittedTailAndEmptiesAfterSegment() {
        var segmenter = MeetingPartialSegmenter()

        segmenter.observe(partial: "這句還在講", at: 0)
        XCTAssertEqual(segmenter.provisionalTail(), "這句還在講", "還沒切段 → 整段都是未定稿尾巴")

        // 非 mutating:多叫幾次不該改變狀態。
        XCTAssertEqual(segmenter.provisionalTail(), "這句還在講")

        // 停頓切段後,尾巴清空(provisional 據此收掉,不與定稿重複)。
        XCTAssertEqual(segmenter.poll(at: 2.0), "這句還在講")
        XCTAssertEqual(segmenter.provisionalTail(), "", "切段後沒有未定稿尾巴")

        // 新的 partial 接續 → 尾巴只含新增的部分(已發出的前綴不再重複)。
        segmenter.observe(partial: "這句還在講然後又補一段", at: 3.0)
        XCTAssertEqual(segmenter.provisionalTail(), "然後又補一段", "尾巴 = 累積文去掉已發出的前綴")
    }
}
