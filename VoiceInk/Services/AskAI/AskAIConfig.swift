import Foundation
import SwiftData

/// Ask AI 範本的預載（一次性、冪等）。存於 index.store，透過 mainContext 存取。
enum AskAITemplateStore {
    static let seededKey = "askAITemplatesSeededV1"

    static let defaults: [(title: String, prompt: String)] = [
        ("面試覆盤教練", "你是資深面試官暨職涯教練，聚焦候選人的溝通表達、臨場反應與答題結構，點出亮點與可改進之處。"),
        ("會議重點整理", "你是專業會議記錄員，聚焦決議事項、待辦（負責人＋期限）與未解決的爭議，條列呈現。"),
        ("學習吸收助手", "你是學習教練，把內容整理成重點大綱、關鍵概念與可延伸思考的問題，方便日後複習。"),
    ]

    static func seedDefaultsIfNeeded(context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        for d in defaults {
            context.insert(AskAITemplate(title: d.title, systemPrompt: d.prompt))
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: seededKey)
    }
}

/// Ask AI 專用「回答模型」設定與解析（與 embedding 模型、enhancement 預設分離，可單獨選更強的模型）。
enum AskAIAnswerModel {
    static let providerKey = "askAIAnswerProvider"
    static let modelKey = "askAIAnswerModel"

    /// 解析用哪個 provider/model 回答：曾設定且仍在可用清單內 → 用設定值;否則跟隨預設 provider（回 nil model）。
    /// 純函式（不碰 UserDefaults/AIService）以便測試。
    static func resolve(storedProvider: String?, storedModel: String?,
                        defaultProvider: String, available: [String]) -> (provider: String, model: String?) {
        if let sp = storedProvider, !sp.isEmpty, available.contains(sp) {
            let m = (storedModel?.isEmpty == false) ? storedModel : nil
            return (sp, m)
        }
        return (defaultProvider, nil)
    }
}

/// Ask AI 來源篩選——UI 兩分：語音輸入 / 錄音輸入（會議歸錄音）。映射到 `EmbeddingChunk.sourceKind`。
enum AskAISourceFilter: String, CaseIterable, Identifiable {
    case all, voice, recorder
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部來源"
        case .voice: return "語音輸入"
        case .recorder: return "錄音輸入"
        }
    }
    /// 對應的 sourceKind 集合——永遠是明確集合，不再有 nil（= 不過濾）語意。
    /// `.all` 指的是「全部**逐字稿**來源」，不含 obsidian 筆記塊：
    /// 舊的 nil 會讓檢索層跳過 source 過濾，把筆記塊漏進預設查詢（見 AskAIScopeTests 回歸鎖）。
    /// 錄音輸入涵蓋一般錄音匯入與會議擷取。
    var sources: Set<String> {
        switch self {
        case .all: return ["dictation", "recorder", "meeting"]
        case .voice: return ["dictation"]
        case .recorder: return ["recorder", "meeting"]
        }
    }
}

/// 引用點回 Obsidian 的深連結：`obsidian://open?path=<絕對路徑>`。
///
/// 一律用 `URLComponents` 組，不手拼字串——筆記路徑含空白／中文是常態
/// （「工作/專案 A.md」），queryItems 會自動 percent-encode，手拼會生出非法 URL（→ nil，點了沒反應）。
///
/// 用 `path=`（絕對路徑）而非 `vault=`＋`file=`：讓 Obsidian 自己解析這條路徑屬於哪個 vault，
/// 我們就不必知道／匹配 vault 名稱（使用者可能重新命名 vault，或同一機器多個 vault）。
/// 前提：該 vault 至少被 Obsidian 開啟過一次（Obsidian 只認得它註冊過的 vault）。
enum ObsidianLink {
    static func openURL(vaultRoot: URL, relativePath: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "path",
                                         value: vaultRoot.appendingPathComponent(relativePath).path)]
        return comps.url
    }
}

/// scope bar 雙 chip → 檢索來源集合。空集合 = 兩顆都關（UI 會擋，這裡是最後防線）。
enum AskAIScopeComposer {
    static func sources(transcriptsOn: Bool, notesOn: Bool, filter: AskAISourceFilter) -> Set<String> {
        var s: Set<String> = []
        if transcriptsOn { s.formUnion(filter.sources) }
        if notesOn { s.insert(ObsidianNoteIndexService.sourceKind) }
        return s
    }
}
