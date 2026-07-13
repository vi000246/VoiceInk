import Foundation
import SwiftData
import Combine
import os

/// M2 的 MVP 管線:
/// `MeetingLiveTranscriber.onRemoteCommitted` → `ResponseCueExtractor` → 去重(FR-10)
/// → persist 到 meeting.store → `@Published cues`(informational 依設定過濾,FR-11)。
///
/// 不含 Tier 回應(M3)、不含 overlay(M4)、不含頁面(M5)。
///
/// # Threading
/// `MeetingLiveTranscriber` 與 `onRemoteCommitted` 都在 `@MainActor`
/// (MeetingLiveTranscriber.swift:20)。抽取在 `Task` 內 await——`completeChat` 是
/// async,await 期間**不佔 main**;但 SwiftData `ModelContext` 非 Sendable,
/// 去重+persist 一律回到本類的 `@MainActor` 隔離內執行。
@MainActor
final class MeetingCopilotController: ObservableObject {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private let extractor: ResponseCueExtractor
    private let config: MeetingCopilotConfigStore
    private let modelContext: ModelContext
    /// cue 抽取實際用的 fast model("provider/model",觀測資料;由 live controller 解析後注入)。
    private let extractionModelLabel: String

    /// 目前的 live session(beginSession 建立並 persist;copilot 關閉時恆為 nil)。
    private(set) var session: MeetingLiveSession?

    /// 已偵測的 cue(依 `showInformationalCues` 過濾;FR-11)。下游 M3/M4 消費這個。
    @Published private(set) var cues: [MeetingLiveCue] = []

    /// Tier 2 進行中的 cue id(overlay 顯示「深度分析中…」;由點擊 handler 設定/清除)。
    @Published var deepInFlightCueId: UUID?

    /// M3 的三層回應編排器。設定後,每則新持久化的非 informational cue 會觸發
    /// Tier 0 + 預跑 Tier 1(`AnswerCoordinator.onNewCue`)。nil = 只偵測不回應(M2 行為)。
    var answerCoordinator: AnswerCoordinator?

    /// 在途抽取(每個 committed 一個 Task)。測試用 `drainInflight()` 等待。
    private var inflightTasks: [Task<Void, Never>] = []

    init(
        extractor: ResponseCueExtractor,
        config: MeetingCopilotConfigStore,
        modelContext: ModelContext,
        extractionModelLabel: String = ""
    ) {
        self.extractor = extractor
        self.config = config
        self.modelContext = modelContext
        self.extractionModelLabel = extractionModelLabel
    }

    // MARK: - Session lifecycle

    /// 建立並 persist 一個新 session。`copilotEnabled == false` 時 no-op(AC-9)。
    /// `configSnapshot` = 本場執行設定的 JSON(`MeetingCopilotRunConfig`),供事後調校對照。
    func beginSession(appName: String = "", configSnapshot: String = "") {
        guard config.copilotEnabled else { return }
        let s = MeetingLiveSession(appName: appName)
        s.configSnapshotRaw = configSnapshot
        modelContext.insert(s)
        try? modelContext.save()
        session = s
        cues = []
    }

    /// 掛上 M1 的接點。**只掛既有 closure,不改 MeetingLiveTranscriber 本體。**
    func attach(to transcriber: MeetingLiveTranscriber, appName: String = "", configSnapshot: String = "") {
        guard config.copilotEnabled else { return }
        beginSession(appName: appName, configSnapshot: configSnapshot)
        transcriber.onRemoteCommitted = { [weak self] text in
            self?.handleRemoteCommitted(text)
        }
        // local 段只進逐字稿時間軸(不抽 cue)——「我當時說了什麼」是覆盤上下文的另一半。
        transcriber.onLocalCommitted = { [weak self] text in
            self?.recordSegment(channel: .local, text: text)
        }
    }

    /// 收 session。傳入雙軌逐字稿快照(來自 transcriber,**stop 之後**讀,含最後 flush 的段落)。
    func endSession(remoteTranscript: String = "", localTranscript: String = "") {
        if !remoteTranscript.isEmpty { session?.remoteTranscriptRaw = remoteTranscript }
        if !localTranscript.isEmpty { session?.localTranscriptRaw = localTranscript }
        session?.endedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Cue pipeline

    /// 每段對方 committed → 開一個 Task 抽 cue。立即返回,不阻塞轉錄事件迴圈。
    func handleRemoteCommitted(_ text: String) {
        guard config.copilotEnabled, session != nil else {
            logger.notice("🧠 committed 到達但被略過(enabled=\(self.config.copilotEnabled, privacy: .public) session=\(self.session != nil, privacy: .public))")
            return
        }
        logger.notice("🧠 remote committed \(text.count, privacy: .public) 字 → cue 抽取")
        // 先落 segment:就算抽出 0 則,「這段話當時被看過、模型怎麼回」也要留下——
        // 漏抓只能從完整時間軸對照出來。
        let segment = recordSegment(channel: .remote, text: text)
        let extractor = self.extractor
        let logger = self.logger
        let task = Task { [weak self] in
            // completeChat 為 async——await 期間讓出 main;失敗 extractor 已回空 outcome。
            let outcome = await extractor.extract(committed: text)
            guard !Task.isCancelled else { return }
            self?.recordExtraction(outcome, on: segment)
            guard !outcome.cues.isEmpty else {
                logger.notice("🧠 cue 抽取結果:0 則(fast model 判定無 cue,或呼叫失敗——見 🥡 log)")
                return
            }
            self?.ingest(outcome.cues, sourceText: text, at: Date(), segment: segment)
        }
        inflightTasks.append(task)
    }

    /// 一段 committed 落入逐字稿時間軸。@MainActor(context 非 Sendable)。
    @discardableResult
    func recordSegment(channel: MeetingSegmentChannel, text: String) -> MeetingLiveSegment? {
        guard config.copilotEnabled, let session else { return nil }
        let segment = MeetingLiveSegment(session: session, channel: channel, text: text)
        modelContext.insert(segment)
        try? modelContext.save()
        return segment
    }

    /// 抽取結果(含失敗)回寫 segment 的偵測 provenance。
    private func recordExtraction(_ outcome: CueExtractionOutcome, on segment: MeetingLiveSegment?) {
        guard let segment else { return }
        segment.extractionModel = extractionModelLabel
        segment.extractionReplyRaw = outcome.rawReply
        segment.extractionError = outcome.errorDescription
        segment.extractionElapsedMs = outcome.elapsedMs
        segment.extractedCount = outcome.cues.count
        try? modelContext.save()
    }

    /// 去重 + persist + 更新暴露面。@MainActor(context 非 Sendable)。
    func ingest(_ extracted: [ExtractedCue], sourceText: String, at time: Date, segment: MeetingLiveSegment? = nil) {
        guard let session else { return }
        var persistedAny = false
        var dedupDropped = 0
        for e in extracted {
            let existing = (session.cues ?? []).map { (text: $0.text, askedAt: $0.askedAt) }
            if MeetingCueDeduplicator.isDuplicate(text: e.text, at: time, existing: existing) {
                dedupDropped += 1
                continue   // FR-10:相似 cue 不重覆 persist
            }
            let cue = MeetingLiveCue(
                session: session,
                text: e.text,
                kind: e.kind,
                askedAt: time,
                contextExcerpt: String(sourceText.prefix(300)))
            cue.sourceSegmentId = segment?.id
            // committed 到 persist 的全程延遲(含抽取 LLM 往返)——「cue 多久才浮上 overlay」。
            if let segment {
                cue.detectionElapsedMs = max(0, Int(time.timeIntervalSince(segment.committedAt) * 1000))
            }
            modelContext.insert(cue)
            persistedAny = true
            logger.notice("🧠 cue [\(e.kind.rawValue, privacy: .public)] \(e.text, privacy: .public)")

            // M3:非 informational cue 觸發三層回應(Tier 0 + 預跑 Tier 1)。
            // coordinator == nil 時(M2 行為)不動作。
            if e.kind != .informational, let coordinator = answerCoordinator {
                let cueRef = cue
                Task { await coordinator.onNewCue(cueRef) }
            }
        }
        segment?.dedupDroppedCount = dedupDropped
        if persistedAny || dedupDropped > 0 { try? modelContext.save() }
        refreshPublishedCues()
    }

    /// FR-11:informational persist 但預設不暴露;開關切換後呼叫本方法重算。
    func refreshPublishedCues() {
        let all = (session?.cues ?? []).sorted { $0.askedAt < $1.askedAt }
        cues = config.showInformationalCues
            ? all
            : all.filter { $0.kind != .informational }
    }

    /// 測試用:等待所有在途抽取完成。
    func drainInflight() async {
        let tasks = inflightTasks
        inflightTasks.removeAll()
        for task in tasks { await task.value }
    }

    // MARK: - 正式 fast completer 工廠(Task 8 的 DEBUG runner 與未來 M3 共用)

    /// 解析 fast model 並組出正式 `ChatCompleting`。
    /// 借用既有純函式 `AskAIAnswerModel.resolve`(AskAIConfig.swift:31-39)+
    /// AskAIView.swift:431-439 的 provider 回退接線;M3 引入
    /// `MeetingCopilotModels.resolve` 時只需替換這一處。
    static func makeFastCompleter(
        aiService: AIService,
        config: MeetingCopilotConfigStore
    ) -> ChatCompleting {
        let resolved = AskAIAnswerModel.resolve(
            storedProvider: config.fastProviderName,
            storedModel: config.fastModelName,
            defaultProvider: aiService.selectedProvider.rawValue,
            available: aiService.connectedProviders.map(\.rawValue))
        let provider = AIProvider(rawValue: resolved.provider) ?? aiService.selectedProvider
        return MeetingFastChatCompleter(
            aiService: aiService, provider: provider, modelName: resolved.model)
    }
}
