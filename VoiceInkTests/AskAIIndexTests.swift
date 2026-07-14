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
}
