import Foundation
import CryptoKit
import SwiftData

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
@MainActor
final class ObsidianNoteIndexService {

    /// 索引塊的來源標記（scope 過濾與 reconcile 豁免都認這個字串）。集中成常數避免魔字串散落。
    static let sourceKind = "obsidian"

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
    /// - embed／save 失敗直接 throw 給呼叫端（設定頁顯示錯誤；背景掃描要吞錯由呼叫端決定，
    ///   與 `MeetingGroundingProvider` 的靜默紀律一致）。
    func reindex(vaultRoot: URL, includeOnly: [String], excluded: [String]) async throws -> Int {
        // 非沙盒 app 下是 no-op，照 house 慣例包 security-scope（鏡射 VaultExportService.export）。
        let accessing = vaultRoot.startAccessingSecurityScopedResource()
        defer { if accessing { vaultRoot.stopAccessingSecurityScopedResource() } }

        let oldState = loadState()
        let files = scanMarkdownFiles(vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded)
        let model = TranscriptIndexService.shared.model

        var newState: [String: String] = [:]
        var reembedded = 0

        // 依相對路徑排序：處理順序（與中斷點）可重現。
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
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

            let vectors = try await embedder.embed(texts: drafts.map(\.text), model: model)
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
                    categoryId: nil, timestamp: file.modifiedAt))
            }
            // save 用 throw（非 try?）：hash 只准記在「確定已落盤」的檔上，否則增量比對會漏重建。
            try modelContext.save()
            newState[file.relativePath] = hash
            reembedded += 1
        }

        // state 有記錄但磁碟上已消失（刪除或改名）的檔：回收它的塊。
        // 改名＝新路徑＝新 noteId，舊路徑的塊就是在這裡以「消失檔」身分被清掉。
        let present = Set(files.map(\.relativePath))
        let vanished = oldState.keys.filter { !present.contains($0) }
        if !vanished.isEmpty {
            for rel in vanished { deleteChunks(noteId: ObsidianNoteChunking.noteId(relativePath: rel)) }
            try modelContext.save()
        }

        // GOTCHA：sidecar 一定最後寫——先 persist 後記 hash。中途中斷時 sidecar 仍是舊狀態，
        // 下次重掃會重做未記錄的檔；因 upsert 冪等，重做只是多花錢、不會壞資料。
        try saveState(newState)
        return reembedded
    }

    // MARK: - 掃描

    private struct ScannedFile {
        let url: URL
        let relativePath: String
        let modifiedAt: Date
    }

    /// 收 vault 下所有 .md（含子目錄）。第一層目錄過濾：excluded 跳過；includeOnly 非空必須命中
    /// （vault 根目錄的散檔沒有第一層目錄名，只受 includeOnly 約束）。
    private func scanMarkdownFiles(vaultRoot: URL, includeOnly: [String], excluded: [String]) -> [ScannedFile] {
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

    // MARK: - 塊刪除（不落盤；save 時機由呼叫點統一掌控，維持先 persist 後記 hash 的順序）

    private func deleteChunks(noteId: UUID) {
        let existing = (try? modelContext.fetch(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.transcriptionId == noteId }))) ?? []
        for chunk in existing { modelContext.delete(chunk) }
    }

    // MARK: - Sidecar 狀態

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func loadState() -> [String: String] {
        guard let data = try? Data(contentsOf: stateURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private func saveState(_ state: [String: String]) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}
