import XCTest
import SwiftData
@testable import VoiceInk

private struct FixedCompleter: ChatCompleting {
    let reply: String
    let onCall: (@Sendable () -> Void)?
    func complete(system: String, user: String) async throws -> String {
        onCall?()
        return reply
    }
}

@MainActor
final class AskAIAnswerTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func insertChunk(_ ctx: ModelContext, tid: UUID, text: String, vector: [Float]) {
        ctx.insert(EmbeddingChunk(
            transcriptionId: tid, chunkIndex: 0, text: text,
            vector: EmbeddingClient.floatsToData(EmbeddingClient.normalize(vector)), dims: 2,
            embeddingModel: EmbeddingModel.gemini001_768.tag, sourceKind: "dictation",
            categoryId: nil, timestamp: .now))
    }

    // 引用只映射到實際檢索到的塊。
    func testCitationsMapToRetrievedChunks() {
        let a = ScoredChunk(chunk: EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 5, text: "片段A",
            vector: Data(), dims: 2, embeddingModel: "m", sourceKind: "dictation", categoryId: nil, timestamp: .now), score: 0.9)
        let b = ScoredChunk(chunk: EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 2, text: "片段B",
            vector: Data(), dims: 2, embeddingModel: "m", sourceKind: "dictation", categoryId: nil, timestamp: .now), score: 0.8)
        let refs = AskAIService.extractCitations(from: "答案 [1] 還有 [2]。", retrieved: [a, b])
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs[0].chunkIndex, 5)
        XCTAssertEqual(refs[1].chunkIndex, 2)
    }

    // 越界引用 [9](只有 1 塊)被剔除;不重複。
    func testOutOfRangeAndDuplicateCitationsDropped() {
        let a = ScoredChunk(chunk: EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "只有一塊",
            vector: Data(), dims: 2, embeddingModel: "m", sourceKind: "dictation", categoryId: nil, timestamp: .now), score: 1)
        let refs = AskAIService.extractCitations(from: "看 [1] 和 [1] 還有 [9]。", retrieved: [a])
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].chunkIndex, 0)
    }

    // 檢索為空 → 不呼叫生成,回「找不到」。
    func testEmptyRetrievalShortCircuits() async throws {
        let ctx = try makeContext()
        var completerCalled = false
        let embedder = FakeEmbedder(map: ["問題": [1, 0]], dims: 2)
        let completer = FixedCompleter(reply: "不該被呼叫", onCall: { completerCalled = true })
        AskAIService.shared.configureForTesting(embedder: embedder, completer: completer)

        // 索引為空。
        let message = try await AskAIService.shared.ask(
            question: "問題", scope: .all, thread: nil, model: .gemini001_768, context: ctx)
        XCTAssertFalse(completerCalled)
        XCTAssertTrue(message.text.contains("找不到"))
        XCTAssertTrue(message.citations.isEmpty)
    }

    // 完整流程:檢索到塊 → 生成帶引用 → 引用正確映射 + thread 持久化。
    func testAskPersistsThreadWithCitations() async throws {
        let ctx = try makeContext()
        let tid = UUID()
        insertChunk(ctx, tid: tid, text: "承諾下週三交付。", vector: [1, 0])
        try ctx.save()

        let embedder = FakeEmbedder(map: ["誰承諾了什麼": [1, 0]], dims: 2)
        let completer = FixedCompleter(reply: "有人承諾下週三交付 [1]。", onCall: nil)
        AskAIService.shared.configureForTesting(embedder: embedder, completer: completer)

        let message = try await AskAIService.shared.ask(
            question: "誰承諾了什麼", scope: .all, thread: nil, model: .gemini001_768, context: ctx)
        XCTAssertEqual(message.citations.count, 1)
        XCTAssertEqual(message.citations[0].transcriptionId, tid)

        // thread 有 user + assistant 兩則,持久化到 store。
        let messages = try ctx.fetch(FetchDescriptor<AskAIMessage>())
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(Set(messages.map(\.role)), ["user", "assistant"])
    }
}
