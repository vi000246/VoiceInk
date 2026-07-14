import XCTest
import SwiftData
@testable import VoiceInk

/// 回固定向量並計數呼叫的假嵌入器：`embedCallCount` 供「增量只重嵌變更檔」斷言。
/// 用 class（非 struct）讓測試能跨呼叫觀察/重設計數。
private final class FakeCountingEmbedder: EmbeddingProviding {
    var embedCallCount = 0
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        embedCallCount += 1
        return texts.map { _ in [0.25, 0.5, 0.75] }
    }
}

final class ObsidianNoteIndexTests: XCTestCase {

    func testStripFrontmatterRemovesYAMLBlock() {
        let md = "---\ntags: [a]\ndate: 2026-01-01\n---\n\n# 標題\n內文段落"
        XCTAssertEqual(ObsidianNoteChunking.stripFrontmatter(md), "# 標題\n內文段落")
        // 沒有 frontmatter 時原樣返回
        XCTAssertEqual(ObsidianNoteChunking.stripFrontmatter("純內容"), "純內容")
        // 只有開頭 --- 沒有收尾 → 不誤刪
        XCTAssertEqual(ObsidianNoteChunking.stripFrontmatter("---\n沒收尾"), "---\n沒收尾")
    }

    func testChunksCarryTitlePrefix() {
        let drafts = ObsidianNoteChunking.chunks(title: "專案A", body: "第一段\n\n第二段")
        XCTAssertFalse(drafts.isEmpty)
        XCTAssertTrue(drafts.allSatisfy { $0.text.hasPrefix("《專案A》") })
    }

    func testDeterministicIdStableAndDistinct() {
        let a1 = ObsidianNoteChunking.noteId(relativePath: "工作/專案A.md")
        let a2 = ObsidianNoteChunking.noteId(relativePath: "工作/專案A.md")
        let b  = ObsidianNoteChunking.noteId(relativePath: "工作/專案B.md")
        XCTAssertEqual(a1, a2, "同路徑恆定")
        XCTAssertNotEqual(a1, b)
    }

    // MARK: - 索引服務（全量 → 增量）

    @MainActor
    func testFullIndexThenIncrementalOnlyReembedsChangedFile() async throws {
        let (ctx, embedder) = try makeInMemoryContextAndFakeEmbedder()
        let vault = try makeTempVault(files: [
            "工作/專案A.md": "---\ntags: [x]\n---\n# A\n內容甲",
            "日記/2026.md": "今天內容"])
        let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: ctx,
                                           stateURL: vault.appendingPathComponent(".state.json"))
        // 全量
        let n1 = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [".obsidian"])
        XCTAssertGreaterThan(n1, 0)
        let all = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
        XCTAssertTrue(all.allSatisfy { $0.sourceKind == "obsidian" })
        XCTAssertTrue(all.contains { $0.text.hasPrefix("《專案A》") && !$0.text.contains("tags:") })
        // 增量：只改一檔＋刪一檔
        embedder.embedCallCount = 0
        try "改過的內容".write(to: vault.appendingPathComponent("工作/專案A.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: vault.appendingPathComponent("日記/2026.md"))
        _ = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [".obsidian"])
        XCTAssertEqual(embedder.embedCallCount, 1, "只有變更檔重嵌")
        let after = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
        XCTAssertFalse(after.contains { $0.text.hasPrefix("《2026》") }, "刪除檔的塊要消失")
    }

    /// 🔴 回歸鎖（2026-07-14 修 FR-44 後半）：**換 embedding 模型後，筆記必須全量重嵌。**
    ///
    /// `TranscriptIndexService.switchModel` 會刪光**所有** `EmbeddingChunk`（含筆記塊），
    /// 但 vault 的檔案內容一個字都沒改。若 sidecar 只記「路徑 → 內容 hash」，下次掃描會
    /// 全部命中、全部跳過 → **筆記塊永遠回不來**，而且設定頁的「重建筆記索引」會回報
    /// 「0 檔」，看起來一切正常。使用者只會發現 aboutMe 突然開始說「筆記沒記」。
    /// 失效是靜默的，所以這條測試存在。
    @MainActor
    func testEmbeddingModelSwitchForcesFullReembed() async throws {
        let (ctx, embedder) = try makeInMemoryContextAndFakeEmbedder()
        let vault = try makeTempVault(files: [
            "工作/專案A.md": "內容甲",
            "日記/2026.md": "內容乙"])
        let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: ctx,
                                           stateURL: vault.appendingPathComponent(".state.json"))

        // 全域單例：測完還原，不污染其他測試。
        let original = TranscriptIndexService.shared.model
        addTeardownBlock { @MainActor in TranscriptIndexService.shared.model = original }

        TranscriptIndexService.shared.model = .gemini001_768
        let firstPass = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        XCTAssertEqual(firstPass, 2)

        // 同模型再掃：檔案沒變 → 零重嵌（增量本來就該這樣，不可回歸）。
        embedder.embedCallCount = 0
        let sameModelPass = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        XCTAssertEqual(sameModelPass, 0)
        XCTAssertEqual(embedder.embedCallCount, 0, "檔案沒變就不該重嵌")

        // 換模型 = 換向量空間。這裡重現 `switchModel` 的效果：索引被清空。
        for chunk in try ctx.fetch(FetchDescriptor<EmbeddingChunk>()) { ctx.delete(chunk) }
        try ctx.save()
        TranscriptIndexService.shared.model = .openaiSmall1536

        // 檔案內容一個字沒改，但**必須**全部重嵌 —— 否則筆記 RAG 從此靜默失效。
        embedder.embedCallCount = 0
        let afterSwitch = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        XCTAssertEqual(afterSwitch, 2, "換 embedding 模型後兩個檔都要重嵌")
        XCTAssertEqual(embedder.embedCallCount, 2)

        let rebuilt = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
        XCTAssertFalse(rebuilt.isEmpty, "筆記塊必須回來")
        XCTAssertTrue(rebuilt.allSatisfy { $0.embeddingModel == EmbeddingModel.openaiSmall1536.tag },
                      "重嵌後的塊必須標新的向量空間")
    }

    /// 🔴 AC-7：舊 sidecar（無 schema）→ 全量重嵌＋metadata 回填＋幽靈塊清理＋sidecar 寫回 schema:2。
    @MainActor
    func testSchemaBumpForcesFullReembedBackfillsMetadataAndClearsGhosts() async throws {
        let (ctx, embedder) = try makeInMemoryContextAndFakeEmbedder()
        let vault = try makeTempVault(files: ["工作/專案A.md": "內容甲"])
        let stateURL = vault.appendingPathComponent(".state.json")
        let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: ctx, stateURL: stateURL)
        // 幽靈：state 裡有、磁碟上沒有的檔的塊（同 model tag —— discardStale 不會清它）
        let ghostId = ObsidianNoteChunking.noteId(relativePath: "已刪/舊筆記.md")
        ctx.insert(EmbeddingChunk(transcriptionId: ghostId, chunkIndex: 0, text: "《舊筆記》幽靈",
            vector: EmbeddingClient.floatsToData([0.1, 0.2, 0.3]), dims: 3,
            embeddingModel: TranscriptIndexService.shared.model.tag, sourceKind: "obsidian",
            categoryId: nil, timestamp: Date()))
        try ctx.save()
        // 舊版 sidecar：無 schema 欄位（M8 出貨格式）
        let legacy = #"{"embeddingModel":"\#(TranscriptIndexService.shared.model.tag)","files":{"工作/專案A.md":"deadbeef","已刪/舊筆記.md":"cafebabe"}}"#
        try legacy.write(to: stateURL, atomically: true, encoding: .utf8)

        let n = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        XCTAssertEqual(n, 1, "schema 不符 → 視為空 → 全量重嵌")
        let chunks = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
        XCTAssertFalse(chunks.contains { $0.text.contains("幽靈") }, "全量起點清掉幽靈塊")
        XCTAssertTrue(chunks.allSatisfy { $0.sourceTitle == "專案A" && $0.sourcePath == "工作/專案A.md" })
        let written = try String(contentsOf: stateURL, encoding: .utf8)
        XCTAssertTrue(written.contains(#""schema":2"#))
    }

    // MARK: - Helpers

    /// in-memory SwiftData context（鏡射 AskAIIndexTests 的建法；索引測試只需 EmbeddingChunk schema）
    /// ＋ 計數 fake embedder。
    private func makeInMemoryContextAndFakeEmbedder() throws -> (ModelContext, FakeCountingEmbedder) {
        let container = try ModelContainer(
            for: EmbeddingChunk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (ModelContext(container), FakeCountingEmbedder())
    }

    /// 臨時 vault：temp 目錄下依 [相對路徑: 內容] 建 .md 檔；teardown 自動清理。
    private func makeTempVault(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, content) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
