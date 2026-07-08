import XCTest
import SwiftData
@testable import VoiceInk

/// Plan D（Ask AI 增強）：答案模型解析、來源二分映射、單檔 scope、範本 persona 注入。
@MainActor
final class AskAIEnhancementTests: XCTestCase {

    // MARK: - Task 1: 答案模型解析

    func testAnswerModelResolvesToConfiguredOrDefault() {
        // 未設定 → 回預設 provider、nil model。
        let unset = AskAIAnswerModel.resolve(storedProvider: nil, storedModel: nil,
                                             defaultProvider: "OpenAI", available: ["OpenAI", "Gemini"])
        XCTAssertEqual(unset.provider, "OpenAI")
        XCTAssertNil(unset.model)

        // 設了且可用 → 用設定值。
        let set = AskAIAnswerModel.resolve(storedProvider: "Gemini", storedModel: "gemini-2.5-pro",
                                           defaultProvider: "OpenAI", available: ["OpenAI", "Gemini"])
        XCTAssertEqual(set.provider, "Gemini")
        XCTAssertEqual(set.model, "gemini-2.5-pro")

        // 設了但已不在可用清單 → 退回預設。
        let stale = AskAIAnswerModel.resolve(storedProvider: "Gemini", storedModel: "gemini-2.5-pro",
                                             defaultProvider: "OpenAI", available: ["OpenAI"])
        XCTAssertEqual(stale.provider, "OpenAI")
        XCTAssertNil(stale.model)
    }

    // MARK: - Task 2: 來源二分映射

    func testSourceFilterRecorderIncludesMeeting() {
        XCTAssertNil(AskAISourceFilter.all.sources)
        XCTAssertEqual(AskAISourceFilter.voice.sources, ["dictation"])
        XCTAssertEqual(AskAISourceFilter.recorder.sources, ["recorder", "meeting"])
    }

    // MARK: - Task 3: 單檔 scope 限定

    private func makeIndexContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self, AskAITemplate.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func insertChunk(_ ctx: ModelContext, tid: UUID, vector: [Float]) {
        ctx.insert(EmbeddingChunk(
            transcriptionId: tid, chunkIndex: 0, text: "t",
            vector: EmbeddingClient.floatsToData(EmbeddingClient.normalize(vector)),
            dims: EmbeddingModel.gemini001_768.dims,
            embeddingModel: EmbeddingModel.gemini001_768.tag, sourceKind: "recorder",
            categoryId: nil, timestamp: .now))
    }

    func testSingleTranscriptionScopeRestricts() throws {
        let ctx = try makeIndexContext()
        let a = UUID(), b = UUID()
        insertChunk(ctx, tid: a, vector: [1, 0])
        insertChunk(ctx, tid: b, vector: [1, 0])   // 同向量，只靠 transcriptionId 區分
        try ctx.save()

        let scope = AskAIScope(transcriptionId: a)
        let results = RetrievalService.retrieve(queryVector: EmbeddingClient.normalize([1, 0]),
                                                scope: scope, k: 10, model: .gemini001_768, context: ctx)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].chunk.transcriptionId, a)
    }

    // MARK: - Task 4: 範本 persona 注入（引用規則永遠保留）

    func testTemplateSystemPromptApplied() {
        let withPersona = AskAIService.systemPrompt(persona: "你是資深面試官，聚焦臨場反應。")
        XCTAssertTrue(withPersona.contains("你是資深面試官"))
        // 引用規則段必須保留（否則幻覺防護失效）。
        XCTAssertTrue(withPersona.contains("[n]"))
        XCTAssertTrue(withPersona.contains("找不到"))
    }

    func testNilPersonaUsesDefaultButKeepsCitationRules() {
        let base = AskAIService.systemPrompt(persona: nil)
        XCTAssertTrue(base.contains(AskAIService.defaultPersona))
        XCTAssertTrue(base.contains("[n]"))

        // 空白 persona 等同 nil。
        let blank = AskAIService.systemPrompt(persona: "   ")
        XCTAssertTrue(blank.contains(AskAIService.defaultPersona))
    }
}
