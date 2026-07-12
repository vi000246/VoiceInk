import Foundation

/// Tier 0(FR-13):領域標籤 + 關鍵字,**完全不呼叫 LLM**(< 0.5s)。
///
/// 任何 LLM 往返都不可能穩定低於 0.5s——所以用手寫領域關鍵字種子表做本機命中。
/// (Open Question:未來可加 `EmbeddingChunk` 相似度補強;M3 先種子表。)
/// 純函式 namespace,房子風格鏡射 `MeetingChannelSplitter`。
enum Tier0Classifier {

    /// 後端系統設計 / 演算法領域的種子表:領域標籤 → 觸發詞(小寫;中英混合)。
    /// 命中詞同時作為 Tier 0 回傳的關鍵字。
    static let domainKeywords: [(label: String, terms: [String])] = [
        ("系統設計", ["系統設計", "架構", "scalab", "擴展", "分散式", "microservice", "微服務",
                     "load balanc", "負載", "api", "gateway", "cap", "一致性", "consistency",
                     "availab", "可用", "高可用", "sla", "throughput", "吞吐", "latency", "延遲"]),
        ("資料庫", ["資料庫", "database", "sql", "nosql", "postgres", "mysql", "mongo", "redis",
                   "index", "索引", "shard", "分片", "分庫", "分表", "replica", "副本", "transaction",
                   "交易", "acid", "schema", "正規化", "查詢", "query"]),
        ("快取", ["快取", "cache", "redis", "memcached", "cdn", "失效", "invalidat", "命中率",
                 "hit rate", "eviction", "ttl"]),
        ("訊息佇列", ["佇列", "queue", "kafka", "rabbitmq", "mq", "pub/sub", "訂閱", "消費者",
                     "producer", "consumer", "事件", "event", "串流", "stream"]),
        ("並發", ["並發", "concurren", "併發", "thread", "執行緒", "lock", "鎖", "race",
                 "競爭", "deadlock", "死鎖", "atomic", "原子", "mutex", "async", "非同步"]),
        ("演算法", ["演算法", "algorithm", "複雜度", "complexity", "big o", "o(n", "時間複雜",
                   "空間複雜", "排序", "sort", "搜尋", "search", "遞迴", "recursion", "動態規劃",
                   "dynamic programming", "dp", "貪婪", "greedy", "圖", "graph", "tree", "hash",
                   "雜湊", "堆疊", "stack", "佇列"]),
        ("網路", ["http", "tcp", "udp", "grpc", "rest", "websocket", "dns", "tls", "restful",
                 "protocol", "協定"]),
        ("可靠性", ["容錯", "fault", "重試", "retry", "冪等", "idempoten", "circuit breaker",
                   "熔斷", "降級", "fallback", "監控", "monitor", "observability", "可觀測"]),
        ("安全", ["安全", "security", "auth", "認證", "授權", "oauth", "jwt", "加密", "encrypt",
                 "xss", "sql injection", "注入", "csrf", "rate limit", "限流"]),
    ]

    /// 分類 cue → 領域標籤 + 命中的關鍵字。純函式,零 I/O、零 LLM。
    static func classify(cueText: String) -> Tier0Result {
        let lowered = cueText.lowercased()
        var bestLabel = ""
        var bestHits: [String] = []
        var bestScore = 0

        for (label, terms) in domainKeywords {
            let hits = terms.filter { lowered.contains($0) }
            if hits.count > bestScore {
                bestScore = hits.count
                bestLabel = label
                bestHits = hits
            }
        }

        guard bestScore > 0 else {
            // 無命中:給一個通用標籤 + 從原句抽 2-3 個較長的詞當關鍵字提示。
            let fallback = cueText
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .map(String.init)
                .filter { $0.count >= 2 }
                .prefix(3)
            return Tier0Result(domainLabel: "一般", keywords: Array(fallback))
        }

        // 關鍵字去重、取前 3 個最具代表性(較長者優先)。
        let keywords = Array(Set(bestHits)).sorted { $0.count > $1.count }.prefix(3)
        return Tier0Result(domainLabel: bestLabel, keywords: Array(keywords))
    }
}
