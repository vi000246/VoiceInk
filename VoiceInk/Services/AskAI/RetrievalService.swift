import Foundation
import SwiftData
import Accelerate

/// 檢索範圍前置過濾。nil 欄位＝不限制。
struct AskAIScope: Equatable {
    var sources: Set<String>?              // "dictation" / "recorder" / "meeting"
    var categoryId: UUID?
    /// 依分類/ tag 名稱過濾（統一：錄音用 recorderCategoryName、語音用 manualTag = displayTag）。
    /// 以 query 時的 live displayTag 比對，免重建索引。nil = 不限。
    var categoryName: String?
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
@MainActor
enum RetrievalService {

    /// 取回 scope 內、與 queryVector 最相似的 k 個塊(僅比對同一 embedding 模型的向量——
    /// 不同向量空間永不混比)。
    static func retrieve(queryVector: [Float], scope: AskAIScope, k: Int,
                         model: EmbeddingModel, context: ModelContext) -> [ScoredChunk] {
        let modelTag = model.tag
        // 只把「一定適用」的兩個條件壓進 #Predicate:embeddingModel(String ==)與日期範圍
        // (用 distantPast/Future 當預設,避免 optional 進 predicate)。nested `??`/optional 檢查會
        // 讓 SwiftData 的 #Predicate 型別檢查爆炸,故 sources / categoryId 一律在記憶體內套用
        // (個人規模、fetch 後 filter 成本可忽略)。
        let lower = scope.dateRange?.lowerBound ?? Date.distantPast
        let upper = scope.dateRange?.upperBound ?? Date.distantFuture
        var descriptor = FetchDescriptor<EmbeddingChunk>()
        descriptor.predicate = #Predicate<EmbeddingChunk> { chunk in
            chunk.embeddingModel == modelTag
                && chunk.timestamp >= lower
                && chunk.timestamp <= upper
        }
        var candidates = (try? context.fetch(descriptor)) ?? []
        // 單檔限定最先套用（最強的縮小）;in-memory 避開 optional-UUID 進 #Predicate 的型別檢查爆炸。
        if let tid = scope.transcriptionId {
            candidates = candidates.filter { $0.transcriptionId == tid }
        }
        if let sources = scope.sources {
            candidates = candidates.filter { sources.contains($0.sourceKind) }
        }
        if let categoryId = scope.categoryId {
            candidates = candidates.filter { $0.categoryId == categoryId }
        }
        // 依名稱過濾：用 live Transcription 的 displayTag（錄音分類名 or 語音手動 tag）比對，
        // 不依賴索引裡的欄位，故新加/改的 tag 立即生效、免重建索引。
        if let categoryName = scope.categoryName {
            let all = (try? context.fetch(FetchDescriptor<Transcription>())) ?? []
            let tagById = Dictionary(all.map { ($0.id, $0.displayTag) }, uniquingKeysWith: { a, _ in a })
            candidates = candidates.filter { tagById[$0.transcriptionId] == categoryName }
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
