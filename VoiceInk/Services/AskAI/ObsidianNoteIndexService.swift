import Foundation
import CryptoKit
import SwiftData
import os

/// Obsidian 筆記 → 索引塊的純函式（切塊委給既有 TranscriptChunker）。
enum ObsidianNoteChunking {

    /// 去 YAML frontmatter：檔案以 "---\n" 開頭且存在收尾 "\n---" 才剝，否則原樣。
    static func stripFrontmatter(_ md: String) -> String {
        guard md.hasPrefix("---\n") else { return md }
        let afterOpen = md.index(md.startIndex, offsetBy: 4)
        guard let close = md.range(of: "\n---", range: afterOpen..<md.endIndex) else { return md }
        var body = String(md[close.upperBound...])
        if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 每塊前綴《標題》供 LLM 引用出處；切塊沿用 TranscriptChunker（段落、CJK-aware）。
    static func chunks(title: String, body: String) -> [ChunkDraft] {
        TranscriptChunker.chunks(for: body).map {
            ChunkDraft(index: $0.index, text: "《\(title)》\n\($0.text)")
        }
    }

    /// vault 相對路徑 → 確定性 UUID（SHA-256 前 16 bytes）。改名＝新 id＝舊塊變孤兒由 diff 清。
    static func noteId(relativePath: String) -> UUID {
        let digest = SHA256.hash(data: Data(relativePath.utf8))
        let bytes = Array(digest.prefix(16))
        return NSUUID(uuidBytes: bytes) as UUID
    }
}

/// Obsidian vault → 向量索引的增量掃描服務。
/// 形狀鏡射 `TranscriptIndexService`（injectable embedder／modelContext），但身分鍵改用
/// `ObsidianNoteChunking.noteId(relativePath:)` 的確定性 UUID——同一路徑永遠算出同一 id，
/// 「先刪同 id 舊塊、再插新塊」就成了天然的取代式 upsert：重跑冪等、不會產生重複塊。
///
/// **in-flight 與進度不歸這裡管**：誰在跑、跑到哪、能不能取消，全部由 `NoteIndexCoordinator`
/// 持有（見該檔的說明）。這個 class 只負責「掃一次、嵌一次」這件事本身。
@MainActor
final class ObsidianNoteIndexService {

    /// 索引塊的來源標記（scope 過濾與 reconcile 豁免都認這個字串）。集中成常數避免魔字串散落。
    static let sourceKind = "obsidian"

    /// sidecar 的格式版本。**改變塊內容或塊欄位語意時必須 +1**——版本一升，`loadState` 就視同
    /// 沒有狀態 → 全量重嵌，舊塊在起點被清光（見 `discardAllNoteChunks`）。這是筆記索引唯一的
    /// 自癒機制：檔案內容 hash 沒變，只有「我們產塊的方式」變了，靠版本號才追得回來。
    /// 2 = 塊帶 `sourceTitle` / `sourcePath` 出處欄位（1 = M8 首版，塊沒有出處）。
    static let sidecarSchema = 2

    private let embedder: EmbeddingProviding
    private let modelContext: ModelContext
    /// sidecar 狀態檔（JSON `[相對路徑: 內容 SHA-256]`）：增量比對的唯一依據。
    private let stateURL: URL

    init(embedder: EmbeddingProviding = LiveEmbedder(), modelContext: ModelContext, stateURL: URL) {
        self.embedder = embedder
        self.modelContext = modelContext
        self.stateURL = stateURL
    }

    /// 全量／增量重建索引。回傳本次真正重嵌（有打 embedding）的檔數。
    /// - `excluded` 的第一層目錄一律跳過；`includeOnly` 非空時第一層目錄名必須命中。
    /// - `force`: 無視 sidecar，當作沒有任何狀態 → 全量重嵌（使用者手動「強制全量重嵌」的入口）。
    /// - `onProgress`: 每處理完一個檔回報一次（含跳過未變更的檔）。純觀察,不影響索引結果。
    /// - embed／save 失敗直接 throw 給呼叫端（設定頁顯示錯誤；背景掃描要吞錯由呼叫端決定，
    ///   與 `MeetingGroundingProvider` 的靜默紀律一致）。
    /// - 取消：每個檔的邊界檢查一次。取消時**照樣寫回 sidecar**（未處理的檔沿用舊 hash）——
    ///   已經花錢嵌好的檔就此記帳，下次不用重嵌；改過但還沒輪到的檔因為 hash 仍是舊的，
    ///   下次比對照樣會發現它變了。取消不該讓已付出的成本白費，也不該掩蓋還沒做的事。
    @discardableResult
    func reindex(vaultRoot: URL, includeOnly: [String], excluded: [String],
                 force: Bool = false,
                 onProgress: ((NoteIndexCoordinator.Progress) -> Void)? = nil) async throws -> Int {
        // 非沙盒 app 下是 no-op，照 house 慣例包 security-scope（鏡射 VaultExportService.export）。
        let accessing = vaultRoot.startAccessingSecurityScopedResource()
        defer { if accessing { vaultRoot.stopAccessingSecurityScopedResource() } }

        let model = TranscriptIndexService.shared.model
        // 空 = 全量重嵌（首次索引、**換過 embedding 模型**，或 sidecar 版本過舊——見 loadState）。
        let oldState = force ? [:] : loadState(currentModelTag: model.tag)
        if oldState.isEmpty {
            // 🔴 順序不可對調：**先讓 sidecar 失效，再清塊。**
            //
            // 反過來寫（先清塊、留著一份仍然「有效」的 sidecar）會製造出最惡毒的一種狀態:塊全沒了，
            // 但 hash 表還在。只要這一輪中途死掉（網路斷、金鑰過期、使用者關掉 app）——而 sidecar
            // 是**最後**才寫的，中途死掉就等於沒寫——下一次增量掃描會看到「每個檔的 hash 都命中」
            // → 全部跳過 → **筆記索引就此永久空著，而且沒有任何錯誤訊息**：重建按鈕回報「已是最新
            // （0 檔變動）」，覆蓋率表每一列都寫「無內容」。使用者只會發現 AI 突然不知道自己寫過什麼。
            // （`force` 才碰得到這條路:非 force 的全量重嵌是因為 schema/model tag 不符，那份 sidecar
            // 本來就已經不可信，下次照樣回空 → 自然會重嵌。force 的 sidecar 卻是有效的。）
            //
            // 先寫空 state：即使接著整個爆掉，下一輪的 `loadState` 也會回空 → 重新全量嵌回來。
            try saveState([:], modelTag: model.tag)
            discardAllNoteChunks()
        }
        let files = Self.scanMarkdownFiles(vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded)
            .sorted { $0.relativePath < $1.relativePath }   // 處理順序（與中斷點）可重現。

        var newState: [String: String] = [:]
        var reembedded = 0
        var cancelled = false

        for (i, file) in files.enumerated() {
            // 取消點：在「還沒開始這個檔」時退出，不會留下嵌到一半的檔。
            if Task.isCancelled { cancelled = true; break }
            onProgress?(NoteIndexCoordinator.Progress(
                scanned: i, total: files.count, reembedded: reembedded,
                currentFile: file.relativePath))

            guard let data = try? Data(contentsOf: file.url),
                  let content = String(data: data, encoding: .utf8) else {
                // 讀不到就沿用舊 hash（若有）：塊保留，等下次可讀時再依 hash 差異重建。
                if let old = oldState[file.relativePath] { newState[file.relativePath] = old }
                continue
            }
            let hash = Self.sha256Hex(data)
            if oldState[file.relativePath] == hash {
                newState[file.relativePath] = hash   // 未變更：不動塊、hash 照抄。
                continue
            }

            let noteId = ObsidianNoteChunking.noteId(relativePath: file.relativePath)
            let title = file.url.deletingPathExtension().lastPathComponent
            let body = ObsidianNoteChunking.stripFrontmatter(content)
            let drafts = ObsidianNoteChunking.chunks(title: title, body: body)

            if drafts.isEmpty {
                // 內容清空（或只剩 frontmatter）：只刪舊塊，不嵌入、不計入回傳數。
                deleteChunks(noteId: noteId)
                try modelContext.save()
                newState[file.relativePath] = hash
                continue
            }

            // 🔴 取消**不會**以 CancellationError 的形式從這裡冒出來。這個 await 是整個迴圈唯一的
            // 懸掛點（其餘都是同步的檔案讀取/hash/save），所以使用者按取消時，任務幾乎必然正懸在
            // 這裡；而 URLSession 被取消時丟的是 `URLError(.cancelled)`，`EmbeddingClient` 的通用
            // catch 又把它包成 `.http(0, "已取消")`。直接 `catch is CancellationError` 永遠抓不到，
            // 下面那整套「取消也要記帳」的邏輯就會變成死碼:sidecar 不寫 → 已經花錢嵌好的檔沒記到
            // hash → 下次全部重嵌（重複付錢），而且使用者看到的是紅色「索引失敗」而不是「已取消」。
            // 所以判斷依據是 `Task.isCancelled`，不是錯誤型別。
            let vectors: [[Float]]
            do {
                vectors = try await embedder.embed(texts: drafts.map(\.text), model: model)
            } catch {
                if Task.isCancelled { cancelled = true; break }
                throw error
            }
            guard vectors.count == drafts.count else {
                throw EmbeddingError.countMismatch(expected: drafts.count, got: vectors.count)
            }

            // 取代式 upsert：確定性 noteId 保證「刪舊＋插新」重跑冪等。
            deleteChunks(noteId: noteId)
            for (draft, vector) in zip(drafts, vectors) {
                modelContext.insert(EmbeddingChunk(
                    transcriptionId: noteId, chunkIndex: draft.index, text: draft.text,
                    vector: EmbeddingClient.floatsToData(vector), dims: model.dims,
                    embeddingModel: model.tag, sourceKind: Self.sourceKind,
                    categoryId: nil, timestamp: file.modifiedAt,
                    // 出處反正規化在塊上：筆記沒有 Transcription 可查，引用 UI 只認得塊本身。
                    sourceTitle: title, sourcePath: file.relativePath))
            }
            // save 用 throw（非 try?）：hash 只准記在「確定已落盤」的檔上，否則增量比對會漏重建。
            try modelContext.save()
            newState[file.relativePath] = hash
            reembedded += 1
        }

        if cancelled {
            // 沿用**所有**還沒處理到的舊記錄 —— 注意是走 `oldState`，不是走 `files`。
            //
            // 只補 `files`（= 磁碟上還在的檔）會悄悄弄丟一種記錄：**已經從磁碟上消失的檔**。
            // 那些 key 只存在於 oldState，不在 files 裡，於是不會被補回 newState → 寫回 sidecar 後
            // 它們就從帳本上蒸發了。而下一輪的「消失檔清理」是靠 `oldState.keys - 磁碟上的檔` 算出來的
            // ——帳本上沒有記錄，就永遠算不出它消失過 → **它的塊變成永久幽靈**：檢索照樣撈得到，
            // AI 於是拿一篇早就刪掉的筆記回答你。取消一次，幽靈跟著你一輩子。
            //
            // 改過但還沒輪到的檔：補回去的是**舊** hash，跟磁碟上的新內容對不上 → 下次照樣判定要重嵌。
            // 所以這裡不會把「還沒做的事」蓋成「做完了」。
            for (path, hash) in oldState where newState[path] == nil { newState[path] = hash }
        } else {
            // state 有記錄但磁碟上已消失（刪除或改名）的檔：回收它的塊。
            // 改名＝新路徑＝新 noteId，舊路徑的塊就是在這裡以「消失檔」身分被清掉。
            // 取消時**不做**這步：掃描雖然完整，但半途而廢的一輪不該順手做破壞性清理。
            let present = Set(files.map(\.relativePath))
            let vanished = oldState.keys.filter { !present.contains($0) }
            if !vanished.isEmpty {
                for rel in vanished { deleteChunks(noteId: ObsidianNoteChunking.noteId(relativePath: rel)) }
                try modelContext.save()
            }
        }

        // GOTCHA：sidecar 一定最後寫——先 persist 後記 hash。中途中斷時 sidecar 仍是舊狀態，
        // 下次重掃會重做未記錄的檔；因 upsert 冪等，重做只是多花錢、不會壞資料。
        try saveState(newState, modelTag: model.tag)

        onProgress?(NoteIndexCoordinator.Progress(
            scanned: files.count, total: files.count, reembedded: reembedded, currentFile: nil))
        if cancelled { throw CancellationError() }
        return reembedded
    }

    // MARK: - 掃描

    /// 掃到的一個 .md 檔。
    struct ScannedFile {
        let url: URL
        let relativePath: String
        let modifiedAt: Date
    }

    /// 收 vault 下所有 .md（含子目錄）。第一層目錄過濾：excluded 跳過；includeOnly 非空必須命中
    /// （vault 根目錄的散檔沒有第一層目錄名，只受 includeOnly 約束）。
    ///
    /// `nonisolated` 是為了讓覆蓋率檢查能在背景執行緒跑（純檔案 IO，不碰 modelContext）——
    /// 幾千個檔的 walk＋hash 掛在 MainActor 上會讓 UI 卡住。呼叫端自行負責 security-scope。
    nonisolated static func scanMarkdownFiles(vaultRoot: URL, includeOnly: [String],
                                             excluded: [String]) -> [ScannedFile] {
        let rootPath = vaultRoot.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: vaultRoot, includingPropertiesForKeys: keys) else { return [] }

        var result: [ScannedFile] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }

            // 相對路徑（同時是 noteId 與 sidecar 的鍵）：由同一 root 字串前綴推出，跨掃描穩定。
            let filePath = url.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else { continue }
            let rel = String(filePath.dropFirst(rootPath.count + 1))

            let comps = rel.split(separator: "/")
            let topDir = comps.count > 1 ? String(comps[0]) : nil
            if let topDir, excluded.contains(topDir) { continue }
            if !includeOnly.isEmpty {
                guard let topDir, includeOnly.contains(topDir) else { continue }
            }

            result.append(ScannedFile(url: url, relativePath: rel,
                                      modifiedAt: values?.contentModificationDate ?? Date()))
        }
        return result
    }

    /// 掃描 ＋ 逐檔算內容 hash 與「切得出塊嗎」（覆蓋率比對用；`reindex` 自己在讀檔時順手算，不走這條）。
    /// 讀不到的檔直接略過——它本來就進不了索引，列在覆蓋率表上只會製造假的「待索引」。
    ///
    /// 這裡**必須用與 `reindex` 完全相同的切塊規則**（去 frontmatter → `ObsidianNoteChunking.chunks`）
    /// 來判斷「有沒有可索引內容」。兩邊規則一旦分岔，覆蓋率就會宣稱某個檔該有塊、而索引器永遠不會
    /// 給它塊 —— 一個按幾次「重建」都消不掉的假警報。
    nonisolated static func scanNotesWithHashes(vaultRoot: URL, includeOnly: [String],
                                                excluded: [String]) -> [ScannedNote] {
        let accessing = vaultRoot.startAccessingSecurityScopedResource()
        defer { if accessing { vaultRoot.stopAccessingSecurityScopedResource() } }
        return scanMarkdownFiles(vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded)
            .compactMap { file in
                guard let data = try? Data(contentsOf: file.url) else { return nil }
                let title = file.url.deletingPathExtension().lastPathComponent
                let hasContent: Bool
                if let text = String(data: data, encoding: .utf8) {
                    let body = ObsidianNoteChunking.stripFrontmatter(text)
                    hasContent = !ObsidianNoteChunking.chunks(title: title, body: body).isEmpty
                } else {
                    hasContent = false   // 解不成 UTF-8 → reindex 也讀不了它 → 本來就不會有塊
                }
                return ScannedNote(relativePath: file.relativePath,
                                   contentHash: sha256Hex(data),
                                   modifiedAt: file.modifiedAt,
                                   hasIndexableContent: hasContent)
            }
    }

    // MARK: - 塊刪除（不落盤；save 時機由呼叫點統一掌控，維持先 persist 後記 hash 的順序）

    private func deleteChunks(noteId: UUID) {
        let existing = (try? modelContext.fetch(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.transcriptionId == noteId }))) ?? []
        for chunk in existing { modelContext.delete(chunk) }
    }

    // MARK: - Sidecar 狀態

    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// sidecar 的內容。`embeddingModel` 與 `schema` **都不是裝飾欄位**——它們是換模型／改塊格式時
    /// 唯一能救回筆記索引的訊號，見 `loadState`。
    private struct IndexState: Codable {
        /// sidecar／塊格式版本（= `sidecarSchema`）。**刻意非 optional**：舊 JSON 缺這個鍵會直接
        /// decode 失敗 → `loadState` 回空 → 全量重嵌。不符版本的 sidecar 天生就是「不可信」，
        /// 讓 decoder 幫我們判斷，不用手寫版本比對，也不會有「忘了比對」的漏洞。
        var schema: Int
        /// 這份 hash 表是在哪個向量空間下建立的（= `EmbeddingModel.tag`）。
        var embeddingModel: String
        /// vault 相對路徑 → 內容 SHA-256。
        var files: [String: String]
    }

    /// 可信的「路徑 → 內容 hash」。**回空 = 全量重嵌。**
    ///
    /// 🔴 tag 不符時必須回空（2026-07-14 修 FR-44 後半）：`TranscriptIndexService.switchModel`
    /// 換模型時會刪光**所有** `EmbeddingChunk`（含筆記塊），但 vault 的檔案內容一個字都沒改。
    /// 只比對內容 hash 的話，下次掃描會全部命中、全部跳過 → **筆記塊永遠回不來**，而且設定頁的
    /// 「重建筆記庫索引」還會回報「0 檔」，看起來一切正常。使用者只會發現 aboutMe 突然開始說
    /// 「筆記沒記」——**失效是靜默的**，這是最糟的失敗模式。
    /// tag 不符 = 向量空間不相容 = 全量重嵌，正是 `switchModel` 的語意。
    ///
    /// 舊格式（M8 首版的裸 `[路徑: hash]`，不知道當時用哪顆模型）一律視為不符：保守重嵌一次，
    /// 比賭「它剛好是同一顆模型」安全。
    ///
    /// 兩道 guard **各自獨立**：`schema` 管「塊的產法變了」（例如塊開始帶出處欄位——內容 hash
    /// 一個字沒變，只有版本號看得出來），`embeddingModel` 管「向量空間變了」。任一不符都回空。
    ///
    /// 覆蓋率檢查也走這裡（`nonisolated`）：它必須看到**和索引一模一樣的信任判斷**，否則會出現
    /// 「覆蓋率說全都索引好了、實際上換過模型一個都查不到」的謊報。
    nonisolated static func loadSidecar(stateURL: URL, currentModelTag: String) -> [String: String] {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(IndexState.self, from: data),
              state.schema == Self.sidecarSchema,
              state.embeddingModel == currentModelTag else { return [:] }
        return state.files
    }

    private func loadState(currentModelTag: String) -> [String: String] {
        Self.loadSidecar(stateURL: stateURL, currentModelTag: currentModelTag)
    }

    /// 全量重嵌的起點：清掉**所有**筆記塊（不分 model tag）。
    ///
    /// 呼叫點只有一個——`oldState.isEmpty`，而空 oldState 的語意就是「這份索引不可信，重建一切」。
    /// 只清「不同 model tag」的舊塊不夠：sidecar 版本升級時 tag 通常沒變，磁碟上已刪除的筆記留下的
    /// 塊會活過重嵌（新一輪只會 upsert 掃得到的檔，掃不到的檔沒人去碰它的塊）→ 這些幽靈塊
    /// tag 相符，`RetrievalService` 檢索得到 → **AI 拿早就刪掉的筆記回答**。所以起點就清光；
    /// 掃描會把還在磁碟上的檔重新嵌回來，清多了不會少東西，清少了會答錯。
    private func discardAllNoteChunks() {
        let kind = Self.sourceKind
        let notes = (try? modelContext.fetch(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.sourceKind == kind }))) ?? []
        guard !notes.isEmpty else { return }
        for chunk in notes { modelContext.delete(chunk) }
        try? modelContext.save()
    }

    private func saveState(_ files: [String: String], modelTag: String) throws {
        let state = IndexState(schema: Self.sidecarSchema, embeddingModel: modelTag, files: files)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    // MARK: - 自動增量觸發（Ask AI 頁 onAppear／筆記 chip 開啟；會議 attach 走 scheduleNotesReindex）

    /// sidecar 路徑（原本住在 `MeetingCopilotLiveController`，FR-8 搬家不搬檔——路徑一字不差，
    /// 否則兩邊各記各的 hash，互看都是「全新 vault」，每次全量重嵌純燒錢）。
    static func defaultStateURL() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("obsidian-index-state.json")
    }

    /// 背景增量掃（single-flight、失敗靜默 log-only）。
    ///
    /// single-flight 現在歸 `NoteIndexCoordinator` 管——它是**全app 唯一**的 in-flight 擁有者，
    /// 所以「Ask AI 頁 onAppear」「筆記 chip 開啟」「會議 attach」「設定頁手動重建」四個入口
    /// 彼此之間也互斥（以前只有前兩者互斥,開著 Ask AI 又開會就是兩份 reindex 同時掃同一份
    /// sidecar、互相覆蓋 hash 表、重複燒 embedding 錢）。
    @MainActor
    static func autoIndex(vaultRoot: URL, includeOnly: [String], excluded: [String],
                          stateURL: URL, modelContext: ModelContext,
                          embedder: EmbeddingProviding = LiveEmbedder()) async {
        await NoteIndexCoordinator.shared.run(
            vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded,
            stateURL: stateURL, modelContext: modelContext, embedder: embedder,
            force: false, announce: false)
    }
}
