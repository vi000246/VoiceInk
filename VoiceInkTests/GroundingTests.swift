import XCTest
import SwiftData
@testable import VoiceInk

// MARK: - Fakes

/// embed 一律 throw（模擬無 embedding key）。
private struct ThrowingEmbedder: EmbeddingProviding {
    struct NoKey: Error {}
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] { throw NoKey() }
}

/// embed 回一個固定向量（但 in-memory index 是空的 → retrieve 回 []）。
private struct StubEmbedder: EmbeddingProviding {
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        [[Float](repeating: 0.1, count: 8)]
    }
}

/// 逐字對應向量（測同義詞多查詢:每個 term 各自嵌成不同向量）。未映射 → 零向量。
private struct MapEmbedder: EmbeddingProviding {
    let map: [String: [Float]]
    let dims: Int
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        texts.map { EmbeddingClient.normalize(map[$0] ?? [Float](repeating: 0, count: dims)) }
    }
}

/// 記錄呼叫次數的螢幕 fake。
private final class FakeScreen: MeetingScreenCapturing {
    private(set) var callCount = 0
    var stubText: String?
    func captureAndExtractText() async -> String? { callCount += 1; return stubText }
}

@MainActor
final class GroundingTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EmbeddingChunk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// AC-9:embed 失敗 → ragExcerpts 空、不 throw、不 persist、答案照出。
    func testRagSkippedSilentlyWhenEmbedderThrows() async throws {
        let ctx = try makeContext()
        let screen = FakeScreen()
        let g = MeetingGroundingProvider(embedder: ThrowingEmbedder(), screen: screen, modelContext: ctx)
        let out = await g.gather(query: "設計短網址", brief: "訂單分庫 review",
                                 includeRAG: true, includeScreen: false, sources: nil)
        XCTAssertTrue(out.ragExcerpts.isEmpty, "embed 失敗 → 無 RAG，但不 throw")
        XCTAssertEqual(out.brief, "訂單分庫 review", "brief 一定保留")
    }

    /// AC-9:embed 成功但索引為空 → retrieve 回 []，靜默、答案照出。
    func testRagEmptyWhenIndexEmpty() async throws {
        let ctx = try makeContext()
        let g = MeetingGroundingProvider(embedder: StubEmbedder(), screen: FakeScreen(), modelContext: ctx)
        let out = await g.gather(query: "x", brief: "", includeRAG: true, includeScreen: false, sources: nil)
        XCTAssertTrue(out.ragExcerpts.isEmpty)
    }

    // MARK: - 同義詞多查詢召回(2026-07-15:會議 copilot 也放寬同義詞檢索)

    /// aboutMe 的 searchHint 由分類器以 `|` 分隔多個同義詞 → gather 拆開後各自檢索取聯集,
    /// 讓「字面沒對上但講同一件事」的筆記也被撈到(零額外 LLM 呼叫、零開口延遲)。
    func testGatherSynonymMultiQueryUnionSurfacesBothNotes() async throws {
        let ctx = try makeContext()
        let tag = TranscriptIndexService.shared.model.tag
        func seed(_ text: String, _ vec: [Float]) {
            ctx.insert(EmbeddingChunk(
                transcriptionId: UUID(), chunkIndex: 0, text: text,
                vector: EmbeddingClient.floatsToData(EmbeddingClient.normalize(vec)), dims: 2,
                embeddingModel: tag, sourceKind: "obsidian", categoryId: nil, timestamp: Date()))
        }
        seed("衝突筆記", [1, 0])
        seed("earn trust 筆記", [0, 1])
        try ctx.save()

        let embedder = MapEmbedder(map: ["衝突": [1, 0], "earn trust": [0, 1]], dims: 2)
        let g = MeetingGroundingProvider(embedder: embedder, screen: FakeScreen(), modelContext: ctx)

        // 單一同義詞 + 相似度下限 → 只撈到字面對上的那則。
        let single = await g.gather(query: "衝突", brief: "", includeRAG: true, includeScreen: false,
                                    sources: ["obsidian"], minScore: 0.5)
        XCTAssertEqual(single.ragExcerpts, ["衝突筆記"], "單查詢 + 下限 → 只撈字面對上的")

        // 多同義詞(| 分隔)聯集 → 兩則都撈到,字面沒對上的 earn trust 筆記也進來。
        let union = await g.gather(query: "衝突|earn trust", brief: "", includeRAG: true, includeScreen: false,
                                   sources: ["obsidian"], minScore: 0.5)
        XCTAssertEqual(Set(union.ragExcerpts), ["衝突筆記", "earn trust 筆記"],
                       "同義詞多查詢聯集應把字面沒對上的筆記也撈進來")
    }

    func testQueryTermsSplitsOnPipe() {
        XCTAssertEqual(MeetingGroundingProvider.queryTerms("團隊衝突|earn trust|協作"),
                       ["團隊衝突", "earn trust", "協作"])
        XCTAssertEqual(MeetingGroundingProvider.queryTerms("設計短網址服務"), ["設計短網址服務"],
                       "無 | → 單一查詢(技術 cue 整句)")
        XCTAssertEqual(MeetingGroundingProvider.queryTerms(" a | a |  | b "), ["a", "b"], "去空白、去重、去空項")
        XCTAssertEqual(MeetingGroundingProvider.queryTerms("a|b|c|d|e").count, 4, "上限 4")
        XCTAssertEqual(MeetingGroundingProvider.queryTerms("   "), [], "全空白 → 空")
    }

    /// M8 FR-47/AC-32:sources 白名單必須傳進檢索 scope——只回指定 sourceKind 的塊;
    /// nil = 不限來源（向下相容原本的 `.all` 行為）。
    func testGatherFiltersBySources() async throws {
        let ctx = try makeContext()
        // 兩塊向量相同、sourceKind 不同;embeddingModel 用 gather 實際讀的 shared model tag,
        // 否則 retrieve 的「同向量空間」前置過濾會把種子塊全濾掉。
        let tag = TranscriptIndexService.shared.model.tag
        func seed(_ kind: String, _ text: String) {
            ctx.insert(EmbeddingChunk(
                transcriptionId: UUID(), chunkIndex: 0, text: text,
                vector: EmbeddingClient.floatsToData([Float](repeating: 0.1, count: 8)),
                dims: 8, embeddingModel: tag, sourceKind: kind,
                categoryId: nil, timestamp: Date()))
        }
        seed("obsidian", "筆記塊")
        seed("dictation", "逐字稿塊")
        try ctx.save()

        let g = MeetingGroundingProvider(embedder: StubEmbedder(), screen: FakeScreen(), modelContext: ctx)
        let notes = await g.gather(query: "x", brief: "", includeRAG: true, includeScreen: false,
                                   sources: ["obsidian"])
        XCTAssertEqual(notes.ragExcerpts, ["筆記塊"], "sources 過濾必須生效")

        let all = await g.gather(query: "x", brief: "", includeRAG: true, includeScreen: false,
                                 sources: nil)
        XCTAssertEqual(Set(all.ragExcerpts), ["筆記塊", "逐字稿塊"], "nil = 不限來源")
    }

    /// AC-10:螢幕只在 Tier 2（includeScreen=true）擷取一次；Tier 0/1（false）不呼叫。
    func testScreenContextOnlyWhenIncluded() async throws {
        let ctx = try makeContext()
        let screen = FakeScreen()
        screen.stubText = "架構圖: API Gateway → Service → DB"
        let g = MeetingGroundingProvider(embedder: StubEmbedder(), screen: screen, modelContext: ctx)

        _ = await g.gather(query: "x", brief: "", includeRAG: false, includeScreen: false, sources: nil)
        XCTAssertEqual(screen.callCount, 0, "Tier 0/1 不得擷取螢幕")

        let out = await g.gather(query: "x", brief: "", includeRAG: false, includeScreen: true, sources: nil)
        XCTAssertEqual(screen.callCount, 1, "Tier 2 擷取一次")
        XCTAssertEqual(out.screenText, "架構圖: API Gateway → Service → DB")
    }

    /// 螢幕 OCR 回 nil（權限未授予等）→ screenText 為 nil，不崩。
    func testScreenNilDegradesSilently() async throws {
        let ctx = try makeContext()
        let screen = FakeScreen()   // stubText = nil
        let g = MeetingGroundingProvider(embedder: StubEmbedder(), screen: screen, modelContext: ctx)
        let out = await g.gather(query: "x", brief: "", includeRAG: false, includeScreen: true, sources: nil)
        XCTAssertNil(out.screenText)
    }
}
