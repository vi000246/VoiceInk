import Foundation

/// Realtime-safe PCM sink。
///
/// # ⚠️ 實作必須 lock-free 且不得配置記憶體
///
/// `write` 會在 **HAL realtime thread** 上被呼叫（`MeetingCaptureContext.handleIO`）。
/// 禁止:加鎖、配置（`Array` 增長 / `Data` 建立）、I/O、Swift runtime 的動態派送。
///
/// # 誠實的現況
///
/// 既有的 `handleIO` **本來就已經在 realtime thread 上配置記憶體**——
/// `MeetingAudioMixer.mixToMono` 每個 callback 都會 `var acc = [Float](repeating: 0, ...)`
/// 與 `var out = [Float](...)`（見 `MeetingAudioMixer.swift:17, 29`）。
/// 也就是說「零配置」這條線在既有程式碼裡已經破了。
///
/// 因此本 sink 的標準是:**做的事必須嚴格少於 mixToMono 已經在做的**。
/// 實作上就是只把 `channelScratch` memcpy 進**預先配置好**的 slot——
/// 切分（`MeetingChannelSplitter`）與降頻（`PCMDownsampler`）全部在 consumer 側做。
protocol MeetingPCMSink: AnyObject, Sendable {
    /// 從 realtime thread 呼叫。
    ///
    /// - Parameters:
    ///   - channelBuffers: deinterleave 後的逐聲道樣本（即 `MeetingCaptureContext.channelScratch`）。
    ///     呼叫端持有,**sink 只讀不改**。
    ///   - channelCount: 本輪的總聲道數（tap + mic）
    ///   - frameCount: 本輪的 frame 數
    ///   - sampleRate: aggregate 的取樣率
    func write(channelBuffers: [[Float]], channelCount: Int, frameCount: Int, sampleRate: Double)
}
