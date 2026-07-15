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

/// 查詢改寫純函式(2026-07-15 治本召回):日期絕對化、改寫 user block、JSON 解析、prompt 內容鎖。
/// 全部是 static 純函式,不碰 store / UserDefaults / 網路。
@MainActor
final class AskAIQueryRewriteTests: XCTestCase {

    /// 造固定日期(當地時區、正午避開 DST / 日界邊界)。iso8601Day 與 rewriteUserBlock 皆以
    /// TimeZone.current 格式化,以同一時區、正午建構可穩定對回同一天,勿用即時 Date()。
    private func fixedDate(year: Int, month: Int, day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.hour = 12
        return cal.date(from: comps)!
    }

    // MARK: - rewriteUserBlock

    /// AC-5/AC-6:改寫器看得到「今天日期」與「上一輪對話」,才可能把「今年」絕對化、
    /// 把 follow-up「哪一次最累」接回「爬山」脈絡。
    func testRewriteUserBlockIncludesDateHistoryAndQuestion() {
        let now = fixedDate(year: 2026, month: 7, day: 15)
        let history: [(role: String, text: String)] = [
            (role: "user", text: "今年爬過哪些山"),
            (role: "assistant", text: "玉山、嘉明湖…")
        ]
        let block = AskAIService.rewriteUserBlock(question: "哪一次最累", now: now, history: history)
        XCTAssertTrue(block.contains("2026-07-15"))
        XCTAssertTrue(block.contains("今年爬過哪些山"))
        XCTAssertTrue(block.contains("哪一次最累"))
    }

    /// 空 history → 不輸出「最近對話」段,但日期與問句仍在。
    func testRewriteUserBlockEmptyHistoryOmitsConversationSection() {
        let now = fixedDate(year: 2026, month: 7, day: 15)
        let block = AskAIService.rewriteUserBlock(question: "哪一次最累", now: now, history: [])
        XCTAssertFalse(block.contains("最近對話"))
        XCTAssertTrue(block.contains("2026-07-15"))
        XCTAssertTrue(block.contains("哪一次最累"))
    }

    // MARK: - iso8601Day

    func testISO8601DayFormatsFixedDate() {
        let date = fixedDate(year: 2026, month: 3, day: 16)
        XCTAssertEqual(AskAIService.iso8601Day(date), "2026-03-16")
    }

    // MARK: - parseExpansions

    func testParseExpansionsPlainArray() {
        let out = AskAIService.parseExpansions(#"["2026 爬山","登山"]"#)
        XCTAssertEqual(out, ["2026 爬山", "登山"])
    }

    /// 模型常把 JSON 包在 ```json fence 裡——要剝掉 fence 再解析。
    func testParseExpansionsStripsJSONFence() {
        let raw = "```json\n[\"2026 爬山\",\"登山\"]\n```"
        XCTAssertEqual(AskAIService.parseExpansions(raw), ["2026 爬山", "登山"])
    }

    /// 壞 JSON → [](沿用 repo try? 容錯慣例,退回原始檢索而非崩)。
    func testParseExpansionsBadJSONReturnsEmpty() {
        XCTAssertEqual(AskAIService.parseExpansions("not json at all"), [])
    }

    /// 上限 4:超過只取前 4,避免擴展查詢無限膨脹嵌入成本。
    func testParseExpansionsCapsAtFour() {
        let out = AskAIService.parseExpansions(#"["a","b","c","d","e","f"]"#)
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out, ["a", "b", "c", "d"])
    }

    /// 空白 / 空字串項剔除。
    func testParseExpansionsDropsBlankItems() {
        let out = AskAIService.parseExpansions(#"["登山","  ","","健行"]"#)
        XCTAssertEqual(out, ["登山", "健行"])
    }

    // MARK: - queryRewriteSystemPrompt 內容鎖

    func testQueryRewriteSystemPromptContainsBranchingMarkerAndIntent() {
        // 「檢索查詢改寫器」:BranchingCompleter 靠這字串分流,拿掉會讓改寫請求誤走一般回答分支。
        XCTAssertTrue(AskAIService.queryRewriteSystemPrompt.contains("檢索查詢改寫器"))
        // 相對時間絕對化是改寫器核心意圖(今年 → 2026),不可從 prompt 移除。
        XCTAssertTrue(AskAIService.queryRewriteSystemPrompt.contains("相對時間絕對化"))
    }
}
