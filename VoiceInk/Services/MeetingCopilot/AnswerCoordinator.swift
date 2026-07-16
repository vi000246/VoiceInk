import Foundation
import SwiftData
import Combine
import os

/// 接地的可注入介面(測試注入 noop / fake)。
protocol MeetingGroundingProviding {
    /// - Parameters:
    ///   - query: 檢索用查詢文字(呼叫端按 cue 種類決定:aboutMe 用 searchHint 改寫詞,其他用 cue 原句)。
    ///   - sources: 檢索來源白名單(`EmbeddingChunk.sourceKind`);nil = 不限來源(M8 FR-47)。
    ///   - minScore: RAG cosine 相似度下限(0 = 不設限;aboutMe 傳非 0 擋離題接地)。
    func gather(query: String, brief: String, includeRAG: Bool, includeScreen: Bool,
                sources: Set<String>?, minScore: Float) async -> MeetingGrounding
}

extension MeetingGroundingProvider: MeetingGroundingProviding {}

/// 編排核心:把一則 cue 變成**三段回應**並回寫 `MeetingLiveCue`(M10 重構)。
///
/// - **Tier 0**(FR-13):`onNewCue` 同步跑 `Tier0Classifier`(無 LLM),寫 `tier0Keywords`。
/// - **開口稿 / Tier 1**(FR-14/15,**即時模型** `fast`):最新一則自動預跑;寫 `tier1Opener`/`tier1Bullets`。
/// - **中度分析 / Tier 2**(FR-74,**即時模型** `fast`):開口稿完成後**恆自動接續**(不可關);寫 `tier2*` +
///   自評升級訊號 `mediumNeedsDeep`/`mediumDeepReason`(FR-75)。
/// - **深度分析 / Tier 3**(FR-76,**深思模型** `deep`):走**閘門**(FR-77)——自動模式且中度 `needsDeep` 為真時
///   自動發起,或使用者按鈕手動起;寫 `tier3*`。M8 的「慢層」機制(latest-only 取消 / 展開保護 FR-54 /
///   未讀徽章 FR-51 / 進度 spinner)**由 Tier 2 平移到 Tier 3**——中度是即時漸進渲染的一部分,不掛這些機制。
/// - **失敗逐層降級**(FR-28):深度失敗保留中度;中度失敗保留開口稿;一律 log-only。
///
/// **完成訊號(FR-81)**:深度分析是否「成功送出」以 `completedDeepGenerations` 世代標記判定,**不得**以
/// `tierNError.isEmpty` 推斷——取消時該欄位亦為空,會把取消誤判成功(截圖深答曾因此清空佇列)。
@MainActor
final class AnswerCoordinator: ObservableObject {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    /// aboutMe 接地的 RAG cosine 相似度下限。向量已 L2-normalize(dot = cosine)。0.2 很保守——
    /// 只砍掉近乎正交(明顯不相關)的塊,真正沾邊的筆記仍留得住。碎片/離題 query 撈回的
    /// 通常落在 0.1 上下,設 0.2 讓 `零接地守門` 有機會生效,而不是硬吞 top-k 個垃圾塊。
    static let aboutMeRAGMinScore: Float = 0.2

    /// **即時模型**:開口稿(Tier 1)+ 中度分析(Tier 2)共用。
    private let fast: StreamingChatCompleting
    /// **深思模型**:僅深度分析(Tier 3)。(param 名沿用 `deep`,語意 = 深思模型,minimal churn。)
    private let deep: StreamingChatCompleting
    private let grounding: MeetingGroundingProviding
    private let config: MeetingCopilotConfigStore
    /// 觀測資料:實際模型名("provider/model")。fastLabel=即時模型、deepLabel=深思模型。
    private let fastLabel: String
    private let deepLabel: String

    private var prefetchTask: Task<Void, Never>?
    /// Tier 3(深度分析)的在途 task。(欄名沿用 `deep*`,語意 = 深度分析/深思。)
    private var deepTask: Task<Void, Never>?
    /// 在途深度分析的目標 cue(nil = 沒有在途)。展開保護(FR-54)靠它判斷「正在跑的深答是不是使用者正在讀的那則」。
    private var deepTaskCueId: UUID?
    /// 在途深度分析的觸發來源("auto"/"manual"/"image")。FR-82:image 的在途深答視同受保護,不被新 cue 秒殺。
    private var deepTaskTrigger: String?
    /// deep 的世代序號:每起一條深答 +1。被取消的舊深答晚醒時,**不能**抹掉新深答剛設的在途標記。
    private var deepGeneration = 0
    /// **成功完成**的深答世代集合(FR-81)。只有 `runDeep` 成功寫回後才記入;取消/早退不記。
    /// `requestDeepWithImages` 以此判定是否清空截圖佇列——**不**用 `tier3Error.isEmpty`(取消時它也是空)。
    private var completedDeepGenerations: Set<Int> = []
    /// 已完成的 Tier 1 草稿(cue.id → draft),供中度/深度零等待取用。
    private var drafts: [UUID: Tier1Draft] = [:]

    /// 目前展開中(= 使用者正在讀)的 cue id。live 端由 controller 注入閉包。
    ///
    /// **用 closure 反轉依賴**:coordinator 是引擎層,不該倒過來依賴 UI 的 controller
    /// (controller 已經持有 coordinator,直接引用就成環,測試也得整包搬 controller 進來)。
    /// 預設回 nil = 沒有展開 → 保護不生效,行為與 M8 之前完全一致。
    var expandedCueIdProvider: () -> UUID? = { nil }

    /// Tier 2 **成功寫回之後**的通知(cue.id)。live 端接到 `MeetingCopilotController.handleDeepCompleted`
    /// 去做自動展開/未讀標記(FR-51)。同上,用 closure 反轉依賴,不讓引擎層認得 UI controller。
    ///
    /// auto 與 manual 兩條路都會叫:手動點擊時 `expandedCueId` 通常已經是該 cue,
    /// `handleDeepCompleted` 內是 no-op,不必在這裡分支。失敗/取消不叫——沒有分析可讀,
    /// 亮「分析完成」徽章只會騙人。
    var onDeepCompleted: (UUID) -> Void = { _ in }

    /// 截圖深答:深答模型不支援圖片、或圖片深答失敗時的**使用者可見**提示。
    /// live 端接到 `MeetingCopilotController.imageDeepError` → overlay 顯示。同 `onDeepCompleted`,
    /// 用 closure 反轉依賴(引擎層不認得 UI controller)。
    var onImageUnsupported: (String) -> Void = { _ in }

    /// 深度分析在途狀態的**單一事實來源**(cue.id = 進行中的那則;nil = 無在途)。
    /// live 端接到 `MeetingCopilotController.deepInFlightCueId` → overlay 顯示 spinner + disable「深入分析」鈕。
    ///
    /// **三條觸發路徑(auto/manual/image)共用這一個 hook**——不能只在 UI 的手動 closure 設旗標:
    /// 自動深答沒有 closure,漏設會讓 overlay 在自動深答進行中仍顯示可點的按鈕,一點就取消+重跑
    /// 那條在途深答(白燒一次深思模型;違反 FR-77/AC-62)。由 `startDeep` 設、`runDeep` 世代守門清。
    var onDeepInFlight: (UUID?) -> Void = { _ in }

    init(
        fast: StreamingChatCompleting,
        deep: StreamingChatCompleting,
        grounding: MeetingGroundingProviding,
        config: MeetingCopilotConfigStore = .shared,
        fastLabel: String = "",
        deepLabel: String = ""
    ) {
        self.fast = fast
        self.deep = deep
        self.grounding = grounding
        self.config = config
        self.fastLabel = fastLabel
        self.deepLabel = deepLabel
    }

    // MARK: - 新 cue:Tier 0 + 預跑 Tier 1

    func onNewCue(_ cue: MeetingLiveCue) async {
        // Tier 0(同步,無 LLM,< 0.5s)
        let t0 = Tier0Classifier.classify(cueText: cue.text)
        cue.tier0Keywords = ([t0.domainLabel] + t0.keywords).joined(separator: " · ")
        try? cue.modelContext?.save()

        // 預跑 Tier 1(只保最新一則:取消前一則未完成的預跑)
        guard config.prefetchEnabled else { return }
        prefetchTask?.cancel()
        let cueRef = cue
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            await self.runTier1(cueRef)
        }
    }

    // MARK: - 回應語言(M8 AC-46)

    /// 三層回應的輸出語言 = **翻譯目標語言**(不是另開一個設定)。
    ///
    /// 開口稿的用途是直接照著唸,所以「我想聽/看什麼語言」與「我要開口說什麼語言」在會議現場
    /// 是同一件事——拆成兩個設定,只會讓人設出「字幕繁中、開口稿英文」這種沒人想要的組合。
    /// 翻譯關著時這個值仍有意義:目標語言的預設(zh-TW)就是回應語言,與 M8 之前的行為一致。
    private var outputLanguage: String {
        MeetingTranslationPrompt.displayName(for: config.translationTargetLanguage)
    }

    // MARK: - 檢索路由(M8 FR-47)

    /// 按 cue 種類決定接地參數。aboutMe 走個人筆記:query 用 searchHint 改寫詞(口語原句直接
    /// 嵌入命中率差)、開關看 `useNotesRAG`(**不看** useHistoryRAG——被問到自己的經歷時,
    /// 逐字稿歷史沒有答案,筆記才有)。其他種類維持逐字稿三來源——**明確排除 obsidian**,
    /// 技術答案不被個人筆記污染(既有行為不變的 NFR;`notesInTechnicalRAG` 顯式開啟才納入)。
    private func groundingPlan(for cue: MeetingLiveCue) -> (query: String, includeRAG: Bool, sources: Set<String>?) {
        if cue.kind == .aboutMe {
            let q = cue.searchHint.isEmpty ? cue.text : cue.searchHint
            return (q, config.useNotesRAG, ["obsidian"])
        }
        var s: Set<String> = ["dictation", "recorder", "meeting"]
        if config.notesInTechnicalRAG { s.insert("obsidian") }
        return (cue.text, config.useHistoryRAG, s)
    }

    // MARK: - Tier 1

    /// - Parameter continueChain: 完成後是否自動接續中度分析(→閘門→深度)。預跑路徑傳 true;
    ///   `requestDeep` 的補跑路徑傳 false——它只是要補一份開口稿草稿,鏈由呼叫端自己接。
    private func runTier1(_ cue: MeetingLiveCue, continueChain: Bool = true) async {
        let started = Date()
        let plan = groundingPlan(for: cue)
        let g = await grounding.gather(
            query: plan.query, brief: cue.session?.brief ?? "",
            includeRAG: plan.includeRAG, includeScreen: false,   // Tier1 不抓螢幕
            sources: plan.sources,
            // aboutMe 對接地相關性最敏感(接錯筆記 = 自信亂答);給 cosine 下限只砍近乎不相關的。
            minScore: cue.kind == .aboutMe ? Self.aboutMeRAGMinScore : 0)

        // M9 FR-65:aboutMe 零接地守門——沒有筆記片段就沒有事實可依,呼叫模型只會拿到編的。
        // 不呼叫 LLM 是唯一的**結構性**保證(prompt 紅線只能降低機率)。ragError(RAG 降級)與
        // 檢索零命中在這裡是同一件事:兩者都代表「我手上沒有你的資料」。replay 路徑共用本函式,
        // 同樣受保護。
        if cue.kind == .aboutMe, g.ragExcerpts.isEmpty {
            cue.tier1Opener = "筆記沒有記載這題——照實說，或把話題帶回你記得的部分。"
            cue.tier1Bullets = config.aboutMeBrief.isEmpty ? [] : [config.aboutMeBrief]
            cue.tier1GroundingNote = "aboutMe 零接地短路（未呼叫 LLM）"
                + (g.ragError.map { "；RAG 降級:\($0)" } ?? "")
            cue.tier1ElapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            cue.tier1At = Date()
            cue.tier1Error = ""
            // fastModelName 不寫:沒打模型就不冒名(覆盤的成本歸因要誠實)。
            try? cue.modelContext?.save()
            // drafts[cue.id] 不塞:短路沒有 Tier 1 草稿。塞了反而讓 requestDeep 的
            // 「無草稿 → 中止」防線失效,aboutMe 就從後門溜進 deep model 自由發揮。
            return
        }

        // M8 FR-48:aboutMe 走「個人記憶助手」變體——鎖死筆記與自介為唯一事實來源、bullets 出
        // 記憶錨點而非論述句。既有函式簽章不動,純 if/else 分支(技術 cue 行為零改變)。
        let system = cue.kind == .aboutMe
            ? TierPrompts.tier1SystemAboutMe(persona: config.domainPersona,
                                             guidance: config.answerStyleGuidance,
                                             outputLanguage: outputLanguage)
            : TierPrompts.tier1System(persona: config.domainPersona,
                                      guidance: config.answerStyleGuidance,
                                      outputLanguage: outputLanguage)
        let user = cue.kind == .aboutMe
            ? TierPrompts.tier1UserAboutMe(cue: cue.text, grounding: g, aboutMeBrief: config.aboutMeBrief)
            : TierPrompts.tier1User(cue: cue.text, grounding: g)
        // 觀測資料:模型看到的完整 user prompt(接地內容全在裡面);system 在 session 快照。
        cue.tier1PromptUser = user
        cue.tier1GroundingNote = g.ragError.map { "RAG 降級:\($0)" } ?? ""

        var acc = ""
        do {
            for try await d in fast.stream(system: system, user: user) {
                if Task.isCancelled { return }
                acc += d
            }
        } catch {
            // Tier 1 失敗 → 保留 Tier 0,log-only(FR-28);失敗原因 persist 供覆盤。
            logger.error("🧠 tier1 failed: \(error.localizedDescription, privacy: .public)")
            cue.tier1Error = error.localizedDescription
            try? cue.modelContext?.save()
            return
        }
        guard !Task.isCancelled else { return }

        let draft = TierParsers.parseTier1(AIEnhancementOutputFilter.filter(acc))
        drafts[cue.id] = draft
        cue.tier1Opener = draft.opener
        cue.tier1Bullets = draft.bullets.filter { !$0.isEmpty }
        cue.tier1RawReply = acc
        cue.tier1ElapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        cue.tier1At = Date()
        cue.tier1Error = ""
        cue.fastModelName = fastLabel.isEmpty ? "fast" : fastLabel
        try? cue.modelContext?.save()

        // FR-74:開口稿一寫完就**恆自動接續中度分析**(即時模型,不可關;aboutMe 只到開口稿為止)。
        //
        // **latest-only 是天然的**:tier1→中度都跑在 prefetchTask 裡,新 cue 進來會 cancel 舊 prefetch,
        // 走得到這裡的只有「活到最後的最新一則」。`Task.isCancelled` 再擋一次:guard 之後仍可能被新 cue 取消。
        // 中度**在同一個 prefetch task 內 await**(它快、~5s),讓新 cue 能連中度一起取消(latest-only);
        // 深度分析(慢)則在中度內視閘門另起獨立 deepTask,不在 prefetch 內 await。
        if continueChain, cue.kind != .aboutMe, !Task.isCancelled {
            await runMedium(cue, autoGate: true)
        }
    }

    /// 離線覆盤用:直接跑 Tier 1 並**等它完成**。
    ///
    /// **不掛 auto-deep、不動 prefetchTask** —— 兩者都是即時語意,replay 兩個都不要:
    /// - `prefetchTask` 是「只保最新一則」(新 cue 取消舊預跑)。replay 是序列全量處理,
    ///   每一則 cue 都要有回應;走 `onNewCue` 會讓前後兩則互相取消,大半的 cue 沒有 Tier 1。
    /// - auto-deep 會把整場會議的每一則 cue 都丟給 deep model(一場一小時的會議可能上百則)。
    ///   覆盤是離線的背景工作,沒有「馬上要答」的壓力,不值得為它燒 deep 的錢——要深度分析,
    ///   使用者在覆盤頁點那一則就好(走 `requestDeep`)。
    func runTier1ForReplay(_ cue: MeetingLiveCue) async {
        await runTier1(cue, continueChain: false)
    }

    // MARK: - 中度分析(Tier 2,即時模型;恆自動接續 + 自評升級訊號)

    /// 已完成中度分析的 cue（供 `requestDeep` 判斷是否需補跑中度作為深度的基底）。
    private var mediumsDone: Set<UUID> = []

    /// 深答資格:aboutMe / informational 不進深度分析（延續 M9 FR-67）。informational 本就不會到 coordinator，
    /// 這裡一併守門是雙保險。
    private func deepEligible(_ cue: MeetingLiveCue) -> Bool {
        cue.kind != .aboutMe && cue.kind != .informational
    }

    /// 中度分析(FR-74):即時模型,帶入開口稿草稿。**恆自動接續**開口稿、無開關可關。
    /// 產出 `tier2*` + 自評升級訊號 `mediumNeedsDeep`/`mediumDeepReason`(FR-75)。
    /// - Parameter autoGate: 完成後是否據 `needsDeep` 自動發起深度分析(FR-77 自動模式)。預跑鏈傳 true;
    ///   `requestDeep` 的補跑傳 false(呼叫端自己接深度)。
    private func runMedium(_ cue: MeetingLiveCue, autoGate: Bool) async {
        // 無開口稿草稿 = tier1 沒成功寫回 → 不跑中度(降級:保留開口稿/Tier0)。
        guard let draft = drafts[cue.id] else { return }
        let groundingStart = Date()
        let plan = groundingPlan(for: cue)
        let g = await grounding.gather(
            query: plan.query, brief: cue.session?.brief ?? "",
            includeRAG: plan.includeRAG, includeScreen: false,   // 中度不抓螢幕(即時;螢幕留給深度/截圖)
            sources: plan.sources,
            minScore: cue.kind == .aboutMe ? Self.aboutMeRAGMinScore : 0)
        let groundingElapsed = Date().timeIntervalSince(groundingStart)

        // 中度分析:回答風格用 answerStyleGuidance(與開口稿共用);密度**固定條列**(3 秒掃視,
        // 使用者不需要中度的密度選項——它的定位就是現場快速掃一眼)。深度分析的 enum 密度不套在這。
        let system = TierPrompts.tier2System(persona: config.domainPersona,
                                             guidance: config.answerStyleGuidance,
                                             outputLanguage: outputLanguage,
                                             style: .bullets)
        let user = TierPrompts.tier2User(cue: cue.text, draft: draft, grounding: g)
        cue.tier2PromptUser = user
        cue.tier2GroundingElapsedMs = Int(groundingElapsed * 1000)
        cue.tier2GroundingNote = g.ragError.map { "RAG 降級:\($0)" } ?? ""

        let streamStart = Date()
        var acc = ""
        do {
            for try await d in fast.stream(system: system, user: user) {
                if Task.isCancelled { return }
                acc += d
            }
        } catch {
            // 中度失敗 → 保留開口稿,log-only(FR-28);原因 persist 供覆盤。
            logger.error("🧠 medium(tier2) failed: \(error.localizedDescription, privacy: .public)")
            cue.tier2Error = error.localizedDescription
            try? cue.modelContext?.save()
            return
        }
        guard !Task.isCancelled else { return }
        let filtered = AIEnhancementOutputFilter.filter(acc)
        let analysis = TierParsers.parseTier2(filtered)
        cue.tier2Analysis = analysis.analysis
        cue.tier2FollowUps = analysis.followUps.map(\.displayLine)
        cue.tier2Uncertainties = analysis.uncertainties
        cue.tier2RawReply = acc
        cue.tier2StreamElapsedMs = Int(Date().timeIntervalSince(streamStart) * 1000)
        cue.tier2Error = ""
        cue.mediumNeedsDeep = analysis.needsDeep
        cue.mediumDeepReason = analysis.deepReason
        cue.fastModelName = fastLabel.isEmpty ? "fast" : fastLabel   // 中度用即時模型(與開口稿同顆)
        cue.answeredAt = Date()
        cue.status = .answered   // 中度是真回答(深度是加值)
        try? cue.modelContext?.save()
        mediumsDone.insert(cue.id)

        logger.notice("🧠 medium 完成 needsDeep=\(analysis.needsDeep, privacy: .public) reason=\(analysis.deepReason.prefix(40), privacy: .public)")

        // FR-77 閘門:自動模式 + 中度判定需要 + 可深答 → 自動發起深度分析(Tier 3)。
        if autoGate, config.deepTrigger == .auto, deepEligible(cue), analysis.needsDeep, !Task.isCancelled {
            startAutoDeep(cue)
        }
    }

    // MARK: - 深度分析(Tier 3,深思模型;閘門化,承接慢層機制)

    /// 中度放行後的自動深答(FR-77)。不 await 起出來的 task:深答動輒十餘~數十秒,綁著 prefetch 一起等
    /// 會糊掉「新 cue 取消舊 prefetch」的語意(prefetch 只代表開口稿+中度)。
    private func startAutoDeep(_ cue: MeetingLiveCue) {
        guard deepEligible(cue) else { return }
        // FR-54 閱讀保護 + FR-82 在途截圖深答保護:在途深答受保護 → 這次自動深答放棄(跳過而非排隊)。
        if isDeepProtected() {
            logger.notice("🫆 auto-deep 跳過（保護中）")
            return
        }
        deepTask?.cancel()   // 在途的不受保護 → 取消(深思算力只給最新的 cue)
        startDeep(cue, trigger: "auto")
    }

    /// 手動深度分析(overlay/覆盤頁的「深入分析」按鈕）。起 Tier 3(深思模型),帶入中度分析為基底。
    func requestDeep(_ cue: MeetingLiveCue) async {
        // aboutMe/informational 不進深度分析(FR-78;守門 auto 那條不夠,按鈕也走這裡)。
        guard deepEligible(cue) else {
            logger.notice("🫆 deep skipped: \(cue.kind.rawValue, privacy: .public) 不進深度分析")
            return
        }
        logger.notice("🫆 deep requested: \(cue.text.prefix(40), privacy: .public)")
        // 先讓自動鏈(開口稿+中度)有機會完成;再補齊開口稿與中度作為深度的基底。
        await prefetchTask?.value
        if drafts[cue.id] == nil {
            logger.notice("🫆 開口稿草稿缺失 → 先補跑開口稿")
            await runTier1(cue, continueChain: false)
        }
        guard drafts[cue.id] != nil else {
            logger.error("🫆 開口稿補跑仍無草稿 → 深度分析中止")
            cue.tier3Error = "開口稿無草稿(即時模型失敗)→ 深度分析中止"
            try? cue.modelContext?.save()
            return
        }
        if !mediumsDone.contains(cue.id) {
            logger.notice("🫆 中度尚未完成 → 先補跑中度(作為深度基底)")
            await runMedium(cue, autoGate: false)
        }

        // 手動點擊是明確意圖:可取消**這則自己**先前的深答(重跑),但不取消使用者正在讀的**另一則**
        // 在途分析(FR-54),也不取消在途的截圖深答(FR-82)。
        if !isDeepProtected(excluding: cue.id) { deepTask?.cancel() }
        let task = startDeep(cue, trigger: "manual")
        await task.value
    }

    // MARK: - 截圖深答(手動視覺;overlay「以截圖重新深答」按鈕)

    /// 帶截圖重跑**深度分析**,直接覆蓋這則的 tier3(原始回覆仍在 `tier3RawReply`)。**純手動、auto 不碰**
    /// ——圖片一次燒 1~1.6k token/張,只有使用者「決定送這幾張」才有意義(FR-80)。
    ///
    /// 回傳 true = **確實完成**(呼叫端據此清空截圖佇列);不支援/取消/失敗回 false 並保留佇列(FR-81)。
    @discardableResult
    func requestDeepWithImages(_ cue: MeetingLiveCue, images: [Data]) async -> Bool {
        guard !images.isEmpty else { return false }
        guard deepEligible(cue) else {
            onImageUnsupported("這類問題不走深度分析,截圖深答不適用。")
            return false
        }
        // 視覺能力守門:判定對象是**深思模型**(FR-80/83)。不支援就給清楚、可行動的訊息。
        guard VisionModelSupport.isVisionCapable(label: deepLabel) else {
            let name = deepLabel.isEmpty ? "目前的深思模型" : deepLabel
            onImageUnsupported("深思模型「\(name)」不支援圖片辨識。請到「設定 → 會議即時輔助 → 模型」把**深思模型**換成支援視覺的（例如 gemini-2.5-pro、gpt-5.5、claude-sonnet-4），再重試截圖深答。")
            return false
        }

        // 補齊開口稿與中度(深度的基底);與 requestDeep 同一套降級。
        await prefetchTask?.value
        if drafts[cue.id] == nil { await runTier1(cue, continueChain: false) }
        guard drafts[cue.id] != nil else {
            cue.tier3Error = "開口稿無草稿 → 截圖深答中止"
            try? cue.modelContext?.save()
            onImageUnsupported("這則還沒準備好開口稿(即時模型可能失敗),稍候再試截圖深答。")
            return false
        }
        if !mediumsDone.contains(cue.id) { await runMedium(cue, autoGate: false) }

        // 手動意圖:可取消**這則自己**先前的在途深答(重跑),但不取消使用者正在讀的**另一則**、
        // 也不取消**別則**在途的截圖深答(FR-54/FR-82;與 requestDeep 同一套保護)。
        if !isDeepProtected(excluding: cue.id) { deepTask?.cancel() }
        let task = startDeep(cue, trigger: "image", images: images)
        let generation = deepGeneration   // startDeep 剛 +1 = 這條深答的世代(@MainActor 同步,無競態)
        await task.value

        // FR-81:以**世代完成標記**判定成功,不用 `tier3Error.isEmpty`——取消時 tier3Error 也是空,
        // 會把「被新 cue 取消」誤判成功而清掉截圖佇列。只有 runDeep 成功寫回才會記入此世代。
        if completedDeepGenerations.contains(generation) { return true }
        onImageUnsupported(cue.tier3Error.isEmpty
            ? "截圖深答被新的問題打斷了——截圖已保留,可再按一次重試。"
            : "截圖深答失敗:\(cue.tier3Error)")
        return false
    }

    /// 在途深答是否受保護、不得被新 cue 的自動升級取消。
    /// - 展開中(FR-54):目標 == 使用者正在讀的那則。
    /// - 在途截圖深答(FR-82):`trigger == "image"`——使用者剛送出的截圖深答不該被下一則 cue 秒殺。
    /// - Parameter excluding: 「這次要跑的 cue」。重跑同一則不算保護(取消掉的是使用者自己的舊深答)。
    private func isDeepProtected(excluding cueId: UUID? = nil) -> Bool {
        guard let inflight = deepTaskCueId else { return false }
        if inflight == cueId { return false }
        if inflight == expandedCueIdProvider() { return true }
        if deepTaskTrigger == "image" { return true }
        return false
    }

    /// 起一條深度分析(auto/manual/image 共用)。回傳 task 供手動路徑 await。
    @discardableResult
    private func startDeep(_ cue: MeetingLiveCue, trigger: String, images: [Data] = []) -> Task<Void, Never> {
        deepGeneration += 1
        let generation = deepGeneration
        // **在途標記在這裡就設**(不能等 runDeep 進 task body):Task 排程後才跑,這中間另一則 cue 的
        // 中度若剛完成,其保護檢查會看到 nil,誤把這條剛掛出的深答取消。
        deepTaskCueId = cue.id
        deepTaskTrigger = trigger
        onDeepInFlight(cue.id)   // 三路共用:auto 也在此設旗標(overlay spinner + 按鈕 disable)
        cue.tier3TriggerRaw = trigger
        try? cue.modelContext?.save()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDeep(cue, generation: generation, images: images)
        }
        deepTask = task
        return task
    }

    /// 深度分析(Tier 3,深思模型)。帶入中度分析為基底做真正的推理;寫回 tier3*。
    private func runDeep(_ cue: MeetingLiveCue, generation: Int, images: [Data] = []) async {
        // 收尾清在途標記:只有「我還是最新那條深答」才清(被取消的舊深答晚醒時不得抹掉新的標記)。
        // 同一守門下清 UI 旗標——世代守門確保被取消的舊深答不會把新深答的 spinner 清掉(修 clobber)。
        defer {
            if deepGeneration == generation {
                deepTaskCueId = nil
                deepTaskTrigger = nil
                onDeepInFlight(nil)
            }
        }

        let groundingStart = Date()
        let plan = groundingPlan(for: cue)
        let g = await grounding.gather(
            query: plan.query, brief: cue.session?.brief ?? "",
            // 深度才抓螢幕 OCR;但**帶了圖就不重複抓 OCR**(圖片已含畫面,再塞 OCR 只增 token 又矛盾)。
            includeRAG: plan.includeRAG, includeScreen: config.useScreenContext && images.isEmpty,
            sources: plan.sources,
            minScore: cue.kind == .aboutMe ? Self.aboutMeRAGMinScore : 0)
        let groundingElapsed = Date().timeIntervalSince(groundingStart)
        logger.notice("🫆 tier3 接地完成 elapsed=\(groundingElapsed, format: .fixed(precision: 1), privacy: .public)s → 深思模型串流開始")

        // 深度分析:風格用**深度專屬**的 deepStyleGuidance(與即時那兩段拆開,不再互相拉扯);
        // 密度用 deepStyle enum(條列/簡潔/詳細)。
        let system = TierPrompts.tier3System(persona: config.domainPersona,
                                             guidance: config.deepStyleGuidance,
                                             outputLanguage: outputLanguage,
                                             style: config.deepStyle)
        let user = TierPrompts.tier3User(cue: cue.text, mediumAnalysis: cue.tier2Analysis, grounding: g)
        cue.tier3PromptUser = user
        cue.tier3GroundingElapsedMs = Int(groundingElapsed * 1000)
        cue.tier3GroundingNote = g.ragError.map { "RAG 降級:\($0)" } ?? ""

        let streamStart = Date()
        var acc = ""
        do {
            for try await d in deep.stream(system: system, user: user, images: images) {
                if Task.isCancelled { return }
                acc += d
            }
        } catch {
            // 深度失敗 → 保留中度,log-only,無可見 UI(FR-28)。
            logger.error("🧠 tier3 failed: \(error.localizedDescription, privacy: .public)")
            cue.tier3Error = error.localizedDescription
            try? cue.modelContext?.save()
            return
        }
        guard !Task.isCancelled else { return }
        logger.notice("🫆 tier3 完成 streamElapsed=\(Date().timeIntervalSince(streamStart), format: .fixed(precision: 1), privacy: .public)s chars=\(acc.count, privacy: .public)")
        let filtered = AIEnhancementOutputFilter.filter(acc)
        let analysis = TierParsers.parseTier3(filtered)
        cue.tier3Analysis = analysis.analysis
        cue.tier3FollowUps = analysis.followUps.map(\.displayLine)
        cue.tier3Uncertainties = analysis.uncertainties
        cue.tier3RawReply = acc
        cue.tier3StreamElapsedMs = Int(Date().timeIntervalSince(streamStart) * 1000)
        cue.tier3Error = ""
        cue.tier3At = Date()
        cue.deepThinkModelName = deepLabel.isEmpty ? "deep" : deepLabel
        cue.answeredAt = Date()
        cue.status = .answered
        try? cue.modelContext?.save()

        // FR-81:成功寫回才記入完成世代(截圖深答據此判定是否清佇列)。
        completedDeepGenerations.insert(generation)
        // FR-51:深度分析完成 → 通知 UI 自動展開/標未讀(徽章綁**深度分析**完成,中度不觸發)。
        onDeepCompleted(cue.id)
    }

    func cancelDeep() {
        deepTask?.cancel()
        deepTask = nil
        deepTaskCueId = nil
        deepTaskTrigger = nil
        onDeepInFlight(nil)
    }

    // MARK: - 測試 hook

    /// 測試用:等待預跑的 Tier 1 完成(免 sleep 輪詢;正式碼不呼叫)。
    func drainPrefetchForTest() async { await prefetchTask?.value }

    /// 測試用:等整條鏈靜止——prefetch 的 Tier 1 **跑完之後**才掛出 auto-deep,
    /// 所以單押 `deepTask` 會撲空(呼叫當下它還是 nil)。作法:等一輪 → 看兩個 task 有沒有換人
    /// → 沒換就是靜止了(鏡射 `MeetingCopilotController.drainInflight` 的排乾語意)。
    func awaitQuiescentForTest() async {
        for _ in 0..<8 {   // 上限純防呆:鏈最長就 tier1 → deep 兩段,兩輪內必靜止
            let p = prefetchTask
            let d = deepTask
            await p?.value
            await d?.value
            if prefetchTask == p, deepTask == d { return }
        }
    }
}
