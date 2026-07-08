import XCTest
import SwiftData
@testable import VoiceInk

/// 回固定向量的假嵌入器:把每段文字對映到指定向量,供索引/檢索測試脫離網路。
struct FakeEmbedder: EmbeddingProviding {
    let map: [String: [Float]]
    let dims: Int
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        texts.map { text in
            let base = map[text] ?? [Float](repeating: 0, count: dims)
            return EmbeddingClient.normalize(base)
        }
    }
}

@MainActor
final class AskAIIndexServiceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transcription.self, ImportLedgerEntry.self, EmbeddingChunk.self,
            AskAIThread.self, AskAIMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    func testUpsertIsIdempotentByChunkIdentity() async throws {
        let ctx = try makeContext()
        let embedder = FakeEmbedder(map: ["內容一。": [1, 0], "內容二。": [0, 1]], dims: 2)
        TranscriptIndexService.shared.configureForTesting(modelContext: ctx, embedder: embedder)

        let t = Transcription(text: "內容一。\n內容二。", duration: 1)
        ctx.insert(t); try ctx.save()

        let n1 = try await TranscriptIndexService.shared.upsert(t)
        let n2 = try await TranscriptIndexService.shared.upsert(t)   // 重跑
        XCTAssertEqual(n1, n2)
        // 兩次 upsert 後,索引中該 transcription 只有一組塊。
        let chunks = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
        XCTAssertEqual(chunks.count, n1)
    }

    func testDeleteChunksRemovesOnlyThatTranscription() async throws {
        let ctx = try makeContext()
        let embedder = FakeEmbedder(map: ["A。": [1, 0], "B。": [0, 1]], dims: 2)
        TranscriptIndexService.shared.configureForTesting(modelContext: ctx, embedder: embedder)

        let t1 = Transcription(text: "A。", duration: 1)
        let t2 = Transcription(text: "B。", duration: 1)
        ctx.insert(t1); ctx.insert(t2); try ctx.save()
        _ = try await TranscriptIndexService.shared.upsert(t1)
        _ = try await TranscriptIndexService.shared.upsert(t2)

        TranscriptIndexService.shared.deleteChunks(transcriptionId: t1.id)
        let remaining = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
        XCTAssertTrue(remaining.allSatisfy { $0.transcriptionId == t2.id })
    }

    func testReconcileRemovesOrphans() async throws {
        let ctx = try makeContext()
        let embedder = FakeEmbedder(map: ["X。": [1, 0]], dims: 2)
        TranscriptIndexService.shared.configureForTesting(modelContext: ctx, embedder: embedder)

        let t = Transcription(text: "X。", duration: 1)
        ctx.insert(t); try ctx.save()
        _ = try await TranscriptIndexService.shared.upsert(t)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EmbeddingChunk>()), 1)

        ctx.delete(t); try ctx.save()          // 刪掉核心 Transcription(索引尚有孤兒塊)
        TranscriptIndexService.shared.reconcileOrphans()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EmbeddingChunk>()), 0)
    }

    func testSourceKindClassification() {
        let dictation = Transcription(text: "d", duration: 1)
        XCTAssertEqual(TranscriptIndexService.sourceKind(for: dictation), "dictation")

        let recorder = Transcription(text: "r", duration: 1)
        recorder.importFingerprint = "fp"
        XCTAssertEqual(TranscriptIndexService.sourceKind(for: recorder), "recorder")

        let meeting = Transcription(text: "m", duration: 1)
        meeting.importFingerprint = "fp"
        meeting.recorderSourceLabel = "會議 · Zoom"
        XCTAssertEqual(TranscriptIndexService.sourceKind(for: meeting), "meeting")
    }
}

@MainActor
final class AskAIRetrievalTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func insertChunk(_ ctx: ModelContext, tid: UUID, vector: [Float], model: EmbeddingModel,
                             sourceKind: String, timestamp: Date, categoryId: UUID? = nil) {
        ctx.insert(EmbeddingChunk(
            transcriptionId: tid, chunkIndex: 0, text: "t",
            vector: EmbeddingClient.floatsToData(EmbeddingClient.normalize(vector)), dims: model.dims,
            embeddingModel: model.tag, sourceKind: sourceKind, categoryId: categoryId, timestamp: timestamp))
    }

    func testTopKOrdersByScore() throws {
        let ctx = try makeContext()
        insertChunk(ctx, tid: UUID(), vector: [1, 0], model: .gemini001_768, sourceKind: "dictation", timestamp: .now)
        insertChunk(ctx, tid: UUID(), vector: [0.7, 0.7], model: .gemini001_768, sourceKind: "dictation", timestamp: .now)
        insertChunk(ctx, tid: UUID(), vector: [0, 1], model: .gemini001_768, sourceKind: "dictation", timestamp: .now)
        try ctx.save()

        let query = EmbeddingClient.normalize([1, 0])
        let results = RetrievalService.retrieve(queryVector: query, scope: .all, k: 3,
                                                model: .gemini001_768, context: ctx)
        XCTAssertEqual(results.count, 3)
        XCTAssertGreaterThanOrEqual(results[0].score, results[1].score)
        XCTAssertGreaterThanOrEqual(results[1].score, results[2].score)
        // [1,0] 應排第一。
        XCTAssertEqual(results[0].score, 1.0, accuracy: 1e-5)
    }

    func testScopeFiltersSourceAndDateAndModel() throws {
        let ctx = try makeContext()
        let now = Date()
        insertChunk(ctx, tid: UUID(), vector: [1, 0], model: .gemini001_768, sourceKind: "meeting", timestamp: now)
        insertChunk(ctx, tid: UUID(), vector: [1, 0], model: .gemini001_768, sourceKind: "dictation", timestamp: now)
        // 範圍外(舊日期)
        insertChunk(ctx, tid: UUID(), vector: [1, 0], model: .gemini001_768, sourceKind: "meeting",
                    timestamp: now.addingTimeInterval(-100 * 86400))
        // 不同向量空間(OpenAI)——永不混比,但維度不同,這裡用相同維度只測 model tag 過濾
        ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "x",
            vector: EmbeddingClient.floatsToData(EmbeddingClient.normalize([1, 0])), dims: 2,
            embeddingModel: EmbeddingModel.openaiSmall1536.tag, sourceKind: "meeting", categoryId: nil, timestamp: now))
        try ctx.save()

        let scope = AskAIScope(sources: ["meeting"], categoryId: nil,
                               dateRange: now.addingTimeInterval(-7 * 86400)...now.addingTimeInterval(86400))
        let results = RetrievalService.retrieve(queryVector: EmbeddingClient.normalize([1, 0]),
                                                scope: scope, k: 10, model: .gemini001_768, context: ctx)
        // 只剩:meeting + 近 7 天 + gemini 模型 = 1 筆。
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].chunk.sourceKind, "meeting")
        XCTAssertEqual(results[0].chunk.embeddingModel, EmbeddingModel.gemini001_768.tag)
    }

    func testCategoryFilterInMemory() throws {
        let ctx = try makeContext()
        let cat = UUID()
        insertChunk(ctx, tid: UUID(), vector: [1, 0], model: .gemini001_768, sourceKind: "recorder", timestamp: .now, categoryId: cat)
        insertChunk(ctx, tid: UUID(), vector: [1, 0], model: .gemini001_768, sourceKind: "recorder", timestamp: .now, categoryId: UUID())
        try ctx.save()

        let scope = AskAIScope(sources: nil, categoryId: cat, dateRange: nil)
        let results = RetrievalService.retrieve(queryVector: EmbeddingClient.normalize([1, 0]),
                                                scope: scope, k: 10, model: .gemini001_768, context: ctx)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].chunk.categoryId, cat)
    }
}
