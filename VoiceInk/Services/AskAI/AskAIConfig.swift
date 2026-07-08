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
    /// 對應的 sourceKind 集合;nil = 不限。錄音輸入涵蓋一般錄音匯入與會議擷取。
    var sources: Set<String>? {
        switch self {
        case .all: return nil
        case .voice: return ["dictation"]
        case .recorder: return ["recorder", "meeting"]
        }
    }
}
