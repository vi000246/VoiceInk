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

    /// 全部四種來源（**含**筆記）。
    ///
    /// 🔴 這裡必須是明確集合，不能是 `AskAIScope()`（= `sources: nil` = 檢索層完全跳過
    /// sourceKind 過濾）。`AskAISourceFilter.all` 就是因為回 nil 而讓筆記塊漏進 Ask AI 的預設
    /// 查詢——那個漏洞已修，但如果這裡留一個同名的「不過濾」常數，任何呼叫點採用它就是第二條
    /// 路重現同一個 bug。nil 仍是型別上合法的值（單檔提問等路徑用得到），但**不再有現成的入口**。
    static let all = AskAIScope(sources: ["dictation", "recorder", "meeting",
                                          ObsidianNoteIndexService.sourceKind])
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
    /// - Parameter minScore: cosine 相似度下限(向量已 L2-normalize,dot = cosine ∈ [-1,1])。
    ///   低於此值的塊視為「不相關」而剔除。預設 0 = 不設限(向下相容)。碎片/離題 query
    ///   在純 top-k 下仍會硬撈回 k 個不相關塊(2026-07-15 aboutMe 亂接地事故),給下限才擋得住。
    static func retrieve(queryVector: [Float], scope: AskAIScope, k: Int,
                         model: EmbeddingModel, context: ModelContext,
                         minScore: Float = 0) -> [ScoredChunk] {
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
        let relevant = minScore > 0 ? scored.filter { $0.score >= minScore } : scored
        let ranked = relevant.sorted { $0.score > $1.score }
        return Array(ranked.prefix(k))
    }

    // MARK: - 多查詢召回(max-score fusion)

    /// 把多組檢索結果以 **chunk 身分**(`transcriptionId#chunkIndex`,同 `ScoredChunk ==`)取聯集,
    /// 同一段保留**最高分**,重排取前 k。多查詢/同義詞檢索共用:一段只要**強配上任一查詢變體**
    /// 就能浮上來(問「山」漏掉、但「百岳」變體撈到 → 以高分擠進前 k)。純函式(不碰索引)。
    static func fuseByMaxScore(_ groups: [[ScoredChunk]], k: Int) -> [ScoredChunk] {
        var bestByKey: [String: ScoredChunk] = [:]
        for group in groups {
            for sc in group {
                let key = "\(sc.chunk.transcriptionId)#\(sc.chunk.chunkIndex)"
                if let existing = bestByKey[key], existing.score >= sc.score { continue }
                bestByKey[key] = sc
            }
        }
        return Array(bestByKey.values.sorted { $0.score > $1.score }.prefix(k))
    }

    /// 多個查詢向量各自 top-k 檢索後 fuse。單一向量 → 等同 `retrieve`(零額外成本)。
    static func retrieveUnion(queryVectors: [[Float]], scope: AskAIScope, k: Int,
                              model: EmbeddingModel, context: ModelContext, minScore: Float = 0) -> [ScoredChunk] {
        guard queryVectors.count > 1 else {
            guard let v = queryVectors.first else { return [] }
            return retrieve(queryVector: v, scope: scope, k: k, model: model, context: context, minScore: minScore)
        }
        let groups = queryVectors.map {
            retrieve(queryVector: $0, scope: scope, k: k, model: model, context: context, minScore: minScore)
        }
        return fuseByMaxScore(groups, k: k)
    }
}
