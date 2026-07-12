import Foundation

/// 把 deinterleave 後的逐聲道緩衝，依「tap 聲道數」切成 **remote（對方）** 與 **local（我）**。
/// 純函式，供 consumer thread 與單元測試共用。
///
/// # 這是 meeting-copilot 講者歸屬的唯一來源——不使用 diarization
///
/// `MeetingCaptureService` 的 private aggregate 同時掛了 process tap（系統音＝會議中其他人）
/// 與麥克風 sub-device（＝我自己）,兩者在**同一個 IOProc callback 的 `AudioBufferList` 中
/// 天生 sample-aligned**（見 `MeetingCaptureService.swift` 檔頭註解 :19-23）。
///
/// `MeetingAudioMixer.mixToMono` 會把所有聲道**等權平均**壓成單聲道——講者資訊在那一刻
/// 不可逆地消失。因此本 splitter 必須在 `mixToMono` **之前**取走資料。
///
/// 這麼做的結果:「這句是對方說的」變成**結構上已知**,100% 準確、零成本、零延遲。
/// 對照組——串流轉錄路徑**完全沒有 speaker 欄位**,而 diarization 只存在於批次 ElevenLabs
/// 整檔路徑且與串流互斥。
enum MeetingChannelSplitter {

    /// - Parameters:
    ///   - channelBuffers: deinterleave 後的逐聲道樣本（`MeetingCaptureContext.channelScratch`）
    ///   - tapChannelCount: tap 的聲道數（`kAudioTapPropertyFormat` 讀得,經 `GraphRates` 傳入）
    ///   - tapFirst: aggregate 的 buffer 順序是否 tap 在前（`MeetingChannelLayout.tapFirst`,**實機量測值**）
    /// - Returns: `(remote, local)`。麥克風未啟用（或聲道數 <= tapChannelCount）時 `local` 為空。
    static func split(
        channelBuffers: [[Float]],
        tapChannelCount: Int,
        tapFirst: Bool
    ) -> (remote: [[Float]], local: [[Float]]) {
        guard !channelBuffers.isEmpty, tapChannelCount > 0 else { return ([], []) }

        let total = channelBuffers.count

        // 聲道數 <= tap 聲道數 → 沒有 mic sub-device,全部都是 tap。
        // （麥克風關閉,或 defaultInputDeviceUID() 取不到裝置——後者在
        //   MeetingCaptureService.swift:417-419 會 warning 並只錄系統音。）
        guard total > tapChannelCount else { return (channelBuffers, []) }

        if tapFirst {
            return (
                remote: Array(channelBuffers[0..<tapChannelCount]),
                local: Array(channelBuffers[tapChannelCount...])
            )
        } else {
            let localCount = total - tapChannelCount
            return (
                remote: Array(channelBuffers[localCount...]),
                local: Array(channelBuffers[0..<localCount])
            )
        }
    }
}
