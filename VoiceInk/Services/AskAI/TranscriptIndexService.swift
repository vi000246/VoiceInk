import Foundation
import SwiftData
import os

/// 可注入的嵌入來源(測試用 fake 回固定向量,正式走 EmbeddingClient)。
protocol EmbeddingProviding {
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]]
}

struct LiveEmbedder: EmbeddingProviding {
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        try await EmbeddingClient.embed(texts: texts, model: model)
    }
}

/// 索引生命週期:轉錄完成 → upsert;轉錄刪除(批次 nil 訊號)→ reconcile 掃孤兒;
/// backfill 回填既有歷史(冪等、可中斷、進度)。索引只讀核心資料,從不變更 Transcription。
@MainActor
final class TranscriptIndexService: ObservableObject {
    static let shared = TranscriptIndexService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AskAI")

    struct Progress: Equatable { var done: Int; var total: Int; var estimatedTokens: Int }

    private var modelContext: ModelContext?
    private var embedder: EmbeddingProviding = LiveEmbedder()
    private var observers: [NSObjectProtocol] = []

    /// 回填進度（nil = 沒在跑）。**持有在 service 上而非 view 的 `@State`**：回填動輒幾分鐘，
    /// 使用者一定會切走去做別的事；進度掛在 view 上的話，一離開 Ask AI 頁進度就消失，
    /// 回來只看得到一片空白（工作其實還在跑）——鏡射 `NoteIndexCoordinator` 的理由。
    @Published private(set) var backfillProgress: Progress?
    /// 回填的 in-flight 真相；由 service 持有 → view 生命週期碰不到它。
    private var backfillTask: Task<Void, Never>?
    var isBackfilling: Bool { backfillTask != nil }

    /// 目前使用的 embedding 模型(向量空間標籤)。換模型需全量重嵌。
    var model: EmbeddingModel {
        get {
            EmbeddingModel(rawValue: UserDefaults.standard.string(forKey: "askAIEmbeddingModelV1") ?? "")
                ?? .gemini001_768
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "askAIEmbeddingModelV1") }
    }

    private init() {}

    /// 測試注入點。
    func configureForTesting(modelContext: ModelContext, embedder: EmbeddingProviding) {
        self.modelContext = modelContext
        self.embedder = embedder
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = [
            NotificationCenter.default.addObserver(
                forName: .transcriptionCompleted, object: nil, queue: .main
            ) { note in
                guard let t = note.object as? Transcription else { return }
                Task { @MainActor in try? await TranscriptIndexService.shared.upsert(t) }
            },
            NotificationCenter.default.addObserver(
                forName: .transcriptionDeleted, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in TranscriptIndexService.shared.reconcileOrphans() }
            }
        ]
    }

    // MARK: - Source kind

    nonisolated static func sourceKind(for t: Transcription) -> String {
        if t.recorderSourceLabel != nil { return "meeting" }
        if t.importFingerprint != nil { return "recorder" }
        return "dictation"
    }

    // MARK: - Upsert (idempotent by transcriptionId)

    @discardableResult
    func upsert(_ transcription: Transcription) async throws -> Int {
        guard let ctx = modelContext else { return 0 }
        let tid = transcription.id
        let indexText = transcription.enhancedText ?? transcription.text
        let drafts = TranscriptChunker.chunks(for: indexText,
                                              speakerSegments: transcription.speakerSegmentsAreNative ? transcription.speakerSegments : [])
        guard !drafts.isEmpty else { deleteChunks(transcriptionId: tid); return 0 }

        let vectors = try await embedder.embed(texts: drafts.map(\.text), model: model)
        guard vectors.count == drafts.count else {
            throw EmbeddingError.countMismatch(expected: drafts.count, got: vectors.count)
        }

        // 取代式 upsert:先刪同 id 舊塊,再插新塊(單次 save)。
        deleteChunks(transcriptionId: tid, save: false)
        let kind = Self.sourceKind(for: transcription)
        for (draft, vector) in zip(drafts, vectors) {
            ctx.insert(EmbeddingChunk(
                transcriptionId: tid, chunkIndex: draft.index, text: draft.text,
                vector: EmbeddingClient.floatsToData(vector), dims: model.dims,
                embeddingModel: model.tag, sourceKind: kind,
                categoryId: transcription.recorderCategoryId, timestamp: transcription.timestamp))
        }
        try? ctx.save()
        return drafts.count
    }

    // MARK: - Delete

    func deleteChunks(transcriptionId: UUID, save: Bool = true) {
        guard let ctx = modelContext else { return }
        let existing = (try? ctx.fetch(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.transcriptionId == transcriptionId }))) ?? []
        for chunk in existing { ctx.delete(chunk) }
        if save { try? ctx.save() }
    }

    /// `.transcriptionDeleted` 是批次 nil 訊號(不帶 id)→ 掃索引中已無對應 Transcription 的孤兒塊。
    /// 注意:obsidian 筆記塊的 transcriptionId 是筆記路徑衍生的合成 id,本來就沒有對應的
    /// Transcription,永遠會被判成「孤兒」——不先排除的話,任一次轉錄刪除就會把整個筆記索引清空。
    func reconcileOrphans() {
        guard let ctx = modelContext else { return }
        let allChunks = (try? ctx.fetch(FetchDescriptor<EmbeddingChunk>())) ?? []
        // 候選集合只含轉錄類塊(dictation/recorder/meeting);obsidian 走自己的 reindex 生命週期。
        let candidates = allChunks.filter { $0.sourceKind != ObsidianNoteIndexService.sourceKind }
        let indexedIds = Set(candidates.map(\.transcriptionId))
        guard !indexedIds.isEmpty else { return }
        let liveIds = Set((try? ctx.fetch(FetchDescriptor<Transcription>()))?.map(\.id) ?? [])
        let orphanIds = indexedIds.subtracting(liveIds)
        guard !orphanIds.isEmpty else { return }
        for chunk in candidates where orphanIds.contains(chunk.transcriptionId) { ctx.delete(chunk) }
        try? ctx.save()
        logger.notice("Reconciled \(orphanIds.count, privacy: .public) orphaned transcription(s) from index")
    }

    // MARK: - Backfill

    /// 估算回填總 token 數(費用預估用;不打網路)。
    func estimateBackfillTokens() -> Int {
        guard let ctx = modelContext else { return 0 }
        let all = (try? ctx.fetch(FetchDescriptor<Transcription>())) ?? []
        return all.reduce(0) { $0 + TokenEstimator.estimate($1.enhancedText ?? $1.text) }
    }

    /// 回填所有既有轉錄。冪等(重跑不產生重複塊)、可中斷、single-flight。
    ///
    /// Task 由 service 持有（不是呼叫端的 view）：離開 Ask AI 頁、切到別的分頁，回填照跑，
    /// 回來時 `backfillProgress` 還在，畫面接得回去。重複按也只會有一輪在跑。
    func startBackfill() {
        guard backfillTask == nil else { return }
        backfillProgress = Progress(done: 0, total: 0, estimatedTokens: 0)
        backfillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // 成功/失敗/取消都要收乾淨——漏掉任一條路徑，backfillTask 就永遠非 nil，
            // 之後所有回填入口全部靜默 no-op。
            defer {
                self.backfillTask = nil
                self.backfillProgress = nil
            }
            guard let ctx = self.modelContext else { return }
            let all = (try? ctx.fetch(FetchDescriptor<Transcription>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))) ?? []
            let total = all.count
            let estTokens = self.estimateBackfillTokens()
            var done = 0
            self.backfillProgress = Progress(done: 0, total: total, estimatedTokens: estTokens)
            for t in all {
                if Task.isCancelled { return }
                try? await self.upsert(t)
                done += 1
                self.backfillProgress = Progress(done: done, total: total, estimatedTokens: estTokens)
            }
        }
    }

    func cancelBackfill() { backfillTask?.cancel() }

    /// 換 embedding 模型 → 清空整個索引(向量空間不相容)並更新標籤。呼叫端接著觸發 backfill。
    func switchModel(to newModel: EmbeddingModel) {
        guard let ctx = modelContext else { return }
        let all = (try? ctx.fetch(FetchDescriptor<EmbeddingChunk>())) ?? []
        for chunk in all { ctx.delete(chunk) }
        try? ctx.save()
        model = newModel
        logger.notice("Switched embedding model to \(newModel.tag, privacy: .public); index cleared")
    }
}
