import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class AskAIIndexTests: XCTestCase {
    func testIndexStoreRoundtrip() throws {
        let container = try ModelContainer(
            for: EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)

        let tid = UUID()
        ctx.insert(EmbeddingChunk(transcriptionId: tid, chunkIndex: 0, text: "hi",
                                  vector: Data([0, 0, 128, 63]), dims: 1,
                                  embeddingModel: "test-model", sourceKind: "dictation",
                                  categoryId: nil, timestamp: .now))
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EmbeddingChunk>()), 1)

        let fetched = try ctx.fetch(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.transcriptionId == tid })).first
        XCTAssertEqual(fetched?.chunkIndex, 0)
        XCTAssertEqual(fetched?.embeddingModel, "test-model")
    }

    func testThreadMessageCascadeAndCitations() throws {
        let container = try ModelContainer(
            for: EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)

        let thread = AskAIThread(title: "測試對話")
        ctx.insert(thread)
        let message = AskAIMessage(thread: thread, role: "assistant", text: "答案 [1]")
        let ref = ChunkRef(transcriptionId: UUID(), chunkIndex: 2, excerpt: "來源片段")
        message.citations = [ref]
        ctx.insert(message)
        try ctx.save()

        let loaded = try ctx.fetch(FetchDescriptor<AskAIMessage>()).first
        XCTAssertEqual(loaded?.citations, [ref])
        XCTAssertEqual(loaded?.thread?.title, "測試對話")

        // cascade:刪 thread → message 一起走。
        ctx.delete(thread)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<AskAIMessage>()), 0)
    }

    /// M8 Task 3(AC-30):obsidian 筆記塊沒有對應 Transcription,永遠是「孤兒」——
    /// reconcileOrphans 只能清轉錄類孤兒塊,不得順手把筆記索引清空。
    func testReconcileOrphansPreservesObsidianChunks() throws {
        let container = try ModelContainer(
            for: Transcription.self, EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)

        ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "孤兒轉錄塊",
                                  vector: Data(), dims: 1, embeddingModel: "t", sourceKind: "dictation",
                                  categoryId: nil, timestamp: .now))
        ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "《筆記》塊",
                                  vector: Data(), dims: 1, embeddingModel: "t", sourceKind: "obsidian",
                                  categoryId: nil, timestamp: .now))
        try ctx.save()

        TranscriptIndexService.shared.configureForTesting(
            modelContext: ctx, embedder: FakeEmbedder(map: [:], dims: 1))
        TranscriptIndexService.shared.reconcileOrphans()

        let left = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.sourceKind, "obsidian")
    }

    /// AC-9:M8 之前的三欄 JSON 必須照常 decode(新欄 nil)。
    func testChunkRefDecodesLegacyThreeFieldJSON() throws {
        let legacy = #"[{"transcriptionId":"00000000-0000-0000-0000-000000000001","chunkIndex":0,"excerpt":"舊引用"}]"#
        let refs = try JSONDecoder().decode([ChunkRef].self, from: Data(legacy.utf8))
        XCTAssertEqual(refs.first?.excerpt, "舊引用")
        XCTAssertNil(refs.first?.sourceTitle)
        XCTAssertNil(refs.first?.sourcePath)
    }

    /// FR-10:引用鏈全程攜帶筆記出處——extractCitations 從塊上的 metadata 帶進 ChunkRef。
    @MainActor
    func testExtractCitationsCarriesNoteMetadata() throws {
        let chunk = EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "《專案A》內容",
            vector: Data(), dims: 0, embeddingModel: "m", sourceKind: "obsidian",
            categoryId: nil, timestamp: Date(), sourceTitle: "專案A", sourcePath: "工作/專案A.md")
        let refs = AskAIService.extractCitations(from: "答案 [1]", retrieved: [ScoredChunk(chunk: chunk, score: 1)])
        XCTAssertEqual(refs.first?.sourceTitle, "專案A")
        XCTAssertEqual(refs.first?.sourcePath, "工作/專案A.md")
    }

    /// FR-12:只問筆記、但筆記索引是空的 → 訊息要指到「筆記來源設定」，
    /// 而不是那句對筆記毫無幫助的「重建索引」（那顆按鈕只重建逐字稿）。
    @MainActor
    func testDiagnoseNotesOnlyEmptyIndexPointsToNotesSettings() {
        let msg = AskAIService.emptyRetrievalMessage(
            scopeSources: ["obsidian"], totalAll: 50, forModel: 50, obsidianCount: 0,
            hasCategoryOrDateFilter: false)
        XCTAssertTrue(msg.contains("筆記"), msg)
        XCTAssertTrue(msg.contains("筆記來源設定") || msg.contains("重建"), msg)
    }

    /// 混合 scope（轉錄＋筆記）且筆記空:不能誤導成「筆記沒索引」——轉錄塊可能只是沒命中。
    @MainActor
    func testDiagnoseMixedScopeEmptyNotesFallsBackToFilterMessage() {
        let msg = AskAIService.emptyRetrievalMessage(
            scopeSources: ["dictation", "obsidian"], totalAll: 50, forModel: 50, obsidianCount: 0,
            hasCategoryOrDateFilter: false)
        XCTAssertFalse(msg.contains("筆記來源設定"), msg)
    }
}
