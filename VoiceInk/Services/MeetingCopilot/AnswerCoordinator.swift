import Foundation
import SwiftData
import Combine
import os

/// 接地的可注入介面(測試注入 noop / fake)。
protocol MeetingGroundingProviding {
    /// - Parameters:
    ///   - query: 檢索用查詢文字(呼叫端按 cue 種類決定:aboutMe 用 searchHint 改寫詞,其他用 cue 原句)。
    ///   - sources: 檢索來源白名單(`EmbeddingChunk.sourceKind`);nil = 不限來源(M8 FR-47)。
    func gather(query: String, brief: String, includeRAG: Bool, includeScreen: Bool,
                sources: Set<String>?) async -> MeetingGrounding
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

    private let fast: StreamingChatCompleting
    private let deep: StreamingChatCompleting
    private let grounding: MeetingGroundingProviding
    private let config: MeetingCopilotConfigStore
    /// 觀測資料:實際模型名("provider/model")。空字串時退回 M3 的佔位標記 "fast"/"deep"。
    private let fastLabel: String
    private let deepLabel: String

    private var prefetchTask: Task<Void, Never>?
    private var deepTask: Task<Void, Never>?
    /// 已完成的 Tier 1 草稿(cue.id → draft),供 requestDeep 零等待取用。
    private var drafts: [UUID: Tier1Draft] = [:]

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

    private func runTier1(_ cue: MeetingLiveCue) async {
        let started = Date()
        let plan = groundingPlan(for: cue)
        let g = await grounding.gather(
            query: plan.query, brief: cue.session?.brief ?? "",
            includeRAG: plan.includeRAG, includeScreen: false,   // Tier1 不抓螢幕
            sources: plan.sources)
        // M8 FR-48:aboutMe 走「個人記憶助手」變體——鎖死筆記與自介為唯一事實來源、bullets 出
        // 記憶錨點而非論述句。既有函式簽章不動,純 if/else 分支(技術 cue 行為零改變)。
        let system = cue.kind == .aboutMe
            ? TierPrompts.tier1SystemAboutMe(persona: config.domainPersona)
            : TierPrompts.tier1System(persona: config.domainPersona)
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
    }

    // MARK: - Tier 2(點擊才跑,帶入 Tier 1 草稿)

    func requestDeep(_ cue: MeetingLiveCue) async {
        logger.notice("🫆 tier2 requested: \(cue.text.prefix(40), privacy: .public)")
        // 先確保 Tier 1 完成(等待預跑,或補跑)。
        await prefetchTask?.value
        if drafts[cue.id] == nil {
            logger.notice("🫆 tier1 draft 缺失 → 先補跑 tier1")
            await runTier1(cue)
        }
        guard let draft = drafts[cue.id] else {
            // Tier 1 也失敗 → 不跑 Tier 2(保留 Tier 0)。中止原因 persist 供覆盤。
            logger.error("🫆 tier1 補跑仍無草稿(fast model 失敗?見 🧠 tier1 failed log)→ tier2 中止")
            cue.tier2Error = "Tier 1 無草稿(fast model 失敗)→ Tier 2 中止"
            try? cue.modelContext?.save()
            return
        }

        deepTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runTier2(cue, draft: draft)
        }
        deepTask = task
        await task.value
    }

    private func runTier2(_ cue: MeetingLiveCue, draft: Tier1Draft) async {
        let groundingStart = Date()
        let plan = groundingPlan(for: cue)
        let g = await grounding.gather(
            query: plan.query, brief: cue.session?.brief ?? "",
            includeRAG: plan.includeRAG, includeScreen: config.useScreenContext,   // Tier2 才抓螢幕
            sources: plan.sources)
        let groundingElapsed = Date().timeIntervalSince(groundingStart)
        logger.notice("🫆 tier2 接地完成 elapsed=\(groundingElapsed, format: .fixed(precision: 1), privacy: .public)s → deep model 串流開始")
        // M8 FR-48:aboutMe 變體。JSON 契約與既有 tier2System 相同(parser/overlay 不分支),
        // 只是 uncertainties 語意換成「筆記沒覆蓋、要我靠現場記憶補的部分」= 現場警示燈。
        let system = cue.kind == .aboutMe
            ? TierPrompts.tier2SystemAboutMe(persona: config.domainPersona)
            : TierPrompts.tier2System(persona: config.domainPersona)
        let user = cue.kind == .aboutMe
            ? TierPrompts.tier2UserAboutMe(cue: cue.text, draft: draft, grounding: g,
                                           aboutMeBrief: config.aboutMeBrief)
            : TierPrompts.tier2User(cue: cue.text, draft: draft, grounding: g)
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
    }

    func cancelDeep() {
        deepTask?.cancel()
        deepTask = nil
    }

    // MARK: - 測試 hook

    /// 測試用:等待預跑的 Tier 1 完成(免 sleep 輪詢;正式碼不呼叫)。
    func drainPrefetchForTest() async { await prefetchTask?.value }
}
