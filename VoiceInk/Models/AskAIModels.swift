import Foundation
import SwiftData

// MARK: - Ask AI 索引與對話模型(全部存放於獨立的第 4 個 store `index.store`,cloudKitDatabase .none)
// 索引是衍生資料:砍掉 index.store 只失去可重建的向量,核心資料零風險。

/// 一段轉錄文字的向量索引單位。身分鍵 = (transcriptionId, chunkIndex) → 冪等 upsert。
@Model
final class EmbeddingChunk {
    // transcriptionId: 刪除傳播與 upsert 取代;timestamp: 日期範圍 scope 過濾。
    #Index<EmbeddingChunk>([\.transcriptionId], [\.timestamp])

    var transcriptionId: UUID = UUID()
    var chunkIndex: Int = 0
    var text: String = ""
    /// Float32 little-endian、L2-normalized(cosine ≡ dot)。維度見 `dims`。
    var vector: Data = Data()
    var dims: Int = 0
    /// 產生此向量的 embedding 模型標籤。不同模型的向量空間互不相容——查詢時強制檢查,
    /// 換模型＝全量重嵌。
    var embeddingModel: String = ""
    /// "dictation" | "recorder" | "meeting" | "obsidian"(反正規化,供 scope 過濾)。
    var sourceKind: String = ""
    var categoryId: UUID?
    var timestamp: Date = Date()
    /// 出處(目前只有 obsidian 塊會填):筆記標題與 vault 相對路徑。
    /// 轉錄塊的出處查得到 `Transcription`(靠 transcriptionId),筆記塊沒有那張表——所以
    /// 反正規化存在塊上,引用 UI 才能顯示「《標題》」並開啟 `obsidian://` 連結。
    /// optional + 預設 nil = SwiftData lightweight migration 安全(舊 store 的塊自動是 nil)。
    var sourceTitle: String?
    var sourcePath: String?

    init(transcriptionId: UUID, chunkIndex: Int, text: String, vector: Data, dims: Int,
         embeddingModel: String, sourceKind: String, categoryId: UUID?, timestamp: Date,
         sourceTitle: String? = nil, sourcePath: String? = nil) {
        self.transcriptionId = transcriptionId
        self.chunkIndex = chunkIndex
        self.text = text
        self.vector = vector
        self.dims = dims
        self.embeddingModel = embeddingModel
        self.sourceKind = sourceKind
        self.categoryId = categoryId
        self.timestamp = timestamp
        self.sourceTitle = sourceTitle
        self.sourcePath = sourcePath
    }
}

/// Ask AI 的持久對話串(與聽寫 Assistant 的暫態 session 是不同職責:庫問答是可回顧的資產)。
@Model
final class AskAIThread {
    var title: String = ""
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \AskAIMessage.thread)
    var messages: [AskAIMessage]? = []

    init(title: String, createdAt: Date = Date()) {
        self.title = title
        self.createdAt = createdAt
    }
}

/// 對話中的一則訊息;assistant 訊息帶引用(JSON-in-raw-field,鏡射 Transcription 的
/// audioChunkPathsRaw 存取器模式)。
@Model
final class AskAIMessage {
    var thread: AskAIThread?
    var role: String = ""          // "user" | "assistant"
    var text: String = ""
    var citationsRaw: String?      // JSON [ChunkRef];nil = 無引用
    var createdAt: Date = Date()

    init(thread: AskAIThread?, role: String, text: String, citationsRaw: String? = nil,
         createdAt: Date = Date()) {
        self.thread = thread
        self.role = role
        self.text = text
        self.citationsRaw = citationsRaw
        self.createdAt = createdAt
    }

    var citations: [ChunkRef] {
        get {
            guard let citationsRaw, let data = citationsRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([ChunkRef].self, from: data) else { return [] }
            return decoded
        }
        set {
            citationsRaw = newValue.isEmpty
                ? nil
                : (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}

/// 回答中 [n] 引用指向的檢索塊參照(可點開原始逐字稿)。
struct ChunkRef: Codable, Equatable {
    var transcriptionId: UUID
    var chunkIndex: Int
    var excerpt: String
}

/// Ask AI 分析角色範本(persona)。問答時可選一個 → 把 persona 段注入 system prompt(引用規則段固定保留)。
/// 存於同一個 index.store（衍生設定，非核心資料）。
@Model
final class AskAITemplate {
    var id: UUID = UUID()
    var title: String = ""
    /// persona 指示（例如「你是資深面試官，聚焦候選人的溝通與臨場反應」）。
    var systemPrompt: String = ""
    var createdAt: Date = Date()

    init(id: UUID = UUID(), title: String, systemPrompt: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
    }
}
