import XCTest
import SwiftData
@testable import VoiceInk

/// 覆蓋率比對（`NoteIndexCoverage.compute`）＋ 索引進度／取消（`reindex`）的回歸鎖。
///
/// 這一整組存在的理由是同一件事:**筆記索引的失效全是靜默的**。新檔沒掃到、改過的檔沒重嵌、
/// 刪掉的檔留著幽靈塊——三種都不會報錯,只會讓 AI 少知道（或多知道）一些東西。覆蓋率表是
/// 使用者唯一看得見這些失效的地方,所以它的判斷邏輯必須被釘死。
final class NoteIndexCoverageTests: XCTestCase {

    private func note(_ path: String, hash: String, hasContent: Bool = true) -> ScannedNote {
        ScannedNote(relativePath: path, contentHash: hash,
                    modifiedAt: Date(timeIntervalSince1970: 0), hasIndexableContent: hasContent)
    }

    // MARK: - 四種狀態的判定

    /// 有塊 ＋ hash 相符 = 已索引（唯一「一切正常」的狀態）。
    func testIndexedWhenChunksExistAndHashMatches() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("工作/A.md", hash: "h1")],
            sidecar: ["工作/A.md": "h1"],
            chunkCounts: ["工作/A.md": 3],
            legacyChunkCount: 0)
        XCTAssertEqual(coverage.entries.first?.status, .indexed)
        XCTAssertEqual(coverage.entries.first?.chunkCount, 3)
        XCTAssertFalse(coverage.needsReindex)
        XCTAssertEqual(coverage.indexedFileCount, 1)
        XCTAssertEqual(coverage.totalChunkCount, 3)
    }

    /// 🔴 使用者問題的核心:**「我剛加的檔有沒有被 RAG 納進去？」**
    /// 新檔＝沒塊、sidecar 也沒記錄 → 必須是 `pending`,而且 `needsReindex` 要亮起來。
    /// 判錯成 `indexed` 的話,使用者會以為問得到、實際上永遠檢索不到——最糟的靜默失效。
    func testNewFileIsPendingAndFlagsReindex() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("工作/A.md", hash: "h1"), note("新增/剛寫的.md", hash: "new")],
            sidecar: ["工作/A.md": "h1"],
            chunkCounts: ["工作/A.md": 2],
            legacyChunkCount: 0)
        XCTAssertEqual(coverage.count(.pending), 1)
        XCTAssertTrue(coverage.needsReindex)
        // 待處理的排最前面——打開這張表就是為了找漏掉的檔。
        XCTAssertEqual(coverage.entries.first?.relativePath, "新增/剛寫的.md")
        XCTAssertEqual(coverage.entries.first?.status, .pending)
        XCTAssertEqual(coverage.entries.first?.chunkCount, 0)
    }

    /// 有塊、但檔案改過（hash 不符）= 塊是舊內容 → `stale`,不是 `indexed`。
    /// 判成 `indexed` 的話,使用者會以為 AI 讀的是最新版,其實讀的是上週的。
    func testModifiedFileIsStale() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("工作/A.md", hash: "NEW-hash")],
            sidecar: ["工作/A.md": "OLD-hash"],
            chunkCounts: ["工作/A.md": 2],
            legacyChunkCount: 0)
        XCTAssertEqual(coverage.entries.first?.status, .stale)
        XCTAssertTrue(coverage.needsReindex)
    }

    /// 沒塊、而且檔案切不出東西（空檔／只剩 frontmatter）= 本來就不該有塊 → 不是漏索引，
    /// 不該催使用者去重建（否則每次重建都還是 0 塊,他會以為壞掉了）。
    func testEmptyFileIsNotReportedAsMissing() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("空檔.md", hash: "h-empty", hasContent: false)],
            sidecar: ["空檔.md": "h-empty"],
            chunkCounts: [:],
            legacyChunkCount: 0)
        XCTAssertEqual(coverage.entries.first?.status, .empty)
        XCTAssertFalse(coverage.needsReindex, "空檔不該被當成待索引")
    }

    /// 🔴 回歸鎖（2026-07-14 對抗式審查揪出）：**塊不見了、但 sidecar 還記著 hash** →
    /// 必須報 `pending`，**不准**因為「hash 命中」就報成無害的「無內容」。
    ///
    /// 這個狀態真的到得了：強制全量重嵌會先清光所有筆記塊，若接著中途失敗（斷網／金鑰過期），
    /// sidecar 仍是舊的那份有效 hash 表。此時每個檔都是「hash 命中、零塊」。若照 hash 判成
    /// `.empty`，覆蓋率表會給出一整排「無內容」＋一句綠色的「範圍內的筆記都已進索引」——
    /// 而事實是**整個筆記索引空了、Ask AI 一則筆記都查不到**。這張表存在的唯一理由就是抓這種
    /// 靜默失效，它自己絕不能是第一個說謊的人。所以「有內容卻零塊」一律 pending，不看 hash。
    func testChunksGoneButSidecarIntactIsPendingNotEmpty() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("工作/A.md", hash: "h1", hasContent: true),
                      note("工作/B.md", hash: "h2", hasContent: true)],
            sidecar: ["工作/A.md": "h1", "工作/B.md": "h2"],   // hash 全命中
            chunkCounts: [:],                                  // 但塊全沒了
            legacyChunkCount: 0)
        XCTAssertEqual(coverage.count(.pending), 2, "有內容卻零塊 = 檢索撈不到 = 待索引")
        XCTAssertEqual(coverage.count(.empty), 0, "絕不可謊報成「無內容」")
        XCTAssertTrue(coverage.needsReindex, "必須催使用者重建")
    }

    /// 索引裡有塊、vault 掃不到 = 幽靈（刪了／改名／被 exclude 排除）。
    /// **檢索還撈得到它們** → AI 會拿早就刪掉的筆記回答。必須顯示出來。
    func testDeletedFileSurfacesAsGhost() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("工作/A.md", hash: "h1")],
            sidecar: ["工作/A.md": "h1"],
            chunkCounts: ["工作/A.md": 1, "已刪/舊筆記.md": 4],
            legacyChunkCount: 0)
        let ghost = coverage.entries.first { $0.status == .ghost }
        XCTAssertEqual(ghost?.relativePath, "已刪/舊筆記.md")
        XCTAssertEqual(ghost?.chunkCount, 4)
        XCTAssertNil(ghost?.modifiedAt, "幽靈沒有對應檔案")
    }

    /// 🔴 換 embedding 模型後：`loadSidecar` 會回空（向量空間不相容）＋ 塊被 switchModel 清光。
    /// 覆蓋率必須誠實顯示「全部尚未索引」,而不是沿用舊 hash 謊報「都好了」。
    func testUntrustedSidecarShowsEverythingAsPending() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("A.md", hash: "h1"), note("B.md", hash: "h2")],
            sidecar: [:],          // loadSidecar 在 schema／model tag 不符時就是回這個
            chunkCounts: [:],      // switchModel 已把塊刪光
            legacyChunkCount: 0)
        XCTAssertEqual(coverage.count(.pending), 2)
        XCTAssertTrue(coverage.needsReindex)
    }

    /// M8 舊格式的塊（沒有 sourcePath）認不出屬於哪個檔 → 單獨計數，供 UI 提示「該強制全量重嵌」。
    func testLegacyChunksAreCountedSeparately() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("A.md", hash: "h1")],
            sidecar: ["A.md": "h1"],
            chunkCounts: ["A.md": 1],
            legacyChunkCount: 7)
        XCTAssertEqual(coverage.legacyChunkCount, 7)
        XCTAssertEqual(coverage.entries.count, 1, "舊格式塊不該冒充成一列檔案")
    }

    // MARK: - 掃描 ＋ 進度 ＋ 取消（走真的 reindex）

    /// `scanNotesWithHashes` 要套用與索引**同一套** include/exclude 規則——
    /// 兩邊規則若不一致，覆蓋率表會把「本來就不該索引的檔」列成「漏索引」，然後不管按幾次重建
    /// 都不會消失（使用者只會覺得這功能壞了）。
    func testScanAppliesSameFolderRulesAsIndexer() throws {
        let vault = try makeTempVault(files: [
            "工作/A.md": "甲",
            "私人/B.md": "乙",
            "根目錄散檔.md": "丙"])
        let onlyWork = ObsidianNoteIndexService.scanNotesWithHashes(
            vaultRoot: vault, includeOnly: ["工作"], excluded: [])
        XCTAssertEqual(onlyWork.map(\.relativePath), ["工作/A.md"],
                       "includeOnly 非空 → 只收該資料夾（根目錄散檔也被排除）")

        let excludePrivate = ObsidianNoteIndexService.scanNotesWithHashes(
            vaultRoot: vault, includeOnly: [], excluded: ["私人"])
        XCTAssertEqual(Set(excludePrivate.map(\.relativePath)), ["工作/A.md", "根目錄散檔.md"])
    }

    /// 進度必須回報到「掃完」為止（scanned == total），否則 UI 的進度條會永遠停在 99%。
    @MainActor
    func testReindexReportsProgressToCompletion() async throws {
        let (ctx, embedder) = try makeContext()
        let vault = try makeTempVault(files: ["a.md": "內容甲", "b.md": "內容乙"])
        let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: ctx,
                                           stateURL: vault.appendingPathComponent(".s.json"))
        var updates: [NoteIndexCoordinator.Progress] = []
        _ = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: []) { updates.append($0) }

        let last = try XCTUnwrap(updates.last)
        XCTAssertEqual(last.scanned, 2)
        XCTAssertEqual(last.total, 2)
        XCTAssertEqual(last.reembedded, 2)
        XCTAssertNil(last.currentFile, "跑完就不該還指著某個檔")
        XCTAssertEqual(last.fraction, 1.0)
    }

    /// `force` = 無視 sidecar，全部重嵌一次（使用者的「索引看起來不對」逃生門）。
    /// 沒有 force 的話，內容 hash 相符就會全部跳過——而 hash 相符**不代表塊真的在**。
    @MainActor
    func testForceReembedsEvenWhenNothingChanged() async throws {
        let (ctx, embedder) = try makeContext()
        let vault = try makeTempVault(files: ["a.md": "內容"])
        let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: ctx,
                                           stateURL: vault.appendingPathComponent(".s.json"))
        _ = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])

        // 檔案沒動 → 增量掃是 0（既有行為，不可回歸）。
        embedder.embedCallCount = 0
        let incremental = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        XCTAssertEqual(incremental, 0)
        XCTAssertEqual(embedder.embedCallCount, 0)

        // force → 照樣重嵌。
        let forced = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [], force: true)
        XCTAssertEqual(forced, 1)
        XCTAssertEqual(embedder.embedCallCount, 1)
    }

    // MARK: - 🔴 取消與 force 的資料完整性（對抗式審查揪出的兩個 critical）

    /// 🔴 回歸鎖：**取消時冒出來的不一定是 `CancellationError`。**
    ///
    /// 迴圈唯一的懸掛點是 embedding 請求，所以按下取消時任務幾乎必然正懸在那裡；而 URLSession
    /// 被取消丟的是 `URLError(.cancelled)`，還會被 `EmbeddingClient` 包成 `.http(0, …)`。
    /// 若只認錯誤型別，整套「取消也要把已嵌好的檔記進 sidecar」的邏輯就是死碼：已經花錢嵌好的
    /// 檔沒記到 hash → 下次全部重嵌（重複付錢），使用者還會收到一則紅色「索引失敗」。
    /// 判斷依據必須是 `Task.isCancelled`。這裡用一個「一被取消就丟普通 Error」的 embedder 重現它。
    @MainActor
    func testCancelDuringEmbedStillRecordsFinishedFilesInSidecar() async throws {
        let container = try ModelContainer(
            for: EmbeddingChunk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let vault = try makeTempVault(files: ["a.md": "甲", "b.md": "乙", "c.md": "丙"])
        let stateURL = vault.appendingPathComponent(".s.json")

        // 嵌完第 1 個檔就取消當前 task；之後的 embed 呼叫丟「非 CancellationError」的錯（模擬 URLError）。
        let embedder = CancelAfterFirstEmbedder()
        let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: ctx, stateURL: stateURL)

        let task = Task { @MainActor in
            try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        }
        embedder.taskToCancel = task
        let result = await task.result

        // 1. 必須被當成「取消」，而不是「失敗」。
        switch result {
        case .success: XCTFail("被取消的 reindex 不該回報成功")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "取消要一路收斂成 CancellationError，實際是 \(error)")
        }

        // 2. **已經花錢嵌好的那個檔必須被記進 sidecar**（首次索引沒有舊 hash 可沿用，
        //    所以還沒輪到的 b/c 本來就不該有記錄——它們下一輪自然會被嵌）。
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try Data(contentsOf: stateURL)) as? [String: Any])
        let files = try XCTUnwrap(json["files"] as? [String: String])
        XCTAssertNotNil(files["a.md"], "已經嵌好並落盤的檔必須記進 sidecar，否則下次重嵌＝重複付錢")

        // 3. ★ 真正的契約：下一輪只嵌「還沒做的」兩個檔，**不重嵌已經付過錢的 a.md**。
        let resumed = CountingEmbedder()
        let count = try await ObsidianNoteIndexService(
            embedder: resumed, modelContext: ctx, stateURL: stateURL
        ).reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        XCTAssertEqual(count, 2, "接續時只補 b.md／c.md")
        XCTAssertEqual(resumed.embedCallCount, 2, "a.md 不可以被重嵌（取消不該讓已付出的成本白費）")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EmbeddingChunk>()), 3, "三個檔最終都要有塊")
    }

    /// 🔴 回歸鎖：**force 全量重嵌必須「先讓 sidecar 失效，再清塊」。**
    ///
    /// 反過來（先清塊、留著有效 sidecar）的話，只要這一輪中途死掉（sidecar 是最後才寫的 → 等於沒寫），
    /// 下次增量掃描會看到 hash 全命中 → 全部跳過 → **筆記索引永久空著且完全無聲**：重建鈕回報
    /// 「已是最新」。這裡讓 force 那一輪在第一個 embed 就爆掉，然後斷言「下一輪還救得回來」。
    @MainActor
    func testForceRebuildThatFailsMidwayIsRecoverableOnNextRun() async throws {
        let container = try ModelContainer(
            for: EmbeddingChunk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let vault = try makeTempVault(files: ["a.md": "甲", "b.md": "乙"])
        let stateURL = vault.appendingPathComponent(".s.json")

        // 先建立一份健康的索引。
        let good = CountingEmbedder()
        let svc = ObsidianNoteIndexService(embedder: good, modelContext: ctx, stateURL: stateURL)
        _ = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EmbeddingChunk>()), 2)

        // force 重嵌，但 embedding 全數失敗（斷網／金鑰過期）。
        let broken = ObsidianNoteIndexService(embedder: AlwaysFailingEmbedder(),
                                              modelContext: ctx, stateURL: stateURL)
        do {
            _ = try await broken.reindex(vaultRoot: vault, includeOnly: [], excluded: [], force: true)
            XCTFail("embedding 全失敗時 reindex 應該 throw")
        } catch {}

        // 塊被清光了（force 的起點就是清光）——這一步本來就會發生，重點是「還救不救得回來」。
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EmbeddingChunk>()), 0)

        // ★ 關鍵：下一輪**普通的增量掃描**（不帶 force）必須把兩個檔重新嵌回來。
        // 若 sidecar 還留著上一份有效 hash，這裡會回 0、索引永遠空著——那就是靜默失效。
        let healer = CountingEmbedder()
        let recovered = try await ObsidianNoteIndexService(
            embedder: healer, modelContext: ctx, stateURL: stateURL
        ).reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        XCTAssertEqual(recovered, 2, "失敗的 force 之後，下一次普通掃描必須把索引救回來")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EmbeddingChunk>()), 2)
    }

    /// 🔴 回歸鎖：取消時**不可以弄丟「已消失檔案」的 sidecar 記錄**。
    ///
    /// 消失檔（刪除／改名）的 key 只存在於 sidecar，不在磁碟掃描結果裡。取消時若只補「磁碟上還在的檔」，
    /// 這些 key 就從帳本上蒸發 → 下一輪算不出它們消失過 → 它們的塊變成**永久幽靈**，檢索照樣撈得到
    /// → AI 拿一篇早就刪掉的筆記回答你。
    @MainActor
    func testCancelKeepsVanishedFileRecordsSoGhostsCanStillBeReclaimed() async throws {
        let container = try ModelContainer(
            for: EmbeddingChunk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let vault = try makeTempVault(files: ["a.md": "甲", "b.md": "乙", "gone.md": "會被刪掉"])
        let stateURL = vault.appendingPathComponent(".s.json")

        _ = try await ObsidianNoteIndexService(embedder: CountingEmbedder(), modelContext: ctx,
                                               stateURL: stateURL)
            .reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EmbeddingChunk>()), 3)

        // 刪掉一個檔（它的塊現在是幽靈，等下一次掃描回收）。
        try FileManager.default.removeItem(at: vault.appendingPathComponent("gone.md"))
        // 改一個檔，讓它需要重嵌（這樣才會走到 embed 的懸掛點 → 才取消得掉）。
        try "改過了".write(to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let embedder = CancelAfterFirstEmbedder()
        let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: ctx, stateURL: stateURL)
        let task = Task { @MainActor in
            try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        }
        embedder.taskToCancel = task
        _ = await task.result

        // 取消後,sidecar 仍必須記得 gone.md —— 否則它的塊再也回收不了。
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try Data(contentsOf: stateURL)) as? [String: Any])
        let files = try XCTUnwrap(json["files"] as? [String: String])
        XCTAssertNotNil(files["gone.md"], "取消不可以把『已消失檔案』的記錄弄丟，否則幽靈塊永遠清不掉")

        // 證明它真的還清得掉：下一輪正常掃描要把 gone.md 的塊回收。
        let ghostId = ObsidianNoteChunking.noteId(relativePath: "gone.md")
        _ = try await ObsidianNoteIndexService(embedder: CountingEmbedder(), modelContext: ctx,
                                               stateURL: stateURL)
            .reindex(vaultRoot: vault, includeOnly: [], excluded: [])
        let ghosts = try ctx.fetch(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.transcriptionId == ghostId }))
        XCTAssertTrue(ghosts.isEmpty, "已刪檔案的塊必須被回收，否則 AI 會拿刪掉的筆記回答")
    }

    // MARK: - Helpers（鏡射 ObsidianNoteIndexTests）

    private func makeContext() throws -> (ModelContext, CountingEmbedder) {
        let container = try ModelContainer(
            for: EmbeddingChunk.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (ModelContext(container), CountingEmbedder())
    }

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

    // MARK: - 資料夾群組（groupedByFolder，M8 UI）

    private func group(_ groups: [NoteFolderCoverage], _ folder: String) -> NoteFolderCoverage? {
        groups.first { $0.folder == folder }
    }

    /// 全數索引好的資料夾 → 摺成單行:isFullyIndexed、100%、無待處理項。
    func testFullyIndexedFolderCollapses() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("筆記/A.md", hash: "h1"), note("筆記/B.md", hash: "h2")],
            sidecar: ["筆記/A.md": "h1", "筆記/B.md": "h2"],
            chunkCounts: ["筆記/A.md": 2, "筆記/B.md": 1],
            legacyChunkCount: 0)
        let g = group(coverage.groupedByFolder(), "筆記")
        XCTAssertNotNil(g)
        XCTAssertTrue(g?.isFullyIndexed ?? false)
        XCTAssertEqual(g?.indexedCount, 2)
        XCTAssertEqual(g?.percentIndexed, 100)
        XCTAssertEqual(g?.problemEntries.count, 0)
    }

    /// 部分索引 → 覆蓋率百分比正確,展開清單只列還沒索引的檔。
    func testPartiallyIndexedFolderReportsPercentAndUnindexed() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("工作/A.md", hash: "h1"), note("工作/B.md", hash: "h2"),
                      note("工作/C.md", hash: "h3"), note("工作/D.md", hash: "h4")],
            sidecar: ["工作/A.md": "h1"],                 // 只有 A 進了索引
            chunkCounts: ["工作/A.md": 2],
            legacyChunkCount: 0)
        let g = group(coverage.groupedByFolder(), "工作")
        XCTAssertNotNil(g)
        XCTAssertFalse(g?.isFullyIndexed ?? true)
        XCTAssertEqual(g?.indexedCount, 1)
        XCTAssertEqual(g?.percentIndexed, 25, "1/4 已索引 → 25%")
        XCTAssertEqual(g?.problemEntries.count, 3, "展開只列 B/C/D 三個待索引")
        XCTAssertTrue(g?.problemEntries.allSatisfy { $0.status == .pending } ?? false)
    }

    /// vault 根目錄散檔(路徑無 "/")歸到 "" 群組,不被丟掉、不崩。
    func testRootLooseFilesGroupIntoEmptyBucket() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("散檔.md", hash: "h1"), note("工作/A.md", hash: "h2")],
            sidecar: [:],
            chunkCounts: [:],
            legacyChunkCount: 0)
        let root = group(coverage.groupedByFolder(), "")
        XCTAssertNotNil(root, "根目錄散檔要有自己的群組")
        XCTAssertEqual(root?.entries.map(\.relativePath), ["散檔.md"])
    }

    /// 幽靈(刪掉但索引還留著)不算進覆蓋率分母,但仍列為待處理(該清理)。
    func testGhostDoesNotCountTowardPercentButIsAProblem() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("舊/A.md", hash: "h1")],
            sidecar: ["舊/A.md": "h1"],
            chunkCounts: ["舊/A.md": 2, "舊/已刪.md": 3],   // 已刪.md 掃不到 → ghost
            legacyChunkCount: 0)
        let g = group(coverage.groupedByFolder(), "舊")
        XCTAssertEqual(g?.percentIndexed, 100, "唯一的活檔已索引 → 分母不含幽靈,仍是 100%")
        XCTAssertFalse(g?.isFullyIndexed ?? true, "有幽靈待清理 → 不算完全就緒")
        XCTAssertEqual(g?.problemEntries.map(\.status), [.ghost])
    }

    /// 排序:有待處理的資料夾排在全數索引好的之前(打開表就是為了找洞)。
    func testProblemFoldersSortBeforeFullyIndexed() {
        let coverage = NoteIndexCoverage.compute(
            scanned: [note("已好/A.md", hash: "h1"), note("有洞/B.md", hash: "h2")],
            sidecar: ["已好/A.md": "h1"],                 // 有洞/B 沒進索引
            chunkCounts: ["已好/A.md": 1],
            legacyChunkCount: 0)
        let groups = coverage.groupedByFolder()
        XCTAssertEqual(groups.first?.folder, "有洞", "待處理的排最前")
        XCTAssertEqual(groups.last?.folder, "已好", "全數索引好的排最後")
    }
}

/// 回固定向量並計數呼叫（與 `ObsidianNoteIndexTests` 的 fake 同形，但那個是 fileprivate）。
private final class CountingEmbedder: EmbeddingProviding {
    var embedCallCount = 0
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        embedCallCount += 1
        return texts.map { _ in [0.25, 0.5, 0.75] }
    }
}

/// 嵌完第一個檔就取消整個 task，之後的呼叫丟一個**普通的** Error（不是 `CancellationError`）。
///
/// 重現正式環境的行為:被取消時懸在 URLSession 上的請求丟的是 `URLError(.cancelled)`，
/// 而 `EmbeddingClient` 又會把它包成 `EmbeddingError.http(0, "已取消")`。索引器若只 catch
/// `CancellationError`，取消路徑就整段失效——這個 fake 就是用來釘死那件事。
@MainActor
private final class CancelAfterFirstEmbedder: EmbeddingProviding {
    var embedCallCount = 0
    var taskToCancel: Task<Int, Error>?

    nonisolated init() {}

    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        embedCallCount += 1
        if embedCallCount == 1 {
            taskToCancel?.cancel()   // 使用者在第一個檔嵌完後按下「取消」
            return texts.map { _ in [0.25, 0.5, 0.75] }
        }
        // 已經被取消了 —— 丟一個非 CancellationError 的錯，正如真實的 URLSession/EmbeddingClient。
        throw EmbeddingError.http(0, "已取消。")
    }
}

/// embedding 一律失敗（斷網／金鑰過期）。
private final class AlwaysFailingEmbedder: EmbeddingProviding {
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        throw EmbeddingError.http(503, "service unavailable")
    }
}
