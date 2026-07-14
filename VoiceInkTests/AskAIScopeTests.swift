import XCTest
import SwiftData
@testable import VoiceInk

final class AskAIScopeTests: XCTestCase {
    /// 🔴 漏洞回歸鎖：.all 絕不可回到 nil（nil = 不過濾 = obsidian 塊漏進預設查詢）。
    func testAllSourceFilterIsExplicitTranscriptKinds() {
        XCTAssertEqual(AskAISourceFilter.all.sources, ["dictation", "recorder", "meeting"])
        XCTAssertEqual(AskAISourceFilter.voice.sources, ["dictation"])
        XCTAssertEqual(AskAISourceFilter.recorder.sources, ["recorder", "meeting"])
    }

    func testScopeComposerCombinations() {
        XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: true, notesOn: false, filter: .all),
                       ["dictation", "recorder", "meeting"])
        XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: false, notesOn: true, filter: .all),
                       ["obsidian"])
        XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: true, notesOn: true, filter: .voice),
                       ["dictation", "obsidian"])
        XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: false, notesOn: false, filter: .all),
                       [], "UI 防呆之外的最後防線：空集合 = 檢索空")
    }

    /// 🔴 FR-4：category / date facet 是「轉錄的屬性」，筆記塊沒有這些欄位 —— 必須豁免，
    /// 否則使用者一選分類或日期，筆記就整批被誤殺（等同筆記 RAG 失效）。
    @MainActor
    func testCategoryAndDateFiltersExemptObsidianChunks() throws {
        let ctx = try makeInMemoryIndexContext()
        let model = EmbeddingModel.gemini001_768
        let vec = EmbeddingClient.floatsToData([1, 0, 0])
        // 一塊 obsidian（mtime 很舊、無分類）＋一塊 dictation（今天、無 tag 命中）
        ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "《筆記》內容",
            vector: vec, dims: 3, embeddingModel: model.tag, sourceKind: "obsidian",
            categoryId: nil, timestamp: Date(timeIntervalSince1970: 0)))
        ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "逐字稿",
            vector: vec, dims: 3, embeddingModel: model.tag, sourceKind: "dictation",
            categoryId: nil, timestamp: Date()))
        try ctx.save()
        // 近 7 天 + 分類「面試」：obsidian 塊兩個 facet 都豁免 → 唯一存活者
        let scope = AskAIScope(sources: ["dictation", "obsidian"], categoryName: "面試",
                               dateRange: Date().addingTimeInterval(-7 * 86400)...Date())
        let hits = RetrievalService.retrieve(queryVector: [1, 0, 0], scope: scope, k: 10,
                                             model: model, context: ctx)
        XCTAssertEqual(hits.map(\.chunk.sourceKind), ["obsidian"],
                       "obsidian 豁免 category/date；dictation 被 tag 過濾掉")
    }

    // MARK: - Helpers

    /// in-memory SwiftData context（鏡射 ObsidianNoteIndexTests 底部的建法）。
    /// Schema 需含 Transcription —— categoryName 過濾會 fetch 它取 live displayTag。
    private func makeInMemoryIndexContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EmbeddingChunk.self, Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }
}
