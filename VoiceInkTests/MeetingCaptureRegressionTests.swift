import XCTest
@testable import VoiceInk

/// AC-2:meeting-copilot 的 realtime seam **不得改變寫進 AAC 的樣本**。
///
/// `handleIO` 的落檔路徑是 deinterleave → `MeetingAudioMixer.mixToMono` → `ExtAudioFileWriteAsync`。
/// copilot 的 seam 插在 `mixToMono` **之前**且**只讀不改** `channelScratch`,
/// 因此 `mixToMono` 的輸入與輸出都必須逐位元不變。
///
/// **這個測試必須在動 `handleIO` 之前就是綠的**——那條路徑寫的是使用者真實會議的錄音檔,
/// 改壞了會先失去一整場會議的錄音才發現。
final class MeetingCaptureRegressionTests: XCTestCase {

    /// Golden:固定的 3 聲道輸入 → 固定的 mono 輸出。
    /// 這組值在 seam 加入前後必須完全一致。
    func testMixToMonoGoldenOutputUnchanged() {
        let tapL: [Float] = [0.10, -0.20, 0.30, -0.40]
        let tapR: [Float] = [0.50, -0.60, 0.70, -0.80]
        let mic: [Float] = [0.90, -1.00, 0.05, -0.15]

        let mono = MeetingAudioMixer.mixToMono(
            channelBuffers: [tapL, tapR, mic],
            frameCount: 4
        )

        // 等權平均:
        //  (0.10 + 0.50 + 0.90) / 3 =  0.50
        //  (-0.20 - 0.60 - 1.00) / 3 = -0.60
        //  (0.30 + 0.70 + 0.05) / 3 =  0.35
        //  (-0.40 - 0.80 - 0.15) / 3 = -0.45
        let expected: [Float] = [0.50, -0.60, 0.35, -0.45]

        XCTAssertEqual(mono.count, 4)
        for (i, e) in expected.enumerated() {
            XCTAssertEqual(mono[i], e, accuracy: 1e-5, "frame \(i)")
        }
    }

    /// 只有 tap（麥克風關閉）時的 golden——會議設定可關麥克風,這條路徑也要鎖住。
    func testMixToMonoTapOnlyGoldenUnchanged() {
        let tapL: [Float] = [1.0, -1.0]
        let tapR: [Float] = [0.0, 0.0]

        let mono = MeetingAudioMixer.mixToMono(channelBuffers: [tapL, tapR], frameCount: 2)

        XCTAssertEqual(mono.count, 2)
        XCTAssertEqual(mono[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(mono[1], -0.5, accuracy: 1e-5)
    }

    /// `mixToMono` 對非法輸入的防守行為也一併鎖住（seam 不得改變它）。
    func testMixToMonoRejectsShortChannels() {
        // 第二個聲道長度不足 frameCount → 既有實作回傳 []
        let out = MeetingAudioMixer.mixToMono(channelBuffers: [[1, 2, 3], [1]], frameCount: 3)
        XCTAssertTrue(out.isEmpty, "長度不足的聲道必須被視為無效輸入")
    }
}
