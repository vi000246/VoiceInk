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

/// M3 的編排核心:把一則 cue 變成三層回應並回寫 `MeetingLiveCue`。
///
/// - **Tier 0**(FR-13):`onNewCue` 同步跑 `Tier0Classifier`(無 LLM),寫 `tier0Keywords`。
/// - **Tier 1**(FR-14/15):最新一則 cue 自動**預跑**(`prefetchEnabled`);寫 `tier1Opener`/`tier1Bullets`。
/// - **Tier 2**(FR-16/17):`requestDeep` 才跑,**帶入 Tier 1 草稿全文**(AC-8);可取消。
/// - **失敗逐層降級**(FR-28):Tier 2 失敗保留 Tier 1;Tier 1 失敗保留 Tier 0;**一律 log-only,
///   不呼叫 `NotificationManager`**(它渲染可見 NSPanel + 播音 + 搶焦點,分享螢幕時會暴露)。
///
/// 狀態:沿用 M2 的 `MeetingCueStatus`(`.detected`/`.answered`)——Tier 1 完成由 `tier1Opener` 非空推斷,
/// Tier 2 完成才 `.answered`(避免改動 M2 已 commit 的 enum)。
@MainActor
final class AnswerCoordinator: ObservableObject {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    /// aboutMe 接地的 RAG cosine 相似度下限。向量已 L2-normalize(dot = cosine)。0.2 很保守——
    /// 只砍掉近乎正交(明顯不相關)的塊,真正沾邊的筆記仍留得住。碎片/離題 query 撈回的
    /// 通常落在 0.1 上下,設 0.2 讓 `零接地守門` 有機會生效,而不是硬吞 top-k 個垃圾塊。
    static let aboutMeRAGMinScore: Float = 0.2

    private let fast: StreamingChatCompleting
    private let deep: StreamingChatCompleting
    private let grounding: MeetingGroundingProviding
    private let config: MeetingCopilotConfigStore
    /// 觀測資料:實際模型名("provider/model")。空字串時退回 M3 的佔位標記 "fast"/"deep"。
    private let fastLabel: String
    private let deepLabel: String

    private var prefetchTask: Task<Void, Never>?
    private var deepTask: Task<Void, Never>?
    /// 在途 deep 的目標 cue(nil = 沒有在途)。展開保護(FR-54)靠它才知道
    /// 「正在跑的那條 deep,是不是使用者眼前正在讀的那則」。
    private var deepTaskCueId: UUID?
    /// deep 的世代序號:每起一條 deep +1。被取消的舊 deep 會晚一步才醒來,收尾時**不能**把新 deep
    /// 剛設好的 `deepTaskCueId` 抹掉——同一則 cue 重跑時 cue.id 相同,只有世代分得出「我是不是最新那條」。
    private var deepGeneration = 0
    /// 已完成的 Tier 1 草稿(cue.id → draft),供 requestDeep 零等待取用。
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

    /// - Parameter autoDeep: 完成後是否自動接 Tier 2(FR-53)。預跑路徑傳 true;`requestDeep` 的
    ///   補跑路徑傳 false——呼叫端緊接著就要自己起 deep,這裡再掛一條只是多燒一次 deep token 再被取消。
    private func runTier1(_ cue: MeetingLiveCue, autoDeep: Bool = true) async {
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

        // FR-53:Tier 1 一寫完就自動接 Tier 2。
        //
        // **latest-only 是天然的**:runTier1 跑在 prefetchTask 裡,新 cue 進來會 cancel 舊 prefetch,
        // 所以能走到這一行的只有「活到最後的最新一則」——不必另外做佇列或節流。
        // `Task.isCancelled` 要在這裡再擋一次:上面的 guard 之後仍可能被新 cue 取消,
        // 已作廢的 tier1 不該再把 deep model 拉起來燒 token。
        if autoDeep, config.autoDeepEnabled, !Task.isCancelled {
            runAutoDeep(cue)
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
        await runTier1(cue, autoDeep: false)
    }

    // MARK: - Tier 2(auto 或點擊;帶入 Tier 1 草稿)

    /// Tier 1 完成後的自動深答(FR-53)。不 await 起出來的 task:deep 動輒十餘秒,
    /// 綁著 prefetchTask 一起等只會讓「新 cue 取消舊 prefetch」的語意糊掉(prefetch 該只代表 Tier 1)。
    private func runAutoDeep(_ cue: MeetingLiveCue) {
        // M9 FR-67:aboutMe 不進 deep——記憶錨點看一眼就夠,深度分析對「回憶自己的經歷」沒有增量,
        // 只是多一段對話中讀不完的文字 + 一次 deep token。
        guard cue.kind != .aboutMe else { return }

        // 無草稿 = tier1 沒成功寫回 → 不進 deep(降級語意同 requestDeep)。
        guard let draft = drafts[cue.id] else { return }

        // FR-54 閱讀保護:在途 deep 的目標正是使用者展開中(= 正在讀)的那則 → 這次 auto-deep 放棄。
        // 「跳過」而不是「排隊」是刻意的:auto-deep 是加值功能,不值得為它把使用者眼前的分析取消掉;
        // 而排隊等它跑完再補跑,輪到時這則 cue 早就不是最新的了(latest-only 反而被破壞)。
        if isDeepProtected() {
            logger.notice("🫆 auto-deep 跳過（展開保護中）")
            return
        }
        deepTask?.cancel()   // 在途的不是展開中那則 → 取消(deep 的算力只給最新的 cue)
        startDeep(cue, draft: draft, trigger: "auto")
    }

    func requestDeep(_ cue: MeetingLiveCue) async {
        // M9 FR-67:守門 auto 那條還不夠——覆盤頁與 overlay 都有「深答」按鈕,手點一樣會走到這裡。
        // aboutMe 在兩條路上都是 no-op(理由同 runAutoDeep)。
        guard cue.kind != .aboutMe else {
            logger.notice("🫆 tier2 skipped: aboutMe 不進 deep（M9 FR-67）")
            return
        }
        logger.notice("🫆 tier2 requested: \(cue.text.prefix(40), privacy: .public)")
        // 先確保 Tier 1 完成(等待預跑,或補跑)。
        await prefetchTask?.value
        if drafts[cue.id] == nil {
            logger.notice("🫆 tier1 draft 缺失 → 先補跑 tier1")
            await runTier1(cue, autoDeep: false)   // 下面就自己起 deep 了,不必掛 auto
        }
        guard let draft = drafts[cue.id] else {
            // Tier 1 也失敗 → 不跑 Tier 2(保留 Tier 0)。中止原因 persist 供覆盤。
            logger.error("🫆 tier1 補跑仍無草稿(fast model 失敗?見 🧠 tier1 failed log)→ tier2 中止")
            cue.tier2Error = "Tier 1 無草稿(fast model 失敗)→ Tier 2 中止"
            try? cue.modelContext?.save()
            return
        }

        // 手動點擊是明確的使用者意圖:可以取消**這則自己**先前的 deep(= 重跑),
        // 但不能為了跑這則,把使用者正在讀的**另一則** cue 的在途分析取消掉(FR-54)。
        if !isDeepProtected(excluding: cue.id) { deepTask?.cancel() }
        let task = startDeep(cue, draft: draft, trigger: "manual")
        await task.value
    }

    /// 在途 deep 是否受展開保護(目標 == 使用者展開中的 cue → 不得取消)。
    /// - Parameter excluding: 「這次要跑的 cue」。重跑同一則不算保護——取消掉的是使用者自己的舊 deep。
    private func isDeepProtected(excluding cueId: UUID? = nil) -> Bool {
        guard let inflight = deepTaskCueId, inflight == expandedCueIdProvider() else { return false }
        return inflight != cueId
    }

    /// 起一條 deep(auto/manual 共用)。回傳 task 供手動路徑 await。
    @discardableResult
    private func startDeep(_ cue: MeetingLiveCue, draft: Tier1Draft, trigger: String) -> Task<Void, Never> {
        deepGeneration += 1
        let generation = deepGeneration
        // **在途標記在這裡就設**,不能等 runTier2 進到 task body 才設:Task 是排程後才跑,
        // 這中間若另一則 cue 的 tier1 剛好完成,它的保護檢查會看到 nil,誤把這條剛掛出的 deep 取消。
        deepTaskCueId = cue.id
        // 觀測(M8):覆盤要分得出這則是自動深答還是使用者點的——兩者的品質期待與成本歸因都不同。
        cue.tier2TriggerRaw = trigger
        try? cue.modelContext?.save()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTier2(cue, draft: draft, generation: generation)
        }
        deepTask = task
        return task
    }

    private func runTier2(_ cue: MeetingLiveCue, draft: Tier1Draft, generation: Int) async {
        // 收尾清在途標記:只有「我還是最新那條 deep」才清。被取消的舊 deep 可能晚一步才醒來,
        // 那時 deepTaskCueId 已經是新 deep 的目標,抹掉它會讓展開保護漏掉一則。
        defer { if deepGeneration == generation { deepTaskCueId = nil } }

        let groundingStart = Date()
        let plan = groundingPlan(for: cue)
        let g = await grounding.gather(
            query: plan.query, brief: cue.session?.brief ?? "",
            includeRAG: plan.includeRAG, includeScreen: config.useScreenContext,   // Tier2 才抓螢幕
            sources: plan.sources,
            minScore: cue.kind == .aboutMe ? Self.aboutMeRAGMinScore : 0)
        let groundingElapsed = Date().timeIntervalSince(groundingStart)
        logger.notice("🫆 tier2 接地完成 elapsed=\(groundingElapsed, format: .fixed(precision: 1), privacy: .public)s → deep model 串流開始")
        // M9 FR-67 之後這裡不再分支:aboutMe 在 runAutoDeep / requestDeep 兩處就被擋下,走不到 Tier 2,
        // 對應的 aboutMe prompt 變體也一併從 TierPrompts 刪掉——留著死路只會讓下一個人以為
        // aboutMe 還有 deep 這條路。
        // M9 FR-73:深答風格跟著 config 走(預設 `.bullets`)——會議進行中讀得完才算數。
        let system = TierPrompts.tier2System(persona: config.domainPersona,
                                             guidance: config.answerStyleGuidance,
                                             outputLanguage: outputLanguage,
                                             style: config.deepStyle)
        let user = TierPrompts.tier2User(cue: cue.text, draft: draft, grounding: g)
        // 觀測資料:Tier2 的完整 user prompt(Tier1 草稿 + 接地 + 螢幕 OCR 全在裡面)。
        cue.tier2PromptUser = user
        cue.tier2GroundingElapsedMs = Int(groundingElapsed * 1000)
        cue.tier2GroundingNote = g.ragError.map { "RAG 降級:\($0)" } ?? ""

        let streamStart = Date()
        var acc = ""
        do {
            for try await d in deep.stream(system: system, user: user) {
                if Task.isCancelled { return }
                acc += d
            }
        } catch {
            // Tier 2 失敗 → 保留 Tier 1(status 不變 .answered),log-only,無可見 UI(FR-28)。
            logger.error("🧠 tier2 failed: \(error.localizedDescription, privacy: .public)")
            cue.tier2Error = error.localizedDescription
            try? cue.modelContext?.save()
            return
        }
        guard !Task.isCancelled else { return }
        logger.notice("🫆 tier2 完成 streamElapsed=\(Date().timeIntervalSince(streamStart), format: .fixed(precision: 1), privacy: .public)s chars=\(acc.count, privacy: .public)")
        let filtered = AIEnhancementOutputFilter.filter(acc)
        let analysis = TierParsers.parseTier2(filtered)
        logger.notice("🫆 tier2 解析: analysis=\(analysis.analysis.count, privacy: .public)字 followUps=\(analysis.followUps.count, privacy: .public) 開頭=\(String(filtered.prefix(120)), privacy: .public)")
        cue.tier2Analysis = analysis.analysis
        cue.tier2FollowUps = analysis.followUps.map(\.displayLine)
        cue.tier2Uncertainties = analysis.uncertainties
        cue.tier2RawReply = acc
        cue.tier2StreamElapsedMs = Int(Date().timeIntervalSince(streamStart) * 1000)
        cue.tier2Error = ""
        cue.deepModelName = deepLabel.isEmpty ? "deep" : deepLabel
        cue.answeredAt = Date()
        cue.status = .answered
        try? cue.modelContext?.save()

        // 分析已經 persist 完 → 才通知 UI 展開/標未讀(FR-51)。
        // 放在 save 之後是必要的:handleDeepCompleted 會讓 overlay 立刻渲染這則的 tier2 欄位,
        // 早一步通知就可能展開到一張還沒寫上分析的空卡。
        onDeepCompleted(cue.id)
    }

    func cancelDeep() {
        deepTask?.cancel()
        deepTask = nil
        // 在途標記跟著清:留著會讓展開保護一直卡在一條已經取消的 deep 上,
        // 之後所有 auto-deep 都被誤判成「保護中」而跳過。
        deepTaskCueId = nil
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
