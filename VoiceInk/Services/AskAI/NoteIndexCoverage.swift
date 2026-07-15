import Foundation

/// 一個筆記檔在「vault 現況」與「索引現況」比對下的狀態。
///
/// 存在的理由:增量索引的失效**全都是靜默的**——新檔沒掃到、改過的檔沒重嵌、刪掉的檔留著
/// 幽靈塊,使用者一律看不到,只會發現「AI 怎麼不知道我上週寫的東西」。這個 enum 讓每一種
/// 失效都有一個看得見的名字。
enum NoteIndexStatus: String {
    /// 索引裡有塊,且塊是用現在磁碟上這份內容嵌的。
    case indexed
    /// 索引裡有塊,但檔案在那之後被改過 → 塊是舊內容,下次掃描會重嵌。
    case stale
    /// 在索引範圍內,但索引裡一個塊都沒有 → **還沒被 RAG 納入**(新加的檔就長這樣)。
    case pending
    /// 掃過了,但這個檔沒有可索引的內容(空檔／只剩 frontmatter)→ 本來就不該有塊,不是漏索引。
    case empty
    /// 索引裡有塊,但檔案已不在範圍內(刪了、改名了、或被 exclude 排除)→ 下次掃描會清掉。
    case ghost

    /// UI 標籤(繁中);順序與 `NoteIndexCoverage.entries` 的排序權重一致。
    var label: String {
        switch self {
        case .indexed: return "已索引"
        case .stale:   return "已修改待重嵌"
        case .pending: return "尚未索引"
        case .empty:   return "無內容"
        case .ghost:   return "已移除待清理"
        }
    }

    /// 需要使用者注意(按重建才會消失)的狀態——決定摘要列要不要示警。
    var needsReindex: Bool { self == .pending || self == .stale }
}

/// 覆蓋率表的一列:一個筆記檔 + 它在索引裡的實際處境。
struct NoteIndexCoverageEntry: Identifiable, Equatable {
    let relativePath: String
    let status: NoteIndexStatus
    /// 索引裡屬於這個檔的 `EmbeddingChunk` 數(0 = 檢索永遠撈不到它)。
    let chunkCount: Int
    /// 檔案 mtime;`ghost` 沒有對應檔案 → nil。
    let modifiedAt: Date?

    var id: String { relativePath }
}

/// 掃描 vault 得到的一個 .md 檔(不含內容,只留比對用的最小資訊)。
struct ScannedNote: Equatable {
    let relativePath: String
    /// 檔案內容的 SHA-256（與 sidecar 記的 hash 同一種算法,才比得出「改過沒」）。
    let contentHash: String
    let modifiedAt: Date
    /// 這個檔切完塊之後**還有東西可嵌**嗎（去掉 frontmatter 後非空）。
    ///
    /// 為什麼非得實際算一次、不能從「hash 有記錄但沒有塊」反推:反推會把**真正的漏索引**
    /// 誤判成「這檔本來就沒內容」。塊有可能在 sidecar 不知情的狀況下消失（例如強制全量重嵌
    /// 清了塊之後中途失敗），那時每個檔都是「hash 命中、零塊」——反推的結論會是一整排無害的
    /// 「無內容」，而事實是**整個筆記索引空了**。覆蓋率表存在的唯一目的就是抓這種事,它自己
    /// 絕不能是第一個說謊的人。掃描本來就要讀檔算 hash,順手切一次塊幾乎不花錢。
    let hasIndexableContent: Bool
}

/// 「vault 有什麼」對上「索引裡有什麼」的比對結果。
struct NoteIndexCoverage: Equatable {
    var entries: [NoteIndexCoverageEntry]
    /// 索引裡 `sourcePath` 為 nil 的 obsidian 塊數(M8 舊格式殘留,查得到但認不出是哪個檔)。
    /// > 0 = 索引狀態不可信,該按「強制全量重嵌」。
    var legacyChunkCount: Int

    func count(_ status: NoteIndexStatus) -> Int { entries.filter { $0.status == status }.count }

    /// 索引裡實際有塊的檔數(= 檢索真的撈得到的檔)。
    var indexedFileCount: Int { entries.filter { $0.chunkCount > 0 }.count }
    var totalChunkCount: Int { entries.reduce(0) { $0 + $1.chunkCount } }
    /// 有任何一列需要重建(新檔沒進、改過沒重嵌)。
    var needsReindex: Bool { entries.contains { $0.status.needsReindex } }

    /// 純函式比對——這是整個覆蓋率功能唯一有邏輯的地方,刻意抽出來讓它可被單元測試釘死。
    ///
    /// - `scanned`: 套過 include/exclude 之後、vault 裡**應該**被索引的 .md 檔(含內容 hash)。
    /// - `sidecar`: 索引服務記的「路徑 → 內容 hash」。**注意這裡要餵已經驗證過的版本**
    ///   (`ObsidianNoteIndexService.loadSidecar` 在 schema/模型 tag 不符時回空)——回空
    ///   代表「這份索引不可信」,於是每個有塊的檔都會被判成 `stale`、沒塊的判成 `pending`,
    ///   正好就是「該全部重嵌」的畫面。這不是 bug,是換 embedding 模型後應有的樣子。
    /// - `chunkCounts`: 索引裡 obsidian 塊依 `sourcePath` 分組的計數(**權威來源是塊本身,
    ///   不是 sidecar** —— sidecar 只是 hash 帳本,塊才是檢索真正看得到的東西)。
    static func compute(scanned: [ScannedNote],
                        sidecar: [String: String],
                        chunkCounts: [String: Int],
                        legacyChunkCount: Int) -> NoteIndexCoverage {
        var entries: [NoteIndexCoverageEntry] = []

        for note in scanned {
            let chunks = chunkCounts[note.relativePath] ?? 0
            let hashMatches = sidecar[note.relativePath] == note.contentHash
            let status: NoteIndexStatus
            if chunks > 0 {
                // 有塊：唯一要回答的是「這些塊是不是用磁碟上這份內容嵌的」。
                status = hashMatches ? .indexed : .stale
            } else if !note.hasIndexableContent {
                // 零塊、而且這個檔本來就切不出東西（空檔／只剩 frontmatter）→ 不是漏索引。
                status = .empty
            } else {
                // 零塊、但檔案**明明有內容** → 檢索絕對撈不到它。**不管 sidecar 怎麼說**都是待索引。
                // 這條刻意不看 hash：hash 命中只代表「上次掃描處理過這個路徑」,不代表「塊還在」。
                // 拿 hash 當作「已索引」的證據,就會在塊被清掉而 sidecar 沒同步的情況下謊報「無內容」——
                // 而那正是這張表唯一該抓到的事。塊才是權威,sidecar 只是帳本。
                status = .pending
            }
            entries.append(NoteIndexCoverageEntry(
                relativePath: note.relativePath, status: status,
                chunkCount: chunks, modifiedAt: note.modifiedAt))
        }

        // 索引裡有、但 vault 掃不到的路徑 = 幽靈(刪除/改名/被排除)。檢索**還撈得到它們**,
        // 所以一定要顯示——這正是「AI 拿早就刪掉的筆記回答」的來源。
        let present = Set(scanned.map(\.relativePath))
        for (path, chunks) in chunkCounts where !present.contains(path) && chunks > 0 {
            entries.append(NoteIndexCoverageEntry(
                relativePath: path, status: .ghost, chunkCount: chunks, modifiedAt: nil))
        }

        // 要處理的排前面(pending → stale → ghost → indexed → empty),同狀態內依路徑排序。
        // 使用者打開這張表是為了找「漏了什麼」,不是為了瀏覽已經好好的檔。
        let weight: [NoteIndexStatus: Int] = [.pending: 0, .stale: 1, .ghost: 2, .indexed: 3, .empty: 4]
        entries.sort {
            let (a, b) = (weight[$0.status] ?? 9, weight[$1.status] ?? 9)
            return a == b ? $0.relativePath < $1.relativePath : a < b
        }
        return NoteIndexCoverage(entries: entries, legacyChunkCount: legacyChunkCount)
    }
}

/// 覆蓋率的**資料夾層**摘要(M8 UI):一整個資料夾若全數索引好,只需一行「已索引」;
/// 部分索引則顯示覆蓋率百分比,展開才列出底下還沒索引的檔。逐檔清單在幾百個筆記時
/// 又長又難掃,群組後一眼就看得出「哪個資料夾還有洞」。
///
/// 純衍生型別,不動 `NoteIndexCoverage.compute`——既有測試釘死的是逐檔比對邏輯,
/// 分組只是顯示層的重新聚合,加成新函式即可,不改既有語意。
struct NoteFolderCoverage: Identifiable, Equatable {
    /// 第一層目錄名;`""` = vault 根目錄下的散檔。
    let folder: String
    /// 這個資料夾底下的列(已沿用 compute 的排序:待處理在前)。
    let entries: [NoteIndexCoverageEntry]

    var id: String { folder }

    /// 需要出現在「還沒索引」展開清單裡的列:待索引 / 已修改待重嵌 / 幽靈待清理。
    var problemEntries: [NoteIndexCoverageEntry] {
        entries.filter { $0.status == .pending || $0.status == .stale || $0.status == .ghost }
    }

    /// 覆蓋率分母:有內容、**應該**進索引的活檔(排除無內容檔與幽靈)。
    private var indexableCount: Int {
        entries.filter { $0.status == .indexed || $0.status == .pending || $0.status == .stale }.count
    }

    /// 已索引的檔數。
    var indexedCount: Int { entries.filter { $0.status == .indexed }.count }

    /// 沒有任何待處理項 → 可摺成單行「已索引」。
    var isFullyIndexed: Bool { problemEntries.isEmpty }

    /// 已索引百分比(0–100);沒有任何可索引檔時視為 100。
    var percentIndexed: Int {
        indexableCount == 0 ? 100 : Int((Double(indexedCount) / Double(indexableCount) * 100).rounded())
    }
}

extension NoteIndexCoverage {
    /// 依 `relativePath` 第一層目錄分組(與 include/exclude 的資料夾範圍同一套粒度)。
    /// 有待處理項的資料夾排前面,其餘依名稱;vault 根目錄散檔(`""`)恆排最後。
    func groupedByFolder() -> [NoteFolderCoverage] {
        let groups = Dictionary(grouping: entries) { entry -> String in
            let comps = entry.relativePath.split(separator: "/", omittingEmptySubsequences: true)
            return comps.count > 1 ? String(comps[0]) : ""
        }
        return groups
            .map { NoteFolderCoverage(folder: $0.key, entries: $0.value) }
            .sorted { lhs, rhs in
                if lhs.isFullyIndexed != rhs.isFullyIndexed { return !lhs.isFullyIndexed } // 待處理在前
                if lhs.folder.isEmpty != rhs.folder.isEmpty { return !lhs.folder.isEmpty } // 根目錄散檔在後
                return lhs.folder.localizedStandardCompare(rhs.folder) == .orderedAscending
            }
    }
}
