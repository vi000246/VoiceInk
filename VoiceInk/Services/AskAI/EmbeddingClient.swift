import Foundation
import Accelerate

/// Ask AI 的雲端 embedding 模型(BYOK)。不同模型的向量空間互不相容——`tag` 存進每個
/// EmbeddingChunk,查詢時強制檢查,換模型＝全量重嵌。
enum EmbeddingModel: String, CaseIterable, Codable {
    case gemini001_768          // gemini-embedding-001 @ 768 維(MRL 截斷);免費層 ~1500 req/day
    case openaiSmall1536        // text-embedding-3-small @ 1536 維

    var tag: String { rawValue }
    var dims: Int { self == .gemini001_768 ? 768 : 1536 }
    /// APIKeyManager 的 provider 名(共用既有金鑰條目:geminiAPIKey / openAIAPIKey)。
    var providerName: String { self == .gemini001_768 ? "gemini" : "openai" }
    var displayName: String {
        self == .gemini001_768 ? "Gemini embedding-001（768 維）" : "OpenAI 3-small（1536 維）"
    }
}

enum EmbeddingError: Error, LocalizedError {
    case missingAPIKey(String)
    case http(Int, String)
    case decodeFailed
    case countMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): return "尚未設定 \(p) 的 API 金鑰"
        case .http(let code, let msg): return "Embedding 服務錯誤（\(code)）：\(msg)"
        case .decodeFailed: return "Embedding 回應解析失敗"
        case .countMismatch(let e, let g): return "Embedding 數量不符（預期 \(e)，得到 \(g)）"
        }
    }
}

struct EmbeddingClient {
    /// 單次請求最多的 text 數(批次)。
    static let batchLimit = 100

    // MARK: - Pure payload builders (unit-testable)

    static func encodeGeminiRequest(texts: [String], model: EmbeddingModel) -> Data {
        let modelPath = "models/gemini-embedding-001"
        let requests: [[String: Any]] = texts.map { text in
            [
                "model": modelPath,
                "content": ["parts": [["text": text]]],
                "outputDimensionality": model.dims
            ]
        }
        let body: [String: Any] = ["requests": requests]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func encodeOpenAIRequest(texts: [String], model: EmbeddingModel) -> Data {
        let body: [String: Any] = [
            "model": "text-embedding-3-small",
            "input": texts,
            "dimensions": model.dims
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    // MARK: - Pure parsers (unit-testable) — 皆回傳 L2-normalized 向量

    static func parseGemini(_ data: Data) throws -> [[Float]] {
        struct Response: Decodable { let embeddings: [Embedding]?
            struct Embedding: Decodable { let values: [Double] } }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              let embeddings = r.embeddings else { throw EmbeddingError.decodeFailed }
        return embeddings.map { normalize($0.values.map(Float.init)) }
    }

    static func parseOpenAI(_ data: Data) throws -> [[Float]] {
        struct Response: Decodable { let data: [Item]?
            struct Item: Decodable { let embedding: [Double]; let index: Int } }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              let items = r.data else { throw EmbeddingError.decodeFailed }
        // OpenAI 保證 index 對應輸入順序,但保險起見排序。
        return items.sorted { $0.index < $1.index }.map { normalize($0.embedding.map(Float.init)) }
    }

    // MARK: - Vector helpers

    /// L2 normalize → cosine 相似度可用單純 dot product。零向量原樣回傳。
    static func normalize(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 1e-9 else { return vector }
        var out = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &out, 1, vDSP_Length(vector.count))
        return out
    }

    /// [Float] ↔ Data(Float32 little-endian)。存進 EmbeddingChunk.vector。
    static func floatsToData(_ floats: [Float]) -> Data {
        var le = floats.map { $0.bitPattern.littleEndian }
        return Data(bytes: &le, count: le.count * MemoryLayout<UInt32>.size)
    }

    static func dataToFloats(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<UInt32>.size
        return data.withUnsafeBytes { raw -> [Float] in
            let ptr = raw.bindMemory(to: UInt32.self)
            return (0..<count).map { Float(bitPattern: UInt32(littleEndian: ptr[$0])) }
        }
    }

    // MARK: - Network

    /// 批次嵌入 texts;超過 batchLimit 自動分批。回傳與輸入同序、同長度的向量陣列。
    static func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let apiKey = APIKeyManager.shared.getAPIKey(forProvider: model.providerName),
              !apiKey.isEmpty else { throw EmbeddingError.missingAPIKey(model.providerName) }

        var out: [[Float]] = []
        var start = 0
        while start < texts.count {
            let batch = Array(texts[start..<min(start + batchLimit, texts.count)])
            let vectors = try await embedBatch(batch, model: model, apiKey: apiKey)
            guard vectors.count == batch.count else {
                throw EmbeddingError.countMismatch(expected: batch.count, got: vectors.count)
            }
            out.append(contentsOf: vectors)
            start += batchLimit
        }
        return out
    }

    private static func embedBatch(_ texts: [String], model: EmbeddingModel, apiKey: String) async throws -> [[Float]] {
        var request: URLRequest
        switch model {
        case .gemini001_768:
            let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:batchEmbedContents")!
            request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = encodeGeminiRequest(texts: texts, model: model)
        case .openaiSmall1536:
            let url = URL(string: "https://api.openai.com/v1/embeddings")!
            request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = encodeOpenAIRequest(texts: texts, model: model)
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        // 指數退避:429 / 5xx 最多重試 3 次。
        var lastError = EmbeddingError.decodeFailed
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    return model == .gemini001_768 ? try parseGemini(data) : try parseOpenAI(data)
                }
                if code == 429 || (500...599).contains(code) {
                    lastError = .http(code, String(data: data, encoding: .utf8) ?? "")
                    try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 500_000_000)
                    continue
                }
                throw EmbeddingError.http(code, String(data: data, encoding: .utf8) ?? "")
            } catch let e as EmbeddingError {
                throw e
            } catch {
                lastError = .http(0, error.localizedDescription)
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 500_000_000)
            }
        }
        throw lastError
    }
}
