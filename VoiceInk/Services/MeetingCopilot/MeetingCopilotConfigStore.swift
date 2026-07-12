import Foundation
import Combine

/// meeting-copilot 的設定。
///
/// **M1 只含音訊骨幹需要的三項**;模型選擇（fast/deep）、熱鍵、接地開關（brief / RAG / 螢幕 OCR）、
/// overlay 行為等屬於 M2–M4。
///
/// 樣式鏡射 `RecorderConfigStore`:`@Published private(set)` + `…V1` UserDefaults key + `set…()` mutator。
@MainActor
final class MeetingCopilotConfigStore: ObservableObject {

    static let shared = MeetingCopilotConfigStore()

    // MARK: - Keys

    private let copilotEnabledKey = "meetingCopilotEnabledV1"
    private let asrModelNameKey = "meetingCopilotASRModelV1"
    private let transcribeLocalMicKey = "meetingCopilotTranscribeLocalMicV1"

    // MARK: - Settings

    /// 總開關（kill switch）。**預設 false**。
    ///
    /// 關閉時 `MeetingCaptureService` 不會建立 ring buffer,`MeetingCaptureContext.pcmSink` 為 nil,
    /// `handleIO` 的 seam 只剩一次 nil 檢查 → **realtime thread 零額外工作、零 ASR、零 LLM、零成本**。
    /// 亦即:未啟用時本模組對既有 app 的行為與效能影響為零。
    @Published private(set) var copilotEnabled: Bool = false

    /// 即時轉錄模型。預設本機 FluidAudio Parakeet（免 API key、免網路往返、隱私）。
    ///
    /// - Important: **本機 ASR 不支援術語偏置。** `VocabularyWord` 字典只接到雲端串流 provider
    ///   （`DeepgramStreamingProvider.swift:32`、`SpeechmaticsStreamingProvider.swift:32`、
    ///   `SonioxStreamingProvider.swift:32` 的 `getCustomVocabularyTerms()`）;FluidAudio 完全沒有
    ///   這條路徑。所以「免費 + 隱私」與「專案代號不會被轉錯」**無法兩全**——M4 的設定 UI
    ///   必須把這個取捨明白告訴使用者,因為術語轉錯會直接讓 cue 抽取失準。
    @Published private(set) var asrModelName: String = "parakeet-tdt-0.6b-v3"

    /// 是否也即時轉錄我自己的麥克風（local 流）。
    ///
    /// 關閉可省一條 ASR 的 CPU/電力。注意:cue 偵測**只讀 remote 流**,所以關掉這個
    /// 不影響核心功能,只是 AI 少了「我已經說過什麼」的上下文。
    @Published private(set) var transcribeLocalMic: Bool = true

    // MARK: - Init

    init() {
        load()
    }

    private func load() {
        let d = UserDefaults.standard

        copilotEnabled = d.bool(forKey: copilotEnabledKey)   // 未設定 → false

        if let m = d.string(forKey: asrModelNameKey), !m.isEmpty {
            asrModelName = m
        }

        if d.object(forKey: transcribeLocalMicKey) != nil {
            transcribeLocalMic = d.bool(forKey: transcribeLocalMicKey)
        }
    }

    // MARK: - Mutators

    func setCopilotEnabled(_ value: Bool) {
        copilotEnabled = value
        UserDefaults.standard.set(value, forKey: copilotEnabledKey)
    }

    func setASRModelName(_ value: String) {
        asrModelName = value
        UserDefaults.standard.set(value, forKey: asrModelNameKey)
    }

    func setTranscribeLocalMic(_ value: Bool) {
        transcribeLocalMic = value
        UserDefaults.standard.set(value, forKey: transcribeLocalMicKey)
    }
}
