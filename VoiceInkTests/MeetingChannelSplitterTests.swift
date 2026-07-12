import XCTest
@testable import VoiceInk

/// AC-1:聲道分流正確（講者歸屬）。
///
/// 本測試**跟著 `MeetingChannelLayout.tapFirst` 走**——Task 1 實機量測出來不管是
/// `true` 還是 `false`,`testSplitsRemoteAndLocalByTapChannelCount` 都會驗證**當前設定值**
/// 下的行為正確。另外兩個佈局也各自獨立測,確保兩條路都對。
final class MeetingChannelSplitterTests: XCTestCase {

    // MARK: - AC-1 主案例（跟隨實機量測值）

    /// tapChannelCount=2（stereo tap）、mic 1 聲道 → remote 拿 tap 兩聲道、local 拿 mic 一聲道。
    func testSplitsRemoteAndLocalByTapChannelCount() {
        let tapL: [Float] = [1, 1]
        let tapR: [Float] = [2, 2]
        let mic: [Float] = [9, 9]

        // 依當前（量測後的）佈局組出 buffer list
        let buffers: [[Float]] = MeetingChannelLayout.tapFirst
            ? [tapL, tapR, mic]
            : [mic, tapL, tapR]

        let out = MeetingChannelSplitter.split(
            channelBuffers: buffers,
            tapChannelCount: 2,
            tapFirst: MeetingChannelLayout.tapFirst
        )

        XCTAssertEqual(out.remote, [tapL, tapR], "remote 必須是 tap（對方）的聲道")
        XCTAssertEqual(out.local, [mic], "local 必須是 mic（我）的聲道")
    }

    // MARK: - 兩種佈局各自獨立驗證

    /// tap-first 佈局:[tapL, tapR, mic]
    func testTapFirstLayout() {
        let tapL: [Float] = [1, 1]
        let tapR: [Float] = [2, 2]
        let mic: [Float] = [9, 9]

        let out = MeetingChannelSplitter.split(
            channelBuffers: [tapL, tapR, mic],
            tapChannelCount: 2,
            tapFirst: true
        )

        XCTAssertEqual(out.remote, [tapL, tapR])
        XCTAssertEqual(out.local, [mic])
    }

    /// subdevice-first 佈局:[mic, tapL, tapR]
    func testSubdeviceFirstLayout() {
        let mic: [Float] = [9, 9]
        let tapL: [Float] = [1, 1]
        let tapR: [Float] = [2, 2]

        let out = MeetingChannelSplitter.split(
            channelBuffers: [mic, tapL, tapR],
            tapChannelCount: 2,
            tapFirst: false
        )

        XCTAssertEqual(out.remote, [tapL, tapR])
        XCTAssertEqual(out.local, [mic])
    }

    /// **切反必然被抓到**——這是本模組最大的風險,所以明確斷言兩種佈局的結果**不同**。
    /// 若 splitter 忽略了 `tapFirst`,這個測試會失敗。
    func testLayoutFlagActuallyChangesResult() {
        let a: [Float] = [1, 1]
        let b: [Float] = [2, 2]
        let c: [Float] = [9, 9]
        let buffers = [a, b, c]

        let tapFirstOut = MeetingChannelSplitter.split(channelBuffers: buffers, tapChannelCount: 2, tapFirst: true)
        let subFirstOut = MeetingChannelSplitter.split(channelBuffers: buffers, tapChannelCount: 2, tapFirst: false)

        XCTAssertEqual(tapFirstOut.remote, [a, b])
        XCTAssertEqual(tapFirstOut.local, [c])

        XCTAssertEqual(subFirstOut.remote, [b, c])
        XCTAssertEqual(subFirstOut.local, [a])

        XCTAssertNotEqual(tapFirstOut.remote, subFirstOut.remote, "tapFirst 必須真的改變切分結果")
    }

    // MARK: - 邊界

    /// 麥克風關閉 → 只有 tap 聲道,local 為空。
    func testMicDisabledYieldsEmptyLocal() {
        let out = MeetingChannelSplitter.split(
            channelBuffers: [[1, 1], [2, 2]],
            tapChannelCount: 2,
            tapFirst: true
        )

        XCTAssertEqual(out.remote.count, 2)
        XCTAssertTrue(out.local.isEmpty, "沒有 mic sub-device 時 local 必須為空")
    }

    /// 防守:聲道數比 tapChannelCount 少（不該發生,但不能崩）→ 全部當 remote。
    func testFewerChannelsThanTapCountFallsBackToAllRemote() {
        let out = MeetingChannelSplitter.split(
            channelBuffers: [[1, 1]],
            tapChannelCount: 2,
            tapFirst: true
        )

        XCTAssertEqual(out.remote.count, 1)
        XCTAssertTrue(out.local.isEmpty)
    }

    /// 空輸入 / 非法 tapChannelCount → 空,不崩。
    func testEmptyAndInvalidInput() {
        let empty = MeetingChannelSplitter.split(channelBuffers: [], tapChannelCount: 2, tapFirst: true)
        XCTAssertTrue(empty.remote.isEmpty)
        XCTAssertTrue(empty.local.isEmpty)

        let zeroTap = MeetingChannelSplitter.split(channelBuffers: [[1]], tapChannelCount: 0, tapFirst: true)
        XCTAssertTrue(zeroTap.remote.isEmpty)
        XCTAssertTrue(zeroTap.local.isEmpty)
    }

    /// mono tap（非 stereo）也要正確——不要假設 tap 一定是 2 聲道。
    func testMonoTapWithMic() {
        let tap: [Float] = [1, 1]
        let mic: [Float] = [9, 9]

        let out = MeetingChannelSplitter.split(
            channelBuffers: [tap, mic],
            tapChannelCount: 1,
            tapFirst: true
        )

        XCTAssertEqual(out.remote, [tap])
        XCTAssertEqual(out.local, [mic])
    }

    // MARK: - RMS probe（Task 1 的 debug 輔助）

    func testChannelRMS() {
        // RMS of [1, -1] = 1.0；RMS of [0, 0] = 0
        let rms = MeetingChannelLayout.channelRMS(channelBuffers: [[1, -1], [0, 0]], frameCount: 2)
        XCTAssertEqual(rms.count, 2)
        XCTAssertEqual(rms[0], 1.0, accuracy: 1e-5)
        XCTAssertEqual(rms[1], 0.0, accuracy: 1e-5)
    }

    /// probe 的 log 字串必須把 remote / local 分開標示,否則人工判讀不了。
    func testDescribeSplitsRemoteAndLocal() {
        let s = MeetingChannelLayout.describe(rms: [0.5, 0.5, 0.001], tapChannelCount: 2, tapFirst: true)
        XCTAssertTrue(s.contains("REMOTE[0.5000, 0.5000]"), s)
        XCTAssertTrue(s.contains("LOCAL[0.0010]"), s)
    }
}
