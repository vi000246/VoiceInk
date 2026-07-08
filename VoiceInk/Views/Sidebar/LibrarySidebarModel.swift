import Foundation
import SwiftData
import Combine

/// 側欄「錄音管理／語音管理」可展開的分類子項資料 + deep-link 篩選狀態。
///
/// 兩個角色：
///  1. 計數：把目前的錄音項依 `recorderCategoryName`、語音項依 `manualTag` 分組計數，數量多者在前，
///     供側欄直接列出「分類 (檔案數)」。
///  2. 導覽：`recorderCategoryFilter` 是錄音管理頁的單一事實來源——側欄點某分類即設定它，
///     `RecorderHistoryView` 綁定同一值即完成 deep-link 篩選（避免雙向同步迴圈）。
@MainActor
final class LibrarySidebarModel: ObservableObject {
    static let shared = LibrarySidebarModel()

    struct CategoryCount: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }

    @Published private(set) var recorderCategories: [CategoryCount] = []
    @Published private(set) var voiceTags: [CategoryCount] = []

    /// 錄音管理頁目前的分類篩選（nil = 全部）。側欄與頁內 Picker 共用此單一來源。
    @Published var recorderCategoryFilter: String?

    private init() {}

    /// 重新計算分類計數。個人規模下一次抓全部再在記憶體分組成本可忽略（與 RecorderHistoryView 的
    /// @Query 同等級）。錄音項計 `recorderCategoryName`（nil 併入「未分類」但不列進側欄子項），
    /// 語音項計非空 `manualTag`。
    func refresh(_ context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Transcription>())) ?? []
        var rec: [String: Int] = [:]
        var voc: [String: Int] = [:]
        for t in all {
            if t.importFingerprint != nil {
                if let name = t.recorderCategoryName, !name.isEmpty { rec[name, default: 0] += 1 }
            } else {
                if let tag = t.manualTag, !tag.isEmpty { voc[tag, default: 0] += 1 }
            }
        }
        recorderCategories = Self.sortedCounts(rec)
        voiceTags = Self.sortedCounts(voc)
    }

    /// 數量多者在前;同數量以名稱排序保持穩定。
    private static func sortedCounts(_ dict: [String: Int]) -> [CategoryCount] {
        dict.map { CategoryCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
