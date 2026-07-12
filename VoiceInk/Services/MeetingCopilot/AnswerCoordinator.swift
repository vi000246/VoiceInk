import Foundation
import SwiftData
import Combine
import os

/// 接地的可注入介面(測試注入 noop / fake)。
protocol MeetingGroundingProviding {
    func gather(cueText: String, brief: String, includeRAG: Bool, includeScreen: Bool) async -> MeetingGrounding
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

    private var prefetchTask: Task<Void, Never>?
    private var deepTask: Task<Void, Never>?
    /// 已完成的 Tier 1 草稿(cue.id → draft),供 requestDeep 零等待取用。
    private var drafts: [UUID: Tier1Draft] = [:]

    init(
        fast: StreamingChatCompleting,
        deep: StreamingChatCompleting,
        grounding: MeetingGroundingProviding,
        config: MeetingCopilotConfigStore = .shared
    ) {
        self.fast = fast
        self.deep = deep
        self.grounding = grounding
        self.config = config
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

    // MARK: - Tier 1

    private func runTier1(_ cue: MeetingLiveCue) async {
        let g = await grounding.gather(
            cueText: cue.text, brief: cue.session?.brief ?? "",
            includeRAG: config.useHistoryRAG, includeScreen: false)   // Tier1 不抓螢幕
        let system = TierPrompts.tier1System(persona: config.domainPersona)
        let user = TierPrompts.tier1User(cue: cue.text, grounding: g)

        var acc = ""
        do {
            for try await d in fast.stream(system: system, user: user) {
                if Task.isCancelled { return }
                acc += d
            }
        } catch {
            // Tier 1 失敗 → 保留 Tier 0,log-only(FR-28)。
            logger.error("🧠 tier1 failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }

        let draft = TierParsers.parseTier1(AIEnhancementOutputFilter.filter(acc))
        drafts[cue.id] = draft
        cue.tier1Opener = draft.opener
        cue.tier1Bullets = draft.bullets.filter { !$0.isEmpty }
        cue.fastModelName = "fast"   // 具體 model 名由 live completer 端已知;M3 標記已產生
        try? cue.modelContext?.save()
    }

    // MARK: - Tier 2(點擊才跑,帶入 Tier 1 草稿)

    func requestDeep(_ cue: MeetingLiveCue) async {
        // 先確保 Tier 1 完成(等待預跑,或補跑)。
        await prefetchTask?.value
        if drafts[cue.id] == nil {
            await runTier1(cue)
        }
        guard let draft = drafts[cue.id] else {
            // Tier 1 也失敗 → 不跑 Tier 2(保留 Tier 0)。
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
        let g = await grounding.gather(
            cueText: cue.text, brief: cue.session?.brief ?? "",
            includeRAG: config.useHistoryRAG, includeScreen: config.useScreenContext)   // Tier2 才抓螢幕
        let system = TierPrompts.tier2System(persona: config.domainPersona)
        let user = TierPrompts.tier2User(cue: cue.text, draft: draft, grounding: g)

        var acc = ""
        do {
            for try await d in deep.stream(system: system, user: user) {
                if Task.isCancelled { return }
                acc += d
            }
        } catch {
            // Tier 2 失敗 → 保留 Tier 1(status 不變 .answered),log-only,無可見 UI(FR-28)。
            logger.error("🧠 tier2 failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }

        let analysis = TierParsers.parseTier2(AIEnhancementOutputFilter.filter(acc))
        cue.tier2Analysis = analysis.analysis
        cue.tier2FollowUps = analysis.followUps.map(\.displayLine)
        cue.tier2Uncertainties = analysis.uncertainties
        cue.deepModelName = "deep"
        cue.answeredAt = Date()
        cue.status = .answered
        try? cue.modelContext?.save()
    }

    func cancelDeep() {
        deepTask?.cancel()
        deepTask = nil
    }
}
