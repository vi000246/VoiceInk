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

/// 查詢擴展測試用:改寫器 prompt → 回擴展 JSON;其餘(答案生成)→ 回帶引用的答案。
/// 同一個 completer 在 `ask()` 內被呼叫兩次(先擴展、後答案),靠 system prompt 分流。
private struct BranchingCompleter: ChatCompleting {
    let expansionReply: String
    let answerReply: String
    func complete(system: String, user: String) async throws -> String {
        system.contains("檢索查詢改寫器") ? expansionReply : answerReply
    }
}

/// 同 BranchingCompleter 分流(改寫 vs 答案),另**記錄答案呼叫收到的 user block**——
/// 驗證對話歷史是否被注入回答 prompt。改寫分支不觸發記錄。
private struct RecordingBranchingCompleter: ChatCompleting {
    let expansionReply: String
    let answerReply: String
    let onAnswerUser: (@Sendable (String) -> Void)?
    func complete(system: String, user: String) async throws -> String {
        if system.contains("檢索查詢改寫器") { return expansionReply }
        onAnswerUser?(user)
        return answerReply
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

    private func insertChunk(_ ctx: ModelContext, tid: UUID, text: String, vector: [Float],
                             chunkIndex: Int = 0) {
        ctx.insert(EmbeddingChunk(
            transcriptionId: tid, chunkIndex: chunkIndex, text: text,
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
        // 空索引 → 診斷訊息提示「索引是空的／重建索引」（不再是一律「找不到」）。
        XCTAssertTrue(message.text.contains("索引"))
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

    // MARK: - 查詢擴展(2026-07-15:問「山」撈不到「百岳」筆記)

    /// 治本召回:原始查詢排在前 12 之外的段,靠同義擴展查詢擠進答案上下文並被引用。
    /// 12 個 decoy 段高度匹配原始查詢([1,0.1]),把 base 前 12 佔滿;爬山段([0,1])與原始查詢
    /// 正交(排第 13、base 撈不到),只有「百岳」擴展查詢([0,1])撈得到 → union 後以最高分擠進前 12。
    func testQueryExpansionSurfacesChunkOriginalQueryMissed() async throws {
        let ctx = try makeContext()
        for i in 0..<12 {
            insertChunk(ctx, tid: UUID(), text: "無關內容\(i)", vector: [1, 0.1], chunkIndex: i)
        }
        let hikingTid = UUID()
        insertChunk(ctx, tid: hikingTid, text: "今年爬了玉山跟合歡", vector: [0, 1])
        try ctx.save()

        let embedder = FakeEmbedder(map: ["爬過哪些山": [1, 0], "百岳": [0, 1]], dims: 2)
        let completer = BranchingCompleter(expansionReply: #"["百岳"]"#,
                                           answerReply: "今年爬了玉山跟合歡 [1]。")
        AskAIService.shared.configureForTesting(embedder: embedder, completer: completer)

        let message = try await AskAIService.shared.ask(
            question: "爬過哪些山", scope: .all, thread: nil, model: .gemini001_768, context: ctx)

        XCTAssertTrue(message.citations.contains { $0.transcriptionId == hikingTid },
                      "查詢擴展應讓原始查詢漏掉的爬山段進入答案上下文並可被引用")
    }

    /// 擴展失敗(改寫器回無法解析的東西)→ 退回原始檢索,絕不比現況差。
    func testQueryExpansionFallsBackGracefullyOnGarbage() async throws {
        let ctx = try makeContext()
        let tid = UUID()
        insertChunk(ctx, tid: tid, text: "承諾下週三交付。", vector: [1, 0])
        try ctx.save()

        let embedder = FakeEmbedder(map: ["誰承諾了什麼": [1, 0]], dims: 2)
        // 改寫器回非 JSON → parseExpansions 回 [] → 只用原始檢索;答案照常。
        let completer = BranchingCompleter(expansionReply: "這不是 JSON",
                                           answerReply: "有人承諾下週三交付 [1]。")
        AskAIService.shared.configureForTesting(embedder: embedder, completer: completer)

        let message = try await AskAIService.shared.ask(
            question: "誰承諾了什麼", scope: .all, thread: nil, model: .gemini001_768, context: ctx)
        XCTAssertEqual(message.citations.count, 1)
        XCTAssertEqual(message.citations[0].transcriptionId, tid)
    }

    // MARK: - 純函式:擴展解析 + 放寬拒答規則

    func testParseExpansionsTolerant() {
        XCTAssertEqual(AskAIService.parseExpansions(#"["百岳","登山"]"#), ["百岳", "登山"])
        XCTAssertEqual(AskAIService.parseExpansions("不是 JSON"), [], "壞格式 → 空,退回原始檢索")
        XCTAssertEqual(AskAIService.parseExpansions(#"["a","","  "]"#), ["a"], "空白項剔除")
        let fenced = "```json\n[\"x\",\"y\"]\n```"
        XCTAssertEqual(AskAIService.parseExpansions(fenced), ["x", "y"], "code fence 要剝掉")
        XCTAssertEqual(AskAIService.parseExpansions(#"["1","2","3","4","5"]"#).count, 4, "至多 4 個（改寫上限 3→4）")
    }

    /// 放寬拒答只放寬「字面沒對上」,反幻覺底線不動——且這是 Ask AI 專用文案。
    func testCitationRulesSoftenedButKeepsAntiHallucination() {
        let rules = AskAIService.citationRules
        XCTAssertTrue(rules.contains("語意相關就據以回答"), "放寬過度拒答:語意相關即答")
        XCTAssertTrue(rules.contains("百岳"), "帶上使用者回報的具體例子")
        XCTAssertTrue(rules.contains("不要編造"), "反幻覺底線保留")
        XCTAssertTrue(rules.contains("找不到相關內容"), "真無關仍要明說找不到")
    }

    // MARK: - 回答注入對話歷史(AC-7:follow-up 的回答 prompt 看得到上文)

    /// 純函式:帶歷史 → 回答 prompt 含上一輪問句並標示「先前對話」;
    /// 空歷史 → **不**加「先前對話」字樣(回歸:與現況逐字相容)。
    func testBuildUserBlockIncludesHistoryButOmitsWhenEmpty() {
        let withHistory = AskAIService.buildUserBlock(
            question: "哪一次最累", chunks: [],
            history: [(role: "user", text: "今年爬過哪些山"), (role: "assistant", text: "玉山")])
        XCTAssertTrue(withHistory.contains("今年爬過哪些山"), "回答 prompt 應帶入上一輪問句")
        XCTAssertTrue(withHistory.contains("先前對話"), "非空歷史應標示先前對話段")

        let noHistory = AskAIService.buildUserBlock(question: "哪一次最累", chunks: [])
        XCTAssertFalse(noHistory.contains("先前對話"), "空歷史不得加先前對話段(與現況逐字相容)")
    }

    /// 端到端:同一 thread 第二輪提問時,第一輪的問句要被注入回答 user block。
    /// completer 分流——改寫器回 `[]`(不擴展、退回 base),答案分支記錄收到的 user block。
    func testAskInjectsPriorThreadHistoryIntoAnswerPrompt() async throws {
        let ctx = try makeContext()
        let tid = UUID()
        insertChunk(ctx, tid: tid, text: "最累的是嘉明湖那次。", vector: [1, 0])

        // 模擬第一輪:thread 內先塞 user/assistant 訊息(createdAt 保證 user 早於 assistant)。
        let thread = AskAIThread(title: "山")
        ctx.insert(thread)
        ctx.insert(AskAIMessage(thread: thread, role: "user", text: "今年爬過哪些山",
                                createdAt: Date(timeIntervalSince1970: 1)))
        ctx.insert(AskAIMessage(thread: thread, role: "assistant", text: "玉山、合歡、嘉明湖。",
                                createdAt: Date(timeIntervalSince1970: 2)))
        try ctx.save()

        var capturedAnswerUser = ""
        let embedder = FakeEmbedder(map: ["哪一次最累": [1, 0]], dims: 2)
        let completer = RecordingBranchingCompleter(
            expansionReply: "[]", answerReply: "最累的是嘉明湖那次 [1]。",
            onAnswerUser: { capturedAnswerUser = $0 })
        AskAIService.shared.configureForTesting(embedder: embedder, completer: completer)

        _ = try await AskAIService.shared.ask(
            question: "哪一次最累", scope: .all, thread: thread, model: .gemini001_768, context: ctx)

        XCTAssertTrue(capturedAnswerUser.contains("先前對話"), "第二輪回答 prompt 應含先前對話段")
        XCTAssertTrue(capturedAnswerUser.contains("今年爬過哪些山"), "第二輪回答應看得到第一輪問句")
    }

    /// 第一輪(thread=nil):當前問句不得混進歷史 → 回答 user block 無「先前對話」,
    /// 但當前問句仍出現在問題行。守住 priorMessages「插入前擷取」的擷取順序。
    func testFirstRoundHasNoPriorHistoryInAnswerPrompt() async throws {
        let ctx = try makeContext()
        insertChunk(ctx, tid: UUID(), text: "承諾下週三交付。", vector: [1, 0])
        try ctx.save()

        var capturedAnswerUser = ""
        let embedder = FakeEmbedder(map: ["誰承諾了什麼": [1, 0]], dims: 2)
        let completer = RecordingBranchingCompleter(
            expansionReply: "[]", answerReply: "有人承諾下週三交付 [1]。",
            onAnswerUser: { capturedAnswerUser = $0 })
        AskAIService.shared.configureForTesting(embedder: embedder, completer: completer)

        _ = try await AskAIService.shared.ask(
            question: "誰承諾了什麼", scope: .all, thread: nil, model: .gemini001_768, context: ctx)

        XCTAssertFalse(capturedAnswerUser.contains("先前對話"), "第一輪無歷史;當前問句不得混進上文")
        XCTAssertTrue(capturedAnswerUser.contains("誰承諾了什麼"), "當前問句仍在問題行")
    }
}
