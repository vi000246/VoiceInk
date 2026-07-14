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
