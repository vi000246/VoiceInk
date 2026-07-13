import Foundation

/// Aggregate device 的 `AudioBufferList` 聲道順序。
///
/// # ⚠️ 這個值必須實機量測，不可推導
///
/// `MeetingCaptureService.createTapAndAggregate` 建立的 private aggregate 同時掛了
/// process tap（`kAudioAggregateDeviceTapListKey`,系統音＝**對方**）與麥克風 sub-device
/// （`kAudioAggregateDeviceSubDeviceListKey`,＝**我**）。單次 IOProc callback 的
/// `AudioBufferList` 會同時帶到兩者且天生 sample-aligned
/// （見 `MeetingCaptureService.swift` 檔頭註解 :19-23）。
///
/// **但 CoreAudio 沒有任何文件保證兩者在 buffer list 中的先後順序**,composition dictionary
/// 裡 key 的擺放順序**不代表** stream 順序。因此 `tapFirst` 只能靠實機量測決定。
///
/// ## 切反的後果
///
/// remote 與 local 顛倒 → 整個 meeting-copilot 會把「**我自己講的話**」當成
/// 「**對方問的問題**」,而且症狀極隱晦（逐字稿看起來都正常,只是講者標錯）。
///
/// ## 如何量測（照做一次即可，之後填回 `tapFirst`）
///
/// 1. `make deploy`,啟用 copilot（設定 `meetingCopilotEnabledV1 = true`）。
/// 2. 開始會議錄製。開 Console.app,過濾 `🎚️`。
/// 3. **情境 A（找 tap）**:把系統設定的**麥克風輸入音量調到 0**（或拔掉麥克風）,
///    然後用喇叭/耳機播放音樂 → log 中**有能量的那組聲道 = tap（remote）**。
/// 4. **情境 B（找 mic，反向驗證）**:把**系統音量靜音**（無輸出）,對著麥克風說話
///    → log 中**有能量的那組聲道 = mic（local）**。
/// 5. **兩個情境必須互補**（A 有能量的聲道,B 應該安靜；反之亦然）。
///    **若不互補 → 停下來**,代表假設有問題,不要硬填值。
/// 6. 把結論寫進下方 `tapFirst`,並補上量測日期／機器／macOS 版本。
///
/// 典型情況:tap 是 stereo（`stereoGlobalTapButExcludeProcesses` → 2 聲道）,mic 是 mono
/// （1 聲道）,所以 `totalChannels == 3`。**但不要假設——讓 probe 告訴你真相。**
enum MeetingChannelLayout {

    /// `true` = tap（系統音／對方）的聲道排在 mic（我）之前。
    ///
    /// - Note: **實機量測結果:mic 在前,tap 在後 → `false`。**
    ///   量測方法:🎚️ probe(LiveMeetingAudioSource)觀察 Google 翻譯 TTS 經系統音訊
    ///   播放時的逐聲道 RMS——ch0 恆為 ~0.01 的類比噪音底(靜音時也不歸零 = mic);
    ///   ch1/ch2 在 TTS 播放時能量**位元級相同**(同一 mono 訊號的立體聲兩路 = tap),
    ///   數位靜音時精確為 0.0000。composition dictionary 的 key 順序果然不代表
    ///   stream 順序——aggregate 把 sub-device(mic)排在 tap 之前。
    ///
    ///   量測日期:2026-07-13
    ///   量測機器:Logan 的 Mac(Darwin 25.5.0)
    ///   證據:log 260713 13:23 場次,`🎚️ REMOTE[0.0144, 0.1931] | LOCAL[0.1931]`
    static let tapFirst: Bool = false

    /// 這個值是否已經過實機驗證。`false` 時 `LiveMeetingAudioSource` 會在啟動時
    /// 印一則 warning,提醒使用者跑 probe——避免「以為量過了其實沒有」。
    static let isVerified: Bool = true

    /// 逐聲道 RMS。供 probe 與 debug log 使用（純函式,可測）。
    ///
    /// - Parameters:
    ///   - channelBuffers: deinterleave 後的逐聲道樣本
    ///   - frameCount: 本輪 frame 數
    /// - Returns: 每個聲道的 RMS。長度 == `channelBuffers.count`。
    static func channelRMS(channelBuffers: [[Float]], frameCount: Int) -> [Float] {
        guard frameCount > 0 else { return channelBuffers.map { _ in 0 } }
        return channelBuffers.map { ch in
            guard ch.count >= frameCount else { return 0 }
            var sum: Float = 0
            for i in 0..<frameCount {
                sum += ch[i] * ch[i]
            }
            return (sum / Float(frameCount)).squareRoot()
        }
    }

    /// 把 RMS 陣列格式化成可讀的 log 字串,標出 splitter 目前認定的切點。
    ///
    /// 例:`tapFirst=true tapCh=2 | REMOTE[0.0421, 0.0398] | LOCAL[0.0002]`
    /// → tap 兩聲道有能量、mic 幾乎靜音 = 情境 A 的預期結果 → `tapFirst = true` 正確。
    static func describe(rms: [Float], tapChannelCount: Int, tapFirst: Bool) -> String {
        guard !rms.isEmpty else { return "（無聲道）" }
        let fmt: (Float) -> String = { String(format: "%.4f", $0) }

        guard rms.count > tapChannelCount, tapChannelCount > 0 else {
            return "tapFirst=\(tapFirst) tapCh=\(tapChannelCount) | ALL[\(rms.map(fmt).joined(separator: ", "))]（無 mic sub-device）"
        }

        let remote: [Float]
        let local: [Float]
        if tapFirst {
            remote = Array(rms[0..<tapChannelCount])
            local = Array(rms[tapChannelCount...])
        } else {
            let localCount = rms.count - tapChannelCount
            remote = Array(rms[localCount...])
            local = Array(rms[0..<localCount])
        }

        return "tapFirst=\(tapFirst) tapCh=\(tapChannelCount) | "
            + "REMOTE[\(remote.map(fmt).joined(separator: ", "))] | "
            + "LOCAL[\(local.map(fmt).joined(separator: ", "))]"
    }
}
