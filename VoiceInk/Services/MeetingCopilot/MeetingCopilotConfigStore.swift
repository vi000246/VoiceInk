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
    private let asrLanguageKey = "meetingCopilotASRLanguageV1"
    private let transcribeLocalMicKey = "meetingCopilotTranscribeLocalMicV1"

    // Keys(M2 新增)
    private let fastProviderKey = "meetingCopilotFastProviderV1"
    private let fastModelKey = "meetingCopilotFastModelV1"
    private let showInformationalCuesKey = "meetingCopilotShowInformationalCuesV1"

    // Keys(M3 新增：deep model + 三層/接地開關)
    private let deepProviderKey = "meetingCopilotDeepProviderV1"
    private let deepModelKey = "meetingCopilotDeepModelV1"
    private let prefetchEnabledKey = "meetingCopilotPrefetchV1"
    private let domainPersonaKey = "meetingCopilotPersonaV1"
    private let useHistoryRAGKey = "meetingCopilotUseRAGV1"
    private let useScreenContextKey = "meetingCopilotUseScreenV1"

    // Keys(M4 新增：overlay 行為)
    private let overlayClickThroughKey = "meetingCopilotOverlayClickThroughV1"
    private let maxCuesShownKey = "meetingCopilotMaxCuesShownV1"

    // Keys(M8 新增：個人筆記 RAG)
    private let useNotesRAGKey = "meetingCopilotUseNotesRAGV1"
    private let notesInTechnicalRAGKey = "meetingCopilotNotesInTechnicalRAGV1"

    // MARK: - Settings

    /// 總開關（kill switch）。**預設 true**（2026-07-13 依使用者要求改:會議錄製時
    /// 預設就開啟即時監聽,不必每次手動開）。
    ///
    /// 關閉時 `MeetingCaptureService` 不會建立 ring buffer,`MeetingCaptureContext.pcmSink` 為 nil,
    /// `handleIO` 的 seam 只剩一次 nil 檢查 → **realtime thread 零額外工作、零 ASR、零 LLM、零成本**。
    @Published private(set) var copilotEnabled: Bool = true

    /// 即時轉錄模型。預設本機 FluidAudio Parakeet（免 API key、免網路往返、隱私）。
    ///
    /// - Important: **本機 ASR 不支援術語偏置。** `VocabularyWord` 字典只接到雲端串流 provider
    ///   （`DeepgramStreamingProvider.swift:32`、`SpeechmaticsStreamingProvider.swift:32`、
    ///   `SonioxStreamingProvider.swift:32` 的 `getCustomVocabularyTerms()`）;FluidAudio 完全沒有
    ///   這條路徑。所以「免費 + 隱私」與「專案代號不會被轉錯」**無法兩全**——M4 的設定 UI
    ///   必須把這個取捨明白告訴使用者,因為術語轉錯會直接讓 cue 抽取失準。
    @Published private(set) var asrModelName: String = "parakeet-tdt-0.6b-v3"

    /// 即時轉錄語言(語言碼,格式依所選模型的 `supportedLanguages`)。預設 "auto"。
    ///
    /// - Important: **"auto" 對非目標語言可能整段誤判**——實測(2026-07-13)Parakeet V3
    ///   auto 模式把中文 TTS 轉成俄語亂碼,cue 偵測全滅。中文會議必須選支援 zh 的模型
    ///   (Nemotron Multilingual / 雲端)並明確指定語言。
    @Published private(set) var asrLanguage: String = "auto"

    /// 是否也即時轉錄我自己的麥克風（local 流）。
    ///
    /// 關閉可省一條 ASR 的 CPU/電力。注意:cue 偵測**只讀 remote 流**,所以關掉這個
    /// 不影響核心功能,只是 AI 少了「我已經說過什麼」的上下文。
    @Published private(set) var transcribeLocalMic: Bool = true

    // MARK: - Settings(M2 新增：cue 抽取的 fast model + informational 暴露開關)

    /// cue 抽取用的 fast model(provider rawValue)。nil = 跟隨 AI Models 的預設 provider
    /// (經 `AskAIAnswerModel.resolve` 解析,見 MeetingCopilotController.makeFastCompleter)。
    @Published private(set) var fastProviderName: String?
    /// fast model 名稱。nil = 用該 provider 的預設 model。
    @Published private(set) var fastModelName: String?
    /// FR-11:informational cue 是否納入 `MeetingCopilotController.cues` 暴露面。
    /// **預設 false**(仍會 persist,只是引擎層不暴露);UI 切換屬 M5。
    @Published private(set) var showInformationalCues: Bool = false

    // MARK: - Settings(M3 新增：deep model + 三層回應/接地)

    /// Tier 2 的 deep model(provider rawValue)。nil = 跟隨 AI Models 預設 provider。
    @Published private(set) var deepProviderName: String?
    /// deep model 名稱。nil = 用該 provider 的預設 model。
    @Published private(set) var deepModelName: String?
    /// FR-15:最新一則 cue 自動預跑 Tier 1。**預設 true**。
    @Published private(set) var prefetchEnabled: Bool = true
    /// 注入所有 tier system prompt 的 persona(讓答案針對領域)。
    @Published private(set) var domainPersona: String = "你是資深後端工程師,專精分散式系統設計與演算法。"
    /// FR-19:是否以歷史逐字稿 RAG 接地。**預設 false**(2026-07-13 依使用者要求改:
    /// 接地讓 Tier 1/2 各多等數秒~十餘秒,先求快;要接地的人自行到設定頁開)。
    @Published private(set) var useHistoryRAG: Bool = false
    /// FR-20:是否在 Tier 2 擷取分享畫面 OCR 接地。**預設 false**(同上;螢幕截圖+OCR 最耗時)。
    @Published private(set) var useScreenContext: Bool = false

    // MARK: - Settings(M4 新增：overlay 行為;設定頁 UI row 屬 M5)

    /// 點擊穿透。決定 `CopilotOverlayPanel.ignoresMouseEvents`。預設 false(可點 cue 觸發 Tier 2)。
    @Published private(set) var overlayClickThrough: Bool = false
    // (原 FR-25「我說話時淡出」的 speakingOpacity 已整個移除——2026-07-13 依使用者要求,
    //  overlay 恆為不透明。)

    /// overlay 最多列出幾則 cue(FR-26)。夾在 [1, 20]。
    @Published private(set) var maxCuesShown: Int = 5

    // MARK: - Settings(M8 新增：個人筆記 RAG;設定頁 UI 屬 Task 7)

    /// M8 FR-47:aboutMe cue 是否以個人筆記(obsidian)RAG 接地。**預設 true**——
    /// 這是 aboutMe 路由的總開關,獨立於 `useHistoryRAG`(被問到自己的經歷時,
    /// 逐字稿歷史沒有答案,筆記才有;不該被「先求快」的 RAG 預設關掉)。
    /// 未建筆記索引時 retrieve 自然回空,無額外成本。
    @Published private(set) var useNotesRAG: Bool = true
    /// M8:技術 cue 檢索是否也納入個人筆記。**預設 false**——技術答案不被個人筆記
    /// 污染(既有行為不變的 NFR);要混用的人到設定頁顯式開啟。
    @Published private(set) var notesInTechnicalRAG: Bool = false

    // MARK: - Init

    init() {
        load()
    }

    private func load() {
        let d = UserDefaults.standard

        copilotEnabled = (d.object(forKey: copilotEnabledKey) as? Bool) ?? true   // 未設定 → true

        if let m = d.string(forKey: asrModelNameKey), !m.isEmpty {
            asrModelName = m
        }

        if let l = d.string(forKey: asrLanguageKey), !l.isEmpty {
            asrLanguage = l
        }

        if d.object(forKey: transcribeLocalMicKey) != nil {
            transcribeLocalMic = d.bool(forKey: transcribeLocalMicKey)
        }

        fastProviderName = d.string(forKey: fastProviderKey)
        fastModelName = d.string(forKey: fastModelKey)
        showInformationalCues = d.bool(forKey: showInformationalCuesKey)   // 未設定 → false

        deepProviderName = d.string(forKey: deepProviderKey)
        deepModelName = d.string(forKey: deepModelKey)
        prefetchEnabled = (d.object(forKey: prefetchEnabledKey) as? Bool) ?? true   // 預設 true
        if let p = d.string(forKey: domainPersonaKey), !p.isEmpty { domainPersona = p }
        useHistoryRAG = (d.object(forKey: useHistoryRAGKey) as? Bool) ?? false
        useScreenContext = (d.object(forKey: useScreenContextKey) as? Bool) ?? false

        overlayClickThrough = d.bool(forKey: overlayClickThroughKey)   // 未設定 → false
        if d.object(forKey: maxCuesShownKey) != nil {
            maxCuesShown = min(max(d.integer(forKey: maxCuesShownKey), 1), 20)
        }

        useNotesRAG = (d.object(forKey: useNotesRAGKey) as? Bool) ?? true   // 未設定 → true
        notesInTechnicalRAG = (d.object(forKey: notesInTechnicalRAGKey) as? Bool) ?? false
    }

    // MARK: - Mutators

    /// nil = removeObject（鏡射 RecorderConfigStore.persistString）。
    private func persistString(_ value: String?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func setCopilotEnabled(_ value: Bool) {
        copilotEnabled = value
        UserDefaults.standard.set(value, forKey: copilotEnabledKey)
    }

    func setFastModel(provider: String?, model: String?) {
        fastProviderName = provider
        fastModelName = model
        persistString(provider, fastProviderKey)
        persistString(model, fastModelKey)
    }

    func setShowInformationalCues(_ value: Bool) {
        showInformationalCues = value
        UserDefaults.standard.set(value, forKey: showInformationalCuesKey)
    }

    func setASRModelName(_ value: String) {
        asrModelName = value
        UserDefaults.standard.set(value, forKey: asrModelNameKey)
    }

    func setASRLanguage(_ value: String) {
        asrLanguage = value
        UserDefaults.standard.set(value, forKey: asrLanguageKey)
    }

    func setTranscribeLocalMic(_ value: Bool) {
        transcribeLocalMic = value
        UserDefaults.standard.set(value, forKey: transcribeLocalMicKey)
    }

    // MARK: - Mutators(M3)

    func setDeepModel(provider: String?, model: String?) {
        deepProviderName = provider
        deepModelName = model
        persistString(provider, deepProviderKey)
        persistString(model, deepModelKey)
    }

    func setPrefetchEnabled(_ value: Bool) {
        prefetchEnabled = value
        UserDefaults.standard.set(value, forKey: prefetchEnabledKey)
    }

    func setDomainPersona(_ value: String) {
        domainPersona = value
        UserDefaults.standard.set(value, forKey: domainPersonaKey)
    }

    func setUseHistoryRAG(_ value: Bool) {
        useHistoryRAG = value
        UserDefaults.standard.set(value, forKey: useHistoryRAGKey)
    }

    func setUseScreenContext(_ value: Bool) {
        useScreenContext = value
        UserDefaults.standard.set(value, forKey: useScreenContextKey)
    }

    // MARK: - Mutators(M4 overlay)

    func setOverlayClickThrough(_ value: Bool) {
        overlayClickThrough = value
        UserDefaults.standard.set(value, forKey: overlayClickThroughKey)
    }

    func setMaxCuesShown(_ value: Int) {
        let clamped = min(max(value, 1), 20)
        maxCuesShown = clamped
        UserDefaults.standard.set(clamped, forKey: maxCuesShownKey)
    }

    // MARK: - Mutators(M8 筆記 RAG)

    func setUseNotesRAG(_ value: Bool) {
        useNotesRAG = value
        UserDefaults.standard.set(value, forKey: useNotesRAGKey)
    }

    func setNotesInTechnicalRAG(_ value: Bool) {
        notesInTechnicalRAG = value
        UserDefaults.standard.set(value, forKey: notesInTechnicalRAGKey)
    }
}
