import Foundation
import Combine

/// `MeetingCopilotConfigStore` 的設定後端（正式 = `UserDefaults.standard`）。
///
/// 為什麼要這層抽象、而不是直接注入一個 `UserDefaults(suiteName:)`：**suite 擋不住讀取的
/// fallthrough**。`UserDefaults(suiteName:)` 只是把 suite **加進** search list，讀取仍會往下
/// 掉到 app 自己的 domain（`com.prakashjoshipax.VoiceInk`）——於是測試斷言「未設定 → 預設值」時，
/// 讀到的是**開發機上這個 app 的真實設定**，紅燈與程式碼無關（2026-07-14 踩過）。
/// 要真正隔離，就得換掉整個後端，而不是換一個 domain。
protocol MeetingCopilotDefaults: AnyObject {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: MeetingCopilotDefaults {}

/// M9 FR-73:深答（Tier 2）的輸出密度。
///
/// **條列式是預設**——現行的段落式分析在會議進行中根本讀不完:對方講完話的那幾秒裡,
/// 眼睛只掃得過三、四個要點,掃不過三段散文。這是刻意的行為變更,不是保守預設。
/// `detailed` 保留給會後覆盤/非即時場景。
enum MeetingDeepStyle: String, CaseIterable {
    case bullets, concise, detailed

    var label: String {
        switch self {
        case .bullets: return "條列式（3 秒掃視）"
        case .concise: return "簡潔（2~3 句結論）"
        case .detailed: return "詳細（完整分析）"
        }
    }
}

/// 「截圖深答」的擷取對象(手動視覺功能;`captureCopilotScreenshot` 熱鍵 + overlay 按鈕共用)。
///
/// 與 Tier 2 的螢幕 OCR 接地(`useScreenContext`)不同:那是把畫面轉**文字**塞進 prompt,
/// 這是把畫面當**圖片**餵給支援視覺的深答模型——圖表/投影片/程式碼版面 OCR 讀不出的結構,
/// 圖片才看得懂。純手動、auto-deep 不碰(見 `AnswerCoordinator.requestDeepWithImages`)。
/// 深度分析(Tier 3)的觸發模式(M10)。
///
/// 是**觸發模式**不是模型——深度分析只有一顆深思模型。自動:中度分析自評 `needsDeep` 為真且 cue 可深答時
/// **自動發起**;手動:僅使用者按「深入分析」按鈕。手動按鈕在兩模式恆存在(自動只是多了自動放行)。
enum CopilotDeepTrigger: String, CaseIterable {
    case auto, manual

    var label: String {
        switch self {
        case .auto: return "自動（AI 判斷需要時）"
        case .manual: return "手動（我按按鈕）"
        }
    }
}

enum CopilotScreenshotTarget: String, CaseIterable {
    /// 最前景的外部視窗(重用 OCR 那條 `findActiveWindow`,已自動排除 VoiceInk 自己)。
    case activeWindow
    /// 整個螢幕(排除自己的浮動視窗)。
    case fullScreen
    /// 框選區域——走系統原生 `screencapture -i`(十字準星、Esc 取消)。
    case region

    var label: String {
        switch self {
        case .activeWindow: return "最前景視窗"
        case .fullScreen: return "整個螢幕"
        case .region: return "框選區域"
        }
    }
}

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
    // M10:深思模型(僅深度分析)+ 深度分析觸發模式。舊 deep* key 退役(中度改用即時模型),保留不刪。
    private let deepThinkProviderKey = "meetingCopilotDeepThinkProviderV1"
    private let deepThinkModelKey = "meetingCopilotDeepThinkModelV1"
    private let deepTriggerKey = "meetingCopilotDeepTriggerV1"
    private let prefetchEnabledKey = "meetingCopilotPrefetchV1"
    private let domainPersonaKey = "meetingCopilotPersonaV1"
    private let useHistoryRAGKey = "meetingCopilotUseRAGV1"
    private let useScreenContextKey = "meetingCopilotUseScreenV1"
    private let screenshotTargetKey = "meetingCopilotScreenshotTargetV1"

    // Keys(M4 新增：overlay 行為)
    private let overlayClickThroughKey = "meetingCopilotOverlayClickThroughV1"
    private let maxCuesShownKey = "meetingCopilotMaxCuesShownV1"

    // Keys(M8 新增：個人筆記 RAG + auto-deep)
    private let useNotesRAGKey = "meetingCopilotUseNotesRAGV1"
    private let notesInTechnicalRAGKey = "meetingCopilotNotesInTechnicalRAGV1"
    private let aboutMeBriefKey = "meetingCopilotAboutMeBriefV1"
    private let autoDeepEnabledKey = "meetingCopilotAutoDeepV1"

    // Keys(M8 D 組：即時翻譯)
    private let liveTranslationEnabledKey = "meetingCopilotLiveTranslationV1"
    private let translationProviderKey = "meetingCopilotTranslationProviderV1"
    private let translationModelKey = "meetingCopilotTranslationModelV1"
    private let translationSourceLanguageKey = "meetingCopilotTranslationSourceV1"
    private let translationTargetLanguageKey = "meetingCopilotTranslationTargetV1"

    // Keys(M9 新增：深答風格)
    private let deepStyleKey = "meetingCopilotDeepStyleV1"

    // Keys(Prompt 設定：使用者可調 prompt)
    private let answerStyleGuidanceKey = "meetingCopilotAnswerStyleGuidanceV1"
    private let deepStyleGuidanceKey = "meetingCopilotDeepStyleGuidanceV1"
    private let cuePromptOverrideKey = "meetingCopilotCuePromptOverrideV1"

    // MARK: - Prompt 預設

    /// **開口稿 + 中度分析**(即時模型)共用的回答風格與範圍守則,注入這兩段的 system prompt(persona 之後)。
    /// M10 起**只套即時模型的兩段**(深度分析改用 `deepStyleGuidance`,兩者互不干擾——即時要短、深度要深)。
    /// 預設把答案綁在「軟體 + 我的個人專案」範圍、口語淺白、禁生僻術語。空字串 = 不注入。
    static let defaultAnswerStyleGuidance = """
    回答風格與範圍(嚴格遵守):
    - 只回答**軟體/系統/程式工程領域**與**我的個人專案經歷**;超出這兩者的話題(時事、政治、\
    生活雜談、其他專業領域)一律不接話、不生成內容。
    - **口語化、淺顯易懂**,像同事間閒聊那樣講話;不要書面語、不要長句、不要條列術語堆疊。
    - 只有軟體領域才可以用技術名詞,而且要挑**常見、好懂**的詞;會議中我沒空理解太複雜的詞。
    - **絕不丟出我可能沒聽過的專有名詞**——寧可用一句白話解釋概念,也不要拋一個我當場接不住、\
    還要分心去想的術語、縮寫或論文/框架名。真的必須提到時,順帶用半句話講它是什麼。
    """

    /// **深度分析**(深思模型)專用的風格與範圍守則,只注入 Tier 3 的 system prompt(persona 之後)。
    /// 與 `answerStyleGuidance` 拆開:即時那兩段要短要口語,深度這段可以更完整、有推理層次——兩份分開設,
    /// 不再互相拉扯。**密度**(幾條/幾句)另由「深度分析密度」enum 控制,這裡只講「取向/範圍」。空字串 = 不注入。
    static let defaultDeepStyleGuidance = """
    深度分析的取向(嚴格遵守):
    - 針對**軟體/系統/程式工程**與**我的個人專案**做有推理層次的完整回答;不接題外話。
    - 可以比開口稿詳細:多方案要**比較取捨並給出明確判斷**、需要推導就給**關鍵步驟與結論**、\
    設計/決策題給**立場與權衡代價**——不要只列選項。
    - 仍用我聽得懂的白話,技術名詞挑常見好懂的;真要用生僻詞,順帶半句話解釋它是什麼。
    - 只依據我的逐字稿/筆記與已知事實,沒把握的列進 uncertainties,絕不編造數字/論文/公司名。
    """

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

    /// (M10 退役)舊「Tier 2 deep model」設定;M10 起中度分析改用**即時模型**(fast),此設定不再驅動任何 tier。
    /// 保留讀寫與 UserDefaults key,僅為向下相容不破壞,不刪。
    @Published private(set) var deepProviderName: String?
    @Published private(set) var deepModelName: String?

    // MARK: - Settings(M10 新增：深思模型 + 深度分析觸發)

    /// 深思模型(**僅**深度分析 Tier 3 用;推理類)。預設 Gemini / `gemini-2.5-pro`
    /// (ReasoningConfig 認得為 thinking、支援視覺;使用者既有 Gemini key)。
    /// 經 `MeetingCopilotModels.resolve` 解析:provider 未連線時回退預設 provider(可能非推理,屬可接受降級)。
    @Published private(set) var deepThinkProviderName: String? = "Gemini"
    @Published private(set) var deepThinkModelName: String? = "gemini-2.5-pro"
    /// 深度分析觸發模式(自動/手動)。**預設自動**(使用者要「有深度且不想手動」;成本已被 needsDeep 閘門壓住)。
    @Published private(set) var deepTrigger: CopilotDeepTrigger = .auto
    /// FR-15:最新一則 cue 自動預跑 Tier 1。**預設 true**。
    @Published private(set) var prefetchEnabled: Bool = true
    /// 注入所有 tier system prompt 的 persona(讓答案針對領域)。
    static let defaultDomainPersona = "你是資深後端工程師,專精分散式系統設計與演算法。"
    @Published private(set) var domainPersona: String = defaultDomainPersona
    /// FR-19:是否以歷史逐字稿 RAG 接地。**預設 false**(2026-07-13 依使用者要求改:
    /// 接地讓 Tier 1/2 各多等數秒~十餘秒,先求快;要接地的人自行到設定頁開)。
    @Published private(set) var useHistoryRAG: Bool = false
    /// FR-20:是否在 Tier 2 擷取分享畫面 OCR 接地。**預設 false**(同上;螢幕截圖+OCR 最耗時)。
    @Published private(set) var useScreenContext: Bool = false

    /// 「截圖深答」的擷取對象。預設最前景視窗(與 OCR 同源、已自排除自己、最省事)。
    @Published private(set) var screenshotTarget: CopilotScreenshotTarget = .activeWindow

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

    /// M8 FR-48:一兩句話的自介(職稱／年資／主力專案),注入 aboutMe cue 的 tier prompt。
    ///
    /// 為什麼要跟 `domainPersona` 分開:persona 是「用什麼身分回答技術題」(所有 cue 共用);
    /// 自介是「我是誰、我做過什麼」的事實錨,只有被問到我本人時才有意義,而且它與筆記同屬
    /// **事實來源**(模型只能引用,不能延伸)。混進 persona 會讓技術題也開始拿我的履歷說嘴。
    ///
    /// 預設空字串 → prompt 直接略過該行(不留空欄位誤導模型「我沒有自介」)。
    @Published private(set) var aboutMeBrief: String = ""

    // FR-6:索引**範圍**（include/exclude 資料夾清單）不再住這裡——那是筆記管線的設定,
    // Ask AI 與 meeting-copilot 兩個消費者共用,已搬到 `ObsidianRAGConfigStore`(鍵名沿用,
    // 使用者既有設定零遷移)。這裡只留 meeting-copilot 自己的**消費開關**(要不要檢索筆記)。

    /// M8 FR-53:Tier 1 完成後自動接跑 Tier 2(只對「活到最後的最新一則」cue)。**預設 true**——
    /// 手點 Tier 2 這件事在會議中根本做不到:要嘛在聽對方講、要嘛在講話,手離不開;
    /// 等想到要點時分析才開始跑,深答到手已經沒有用了。成本上界是「每則活到最後的 cue 一次 deep」,
    /// 舊 cue 的在途 deep 會被新 cue 取消(latest-only),不會累積。要省錢的人到設定頁關掉。
    @Published private(set) var autoDeepEnabled: Bool = true

    // MARK: - Settings(M8 D 組：即時翻譯;設定頁 UI 屬 Task 19)

    /// M8 FR-62:每段 remote committed 逐字稿即時翻成目標語言,顯示在 overlay 上區。
    /// **預設 false**——這是每段一次 LLM 呼叫的**額外**成本(與 cue 抽取平行,不是取代),
    /// 對單語會議純屬浪費。要用的人到設定頁開(AC-47:關閉時零 API 呼叫)。
    @Published private(set) var liveTranslationEnabled: Bool = false

    /// 翻譯用的 model(provider rawValue)。nil = 跟隨 AI Models 的預設 provider。
    /// 與 fast/deep **各自獨立**:翻譯要的是「便宜、快、量大」(每段都打),
    /// 跟 cue 抽取的判斷力、深度分析的推理力是三種不同取捨。
    @Published private(set) var translationProviderName: String?
    /// 翻譯 model 名稱。nil = 用該 provider 的預設 model。
    @Published private(set) var translationModelName: String?

    /// 來源語言碼。預設 `"auto"` = 不假設輸入語言(混語會議的唯一正解;
    /// 見 `MeetingTranslationPrompt` 檔頭:任何語言偵測器都會在中英夾雜句上判錯)。
    @Published private(set) var translationSourceLanguage: String = "auto"
    /// 目標語言碼。預設繁體中文(本 app 的主要使用情境:聽英文會議、看中文字幕)。
    @Published private(set) var translationTargetLanguage: String = "zh-TW"

    // MARK: - Settings(M9 新增：深答風格)

    /// M9 FR-73:Tier 2 的輸出密度。**預設 `.bullets`**——理由見 `MeetingDeepStyle` 檔頭。
    @Published private(set) var deepStyle: MeetingDeepStyle = .bullets

    // MARK: - Settings(Prompt 設定：使用者可調 prompt)

    /// **開口稿 + 中度分析**(即時模型)的回答風格/範圍守則(注入 tier1/tier2 system prompt)。
    /// 預設見 `defaultAnswerStyleGuidance`;空字串 = 不注入(power user 想完全放開時)。
    @Published private(set) var answerStyleGuidance: String = defaultAnswerStyleGuidance

    /// **深度分析**(深思模型)的風格/範圍守則(只注入 tier3 system prompt;M10 與 answerStyleGuidance 拆開)。
    /// 預設見 `defaultDeepStyleGuidance`;空字串 = 不注入。
    @Published private(set) var deepStyleGuidance: String = defaultDeepStyleGuidance

    /// 問題分類器(cue 偵測)system prompt 的**完整覆寫**。空字串 = 用內建預設
    /// (`ResponseCueExtractor.systemPrompt`)。非空 = 整段取代(進階使用者自負格式契約:
    /// 仍須輸出 `{"cues":[…]}` JSON,否則解析會回空)。
    @Published private(set) var cuePromptOverride: String = ""

    /// 分類器實際使用的 system prompt(override 為空 → 內建預設)。
    var effectiveCuePrompt: String {
        cuePromptOverride.isEmpty ? ResponseCueExtractor.systemPrompt : cuePromptOverride
    }

    // MARK: - Init

    /// 設定的後端。正式一律 `UserDefaults.standard`；**測試務必注入 in-memory 版**——
    /// 測試 target 是 `parallelizable = YES`（每個 test class 一個 process、共用同一個 defaults
    /// domain），任何一個測試往 `.standard` 寫設定，都會跨 process 汙染另一個正在斷言
    /// 「未設定 → 預設值」的測試，變成與被測程式碼無關、且隨排程時隱時現的紅燈。
    private let defaults: MeetingCopilotDefaults

    init(defaults: MeetingCopilotDefaults = UserDefaults.standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        let d = defaults

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
        // M10 深思模型:key 存在才覆寫(否則保留 Gemini/gemini-2.5-pro 預設);
        // 用 object(forKey:) 判存在,讓「使用者顯式清成 auto」也能覆寫掉預設。
        if d.object(forKey: deepThinkProviderKey) != nil { deepThinkProviderName = d.string(forKey: deepThinkProviderKey) }
        if d.object(forKey: deepThinkModelKey) != nil { deepThinkModelName = d.string(forKey: deepThinkModelKey) }
        if let raw = d.string(forKey: deepTriggerKey), let v = CopilotDeepTrigger(rawValue: raw) { deepTrigger = v }
        prefetchEnabled = (d.object(forKey: prefetchEnabledKey) as? Bool) ?? true   // 預設 true
        if let p = d.string(forKey: domainPersonaKey), !p.isEmpty { domainPersona = p }
        useHistoryRAG = (d.object(forKey: useHistoryRAGKey) as? Bool) ?? false
        useScreenContext = (d.object(forKey: useScreenContextKey) as? Bool) ?? false
        if let t = d.string(forKey: screenshotTargetKey), let target = CopilotScreenshotTarget(rawValue: t) {
            screenshotTarget = target
        }

        overlayClickThrough = d.bool(forKey: overlayClickThroughKey)   // 未設定 → false
        if d.object(forKey: maxCuesShownKey) != nil {
            maxCuesShown = min(max(d.integer(forKey: maxCuesShownKey), 1), 20)
        }

        useNotesRAG = (d.object(forKey: useNotesRAGKey) as? Bool) ?? true   // 未設定 → true
        notesInTechnicalRAG = (d.object(forKey: notesInTechnicalRAGKey) as? Bool) ?? false
        autoDeepEnabled = (d.object(forKey: autoDeepEnabledKey) as? Bool) ?? true   // 未設定 → true
        if let b = d.string(forKey: aboutMeBriefKey), !b.isEmpty { aboutMeBrief = b }   // 照 domainPersona

        // M8 D 組:即時翻譯。未設定 → false(AC-47:預設零成本)。
        liveTranslationEnabled = (d.object(forKey: liveTranslationEnabledKey) as? Bool) ?? false
        translationProviderName = d.string(forKey: translationProviderKey)
        translationModelName = d.string(forKey: translationModelKey)
        // 照 domainPersona:空字串視同沒設定(壞設定不該把 prompt 的語言指示清空)。
        if let s = d.string(forKey: translationSourceLanguageKey), !s.isEmpty { translationSourceLanguage = s }
        if let t = d.string(forKey: translationTargetLanguageKey), !t.isEmpty { translationTargetLanguage = t }

        // M9:深答風格。未設定 / 壞 rawValue → 留在預設 .bullets。
        if let raw = d.string(forKey: deepStyleKey), let v = MeetingDeepStyle(rawValue: raw) { deepStyle = v }

        // Prompt 設定。兩者都把「未設定(nil)」與「明確存成空字串」分開:
        // - 從未動過 → 保留各自預設;
        // - 使用者清空 → 存下空字串(guidance 空 = 不注入;cue 空 = 用內建預設)。
        if let g = d.string(forKey: answerStyleGuidanceKey) { answerStyleGuidance = g }
        if let dg = d.string(forKey: deepStyleGuidanceKey) { deepStyleGuidance = dg }
        if let c = d.string(forKey: cuePromptOverrideKey) { cuePromptOverride = c }
    }

    // MARK: - Mutators

    /// nil = removeObject（鏡射 RecorderConfigStore.persistString）。
    private func persistString(_ value: String?, _ key: String) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    func setCopilotEnabled(_ value: Bool) {
        copilotEnabled = value
        defaults.set(value, forKey: copilotEnabledKey)
    }

    func setFastModel(provider: String?, model: String?) {
        fastProviderName = provider
        fastModelName = model
        persistString(provider, fastProviderKey)
        persistString(model, fastModelKey)
    }

    func setShowInformationalCues(_ value: Bool) {
        showInformationalCues = value
        defaults.set(value, forKey: showInformationalCuesKey)
    }

    func setASRModelName(_ value: String) {
        asrModelName = value
        defaults.set(value, forKey: asrModelNameKey)
    }

    func setASRLanguage(_ value: String) {
        asrLanguage = value
        defaults.set(value, forKey: asrLanguageKey)
    }

    func setTranscribeLocalMic(_ value: Bool) {
        transcribeLocalMic = value
        defaults.set(value, forKey: transcribeLocalMicKey)
    }

    // MARK: - Mutators(M3)

    func setDeepModel(provider: String?, model: String?) {
        deepProviderName = provider
        deepModelName = model
        persistString(provider, deepProviderKey)
        persistString(model, deepModelKey)
    }

    // MARK: - Mutators(M10 深思模型 + 深度分析觸發)

    func setDeepThinkModel(provider: String?, model: String?) {
        deepThinkProviderName = provider
        deepThinkModelName = model
        persistString(provider, deepThinkProviderKey)
        persistString(model, deepThinkModelKey)
    }

    func setDeepTrigger(_ value: CopilotDeepTrigger) {
        deepTrigger = value
        defaults.set(value.rawValue, forKey: deepTriggerKey)
    }

    func setPrefetchEnabled(_ value: Bool) {
        prefetchEnabled = value
        defaults.set(value, forKey: prefetchEnabledKey)
    }

    func setDomainPersona(_ value: String) {
        domainPersona = value
        defaults.set(value, forKey: domainPersonaKey)
    }

    func setUseHistoryRAG(_ value: Bool) {
        useHistoryRAG = value
        defaults.set(value, forKey: useHistoryRAGKey)
    }

    func setUseScreenContext(_ value: Bool) {
        useScreenContext = value
        defaults.set(value, forKey: useScreenContextKey)
    }

    func setScreenshotTarget(_ value: CopilotScreenshotTarget) {
        screenshotTarget = value
        defaults.set(value.rawValue, forKey: screenshotTargetKey)
    }

    // MARK: - Mutators(M4 overlay)

    func setOverlayClickThrough(_ value: Bool) {
        overlayClickThrough = value
        defaults.set(value, forKey: overlayClickThroughKey)
    }

    func setMaxCuesShown(_ value: Int) {
        let clamped = min(max(value, 1), 20)
        maxCuesShown = clamped
        defaults.set(clamped, forKey: maxCuesShownKey)
    }

    // MARK: - Mutators(M8 筆記 RAG)

    func setUseNotesRAG(_ value: Bool) {
        useNotesRAG = value
        defaults.set(value, forKey: useNotesRAGKey)
    }

    func setNotesInTechnicalRAG(_ value: Bool) {
        notesInTechnicalRAG = value
        defaults.set(value, forKey: notesInTechnicalRAGKey)
    }

    func setAboutMeBrief(_ value: String) {
        aboutMeBrief = value
        defaults.set(value, forKey: aboutMeBriefKey)
    }

    func setAutoDeepEnabled(_ value: Bool) {
        autoDeepEnabled = value
        defaults.set(value, forKey: autoDeepEnabledKey)
    }

    // MARK: - Mutators(M8 D 組 即時翻譯)

    func setLiveTranslationEnabled(_ value: Bool) {
        liveTranslationEnabled = value
        defaults.set(value, forKey: liveTranslationEnabledKey)
    }

    /// 雙欄 setter,形式照 `setFastModel(provider:model:)`——provider 與 model 是一組,
    /// 分開寫會出現「provider 已換、model 還是舊 provider 的」這種解析不出來的中間狀態。
    func setTranslationModel(provider: String?, model: String?) {
        translationProviderName = provider
        translationModelName = model
        persistString(provider, translationProviderKey)
        persistString(model, translationModelKey)
    }

    func setTranslationLanguages(source: String, target: String) {
        translationSourceLanguage = source
        translationTargetLanguage = target
        defaults.set(source, forKey: translationSourceLanguageKey)
        defaults.set(target, forKey: translationTargetLanguageKey)
    }

    // MARK: - Mutators(M9 深答風格)

    func setDeepStyle(_ value: MeetingDeepStyle) {
        deepStyle = value
        defaults.set(value.rawValue, forKey: deepStyleKey)
    }

    // MARK: - Mutators(Prompt 設定)

    /// 存回空字串是合法的(= 不注入風格守則);要恢復預設請傳 `defaultAnswerStyleGuidance`。
    func setAnswerStyleGuidance(_ value: String) {
        answerStyleGuidance = value
        defaults.set(value, forKey: answerStyleGuidanceKey)
    }

    /// 深度分析風格(深思模型)。空字串 = 不注入;恢復預設傳 `defaultDeepStyleGuidance`。
    func setDeepStyleGuidance(_ value: String) {
        deepStyleGuidance = value
        defaults.set(value, forKey: deepStyleGuidanceKey)
    }

    /// 空字串 = 用內建分類器 prompt;非空 = 完整覆寫。
    func setCuePromptOverride(_ value: String) {
        cuePromptOverride = value
        defaults.set(value, forKey: cuePromptOverrideKey)
    }
}
