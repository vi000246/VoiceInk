import Foundation

/// 錄音管理／語音管理共用的純函式篩選＋排序。純值型別——view 與測試共用，避開把多條件塞進
/// 單一 SwiftData `#Predicate`（本 session 多次踩到型別檢查爆炸）。個人規模下 fetch 後 filter 成本可忽略。
struct LibraryFilter: Equatable {
    /// 頁面範圍：錄音管理＝有 importFingerprint（錄音/會議匯入）;語音管理＝無（語音輸入/聽寫）。
    enum Scope: Equatable { case recorder, voice }
    enum SortField: String, CaseIterable, Equatable { case date, size, title }

    var scope: Scope
    var searchText: String = ""
    var tag: String?              // displayTag 完全比對;nil＝全部
    var starredOnly: Bool = false
    var dateRange: ClosedRange<Date>?
    var sort: SortField = .date
    var ascending: Bool = false

    /// 套用篩選＋排序。`sizeByFingerprint` 供依檔案大小排序（錄音項）。
    func apply(to items: [Transcription], sizeByFingerprint: [String: Int] = [:]) -> [Transcription] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = items.filter { t in
            // 範圍
            switch scope {
            case .recorder: if t.importFingerprint == nil { return false }
            case .voice:    if t.importFingerprint != nil { return false }
            }
            if starredOnly, !t.recorderFavorite { return false }
            if let tag, t.displayTag != tag { return false }
            if let dateRange, !dateRange.contains(t.timestamp) { return false }
            if !q.isEmpty {
                let hay = [t.text, t.enhancedText ?? "", t.recorderTitle ?? "", t.displayTag ?? ""]
                if !hay.contains(where: { $0.localizedStandardContains(q) }) { return false }
            }
            return true
        }
        return filtered.sorted { a, b in
            let result: Bool
            switch sort {
            case .date: result = a.timestamp < b.timestamp
            case .size:
                let sa = a.importFingerprint.flatMap { sizeByFingerprint[$0] } ?? 0
                let sb = b.importFingerprint.flatMap { sizeByFingerprint[$0] } ?? 0
                result = sa < sb
            case .title:
                let ta = a.recorderTitle ?? a.text
                let tb = b.recorderTitle ?? b.text
                result = ta.localizedStandardCompare(tb) == .orderedAscending
            }
            return ascending ? result : !result
        }
    }

    /// 星號保護的刪除集：預設把星號錄音排除在刪除之外;`includeStarred` 為真才納入（呼叫端須先警告）。
    /// 回傳 (實際要刪的, 被保護排除的星號數)。
    static func deletionSet(from selected: [Transcription], includeStarred: Bool)
        -> (toDelete: [Transcription], starredExcluded: Int) {
        if includeStarred { return (selected, 0) }
        let toDelete = selected.filter { !$0.recorderFavorite }
        let starredExcluded = selected.count - toDelete.count
        return (toDelete, starredExcluded)
    }
}
