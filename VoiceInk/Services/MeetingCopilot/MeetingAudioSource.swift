import Foundation

/// 一輪音訊:**已經切分好**的「對方」與「我」。
struct MeetingAudioFrame {
    /// 對方(system tap 的聲道)。
    let remote: [[Float]]
    /// 我(mic sub-device 的聲道)。麥克風未啟用時為空。
    let local: [[Float]]
    let frameCount: Int
    let sampleRate: Double
}

/// 會議音源的**注入層**。
///
/// # 這是整個離線驗證流程的地基
///
/// `LiveMeetingAudioSource`(CoreAudio)與 `ReplayMeetingAudioSource`(預錄 WAV)是它的兩個實作,
/// 而 **source 以下的一切完全相同**:降頻 → 雙路 ASR → (M2)cue 偵測 → 三層回應。
/// 因此 replay 驗證的是**真正要上線的那條 pipeline**,不是平行的假貨。
///
/// # 它不只是「好架構」——它是測試能不能存在的前提
///
/// 專案記憶 `voiceink-running-unit-tests` 明載:`VoiceInkTests` 是 **host-app** 測試 bundle,
/// runner 會啟動 `VoiceInk.app`,而「**CoreAudio `AudioDeviceManager` init 在 headless 下脆弱**」。
/// 沒有這層注入,整條 pipeline 在 XCTest 裡根本跑不起來。
protocol MeetingAudioSource: AnyObject {
    func start() async throws
    func stop() async
    /// 已切分好的音訊流。
    var frames: AsyncStream<MeetingAudioFrame> { get }
}
