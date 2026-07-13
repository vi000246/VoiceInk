import Foundation

/// 「我說話時 overlay 淡出」的純狀態機(FR-25 / AC-17)。
///
/// 免 UI、免 timer:音訊 frame 在會議中持續抵達(靜音時 RMS≈0 也回報),
/// 所以每個樣本進來時**重新判定**當下不透明度即可,不需排程恢復。
/// 呼叫端(`CopilotOverlayWindowManager`)拿回傳值去設 `panel.alphaValue`。
///
/// ⚠️ 門檻已知限制(umbrella SRS Risks):喇叭外放(不戴耳機)時對方聲音會經
/// mic 誤觸發淡出。門檻最終值待實機調校;M4 先取 0.02(正規化 Float 樣本)。
struct OverlayDimmingModel {

    /// RMS 超過此值視為「我在說話」。
    var threshold: Float = 0.02
    /// 停止說話後多久恢復(秒)。
    var recoveryDelay: TimeInterval = 1.5
    /// 說話時的目標不透明度(來自 `MeetingCopilotConfigStore.speakingOpacity`)。
    var speakingOpacity: Double = 0.35

    private var lastVoiceAt: TimeInterval = -.infinity

    init(speakingOpacity: Double = 0.35) {
        self.speakingOpacity = speakingOpacity
    }

    /// 回傳此刻 overlay 該有的不透明度。
    mutating func update(rms: Float, at now: TimeInterval) -> Double {
        if rms >= threshold {
            lastVoiceAt = now
        }
        return (now - lastVoiceAt) < recoveryDelay ? speakingOpacity : 1.0
    }

    /// 多聲道 RMS(全聲道樣本平方均值開根)。純函式,樣不足回 0 不越界。
    static func rms(channelBuffers: [[Float]], frameCount: Int) -> Float {
        guard frameCount > 0, !channelBuffers.isEmpty,
              channelBuffers.allSatisfy({ $0.count >= frameCount }) else { return 0 }
        var sum: Float = 0
        for channel in channelBuffers {
            for i in 0..<frameCount {
                sum += channel[i] * channel[i]
            }
        }
        return (sum / Float(frameCount * channelBuffers.count)).squareRoot()
    }
}
