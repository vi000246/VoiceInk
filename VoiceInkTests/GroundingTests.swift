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
        let out = await g.gather(cueText: "設計短網址", brief: "訂單分庫 review",
                                 includeRAG: true, includeScreen: false)
        XCTAssertTrue(out.ragExcerpts.isEmpty, "embed 失敗 → 無 RAG，但不 throw")
        XCTAssertEqual(out.brief, "訂單分庫 review", "brief 一定保留")
    }

    /// AC-9:embed 成功但索引為空 → retrieve 回 []，靜默、答案照出。
    func testRagEmptyWhenIndexEmpty() async throws {
        let ctx = try makeContext()
        let g = MeetingGroundingProvider(embedder: StubEmbedder(), screen: FakeScreen(), modelContext: ctx)
        let out = await g.gather(cueText: "x", brief: "", includeRAG: true, includeScreen: false)
        XCTAssertTrue(out.ragExcerpts.isEmpty)
    }

    /// AC-10:螢幕只在 Tier 2（includeScreen=true）擷取一次；Tier 0/1（false）不呼叫。
    func testScreenContextOnlyWhenIncluded() async throws {
        let ctx = try makeContext()
        let screen = FakeScreen()
        screen.stubText = "架構圖: API Gateway → Service → DB"
        let g = MeetingGroundingProvider(embedder: StubEmbedder(), screen: screen, modelContext: ctx)

        _ = await g.gather(cueText: "x", brief: "", includeRAG: false, includeScreen: false)
        XCTAssertEqual(screen.callCount, 0, "Tier 0/1 不得擷取螢幕")

        let out = await g.gather(cueText: "x", brief: "", includeRAG: false, includeScreen: true)
        XCTAssertEqual(screen.callCount, 1, "Tier 2 擷取一次")
        XCTAssertEqual(out.screenText, "架構圖: API Gateway → Service → DB")
    }

    /// 螢幕 OCR 回 nil（權限未授予等）→ screenText 為 nil，不崩。
    func testScreenNilDegradesSilently() async throws {
        let ctx = try makeContext()
        let screen = FakeScreen()   // stubText = nil
        let g = MeetingGroundingProvider(embedder: StubEmbedder(), screen: screen, modelContext: ctx)
        let out = await g.gather(cueText: "x", brief: "", includeRAG: false, includeScreen: true)
        XCTAssertNil(out.screenText)
    }
}
