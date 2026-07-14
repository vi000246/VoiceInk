import Foundation
import SwiftData
import Accelerate

/// 檢索範圍前置過濾。nil 欄位＝不限制。
/// 注意：`categoryId` / `categoryName` / `dateRange` 三個 facet 是轉錄的屬性，
/// obsidian 筆記塊一律豁免（見 `RetrievalService` 的 facet 豁免規則）。
struct AskAIScope: Equatable {
    var sources: Set<String>?              // "dictation" / "recorder" / "meeting" / "obsidian"
    /// 筆記塊豁免（筆記沒有分類）。
    var categoryId: UUID?
    /// 依分類/ tag 名稱過濾（統一：錄音用 recorderCategoryName、語音用 manualTag = displayTag）。
    /// 以 query 時的 live displayTag 比對，免重建索引。nil = 不限。筆記塊豁免。
    var categoryName: String?
    /// 筆記塊豁免（筆記的 timestamp 只是檔案 mtime，不是內容的時間軸）。
    var dateRange: ClosedRange<Date>?
    /// 限定單一錄音／逐字稿（管理頁「Ask AI」單檔提問）;nil = 全庫。
    var transcriptionId: UUID?

    static let all = AskAIScope()
}

struct ScoredChunk: Equatable {
    let chunk: EmbeddingChunk
    let score: Float
    static func == (l: ScoredChunk, r: ScoredChunk) -> Bool {
        l.chunk.transcriptionId == r.chunk.transcriptionId
            && l.chunk.chunkIndex == r.chunk.chunkIndex && l.score == r.score
    }
}

/// 個人規模的暴力檢索:scope 預過濾 → vDSP dot product(向量已 L2-normalized,dot ≡ cosine)
/// → top-k。50k×768 ≈150MB、單查 ≪100ms,不需 ANN。
///
/// **Facet 豁免規則(domain)**:分類(category)與日期(date)是「轉錄的屬性」——錄音有分類、
/// 逐字稿有時間軸。Obsidian 筆記塊兩者都沒有(categoryId 永遠 nil、timestamp 只是檔案 mtime),
/// 所以這兩個 facet 一律**豁免筆記塊**:選了「面試」分類或「近 7 天」,不該把筆記整批誤殺。
/// 反之 `sources` 不豁免——它就是 scope 本體(筆記 chip 關掉就是不要筆記);單檔限定
/// `transcriptionId` 也不豁免(筆記本來就不屬於任何一則轉錄)。
@MainActor
enum RetrievalService {

    /// 取回 scope 內、與 queryVector 最相似的 k 個塊(僅比對同一 embedding 模型的向量——
    /// 不同向量空間永不混比)。
    static func retrieve(queryVector: [Float], scope: AskAIScope, k: Int,
                         model: EmbeddingModel, context: ModelContext) -> [ScoredChunk] {
        let modelTag = model.tag
        // #Predicate 只留唯一「對所有塊都成立」的條件:embeddingModel(String ==)。
        // 日期也移到記憶體:一來筆記塊要豁免(SQL 側做不到「豁免」而不寫成 optional 判斷),
        // 二來 nested `??`/optional 檢查會讓 SwiftData 的 #Predicate 型別檢查爆炸。
        // 其餘 facet 同樣在記憶體內套用(個人規模、fetch 後 filter 成本可忽略)。
        var descriptor = FetchDescriptor<EmbeddingChunk>()
        descriptor.predicate = #Predicate<EmbeddingChunk> { chunk in
            chunk.embeddingModel == modelTag
        }
        var candidates = (try? context.fetch(descriptor)) ?? []
        let noteKind = ObsidianNoteIndexService.sourceKind
        // 單檔限定最先套用（最強的縮小）;in-memory 避開 optional-UUID 進 #Predicate 的型別檢查爆炸。
        // 不豁免筆記：單檔提問問的就是那一則轉錄。
        if let tid = scope.transcriptionId {
            candidates = candidates.filter { $0.transcriptionId == tid }
        }
        // 不豁免:sources 是 scope 本體。
        if let sources = scope.sources {
            candidates = candidates.filter { sources.contains($0.sourceKind) }
        }
        if let dateRange = scope.dateRange {
            candidates = candidates.filter { $0.sourceKind == noteKind || dateRange.contains($0.timestamp) }
        }
        if let categoryId = scope.categoryId {
            candidates = candidates.filter { $0.sourceKind == noteKind || $0.categoryId == categoryId }
        }
        // 依名稱過濾：用 live Transcription 的 displayTag（錄音分類名 or 語音手動 tag）比對，
        // 不依賴索引裡的欄位，故新加/改的 tag 立即生效、免重建索引。
        if let categoryName = scope.categoryName {
            let all = (try? context.fetch(FetchDescriptor<Transcription>())) ?? []
            let tagById = Dictionary(all.map { ($0.id, $0.displayTag) }, uniquingKeysWith: { a, _ in a })
            candidates = candidates.filter { $0.sourceKind == noteKind || tagById[$0.transcriptionId] == categoryName }
        }
        guard !candidates.isEmpty else { return [] }

        let dims = queryVector.count
        var scored: [ScoredChunk] = []
        scored.reserveCapacity(candidates.count)
        for chunk in candidates {
            let v = EmbeddingClient.dataToFloats(chunk.vector)
            guard v.count == dims else { continue }   // 維度不符(理論上同模型不會)→ 跳過
            var dot: Float = 0
            vDSP_dotpr(queryVector, 1, v, 1, &dot, vDSP_Length(dims))
            scored.append(ScoredChunk(chunk: chunk, score: dot))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(k))
    }
}
