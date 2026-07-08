import XCTest
@testable import VoiceInk

final class AskAIEmbeddingTests: XCTestCase {

    func testGeminiPayloadShape() throws {
        let data = EmbeddingClient.encodeGeminiRequest(texts: ["hello", "世界"], model: .gemini001_768)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let requests = json?["requests"] as? [[String: Any]]
        XCTAssertEqual(requests?.count, 2)
        XCTAssertEqual(requests?[0]["outputDimensionality"] as? Int, 768)
        XCTAssertEqual(requests?[0]["model"] as? String, "models/gemini-embedding-001")
        let content = requests?[0]["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?[0]["text"] as? String, "hello")
    }

    func testOpenAIPayloadShape() throws {
        let data = EmbeddingClient.encodeOpenAIRequest(texts: ["a", "b", "c"], model: .openaiSmall1536)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "text-embedding-3-small")
        XCTAssertEqual(json?["dimensions"] as? Int, 1536)
        XCTAssertEqual((json?["input"] as? [String])?.count, 3)
    }

    func testParseGeminiNormalizes() throws {
        let response = """
        {"embeddings":[{"values":[3.0,4.0]},{"values":[0.0,0.0]}]}
        """.data(using: .utf8)!
        let vectors = try EmbeddingClient.parseGemini(response)
        XCTAssertEqual(vectors.count, 2)
        // [3,4] → /5 → [0.6, 0.8]
        XCTAssertEqual(vectors[0][0], 0.6, accuracy: 1e-5)
        XCTAssertEqual(vectors[0][1], 0.8, accuracy: 1e-5)
        // 零向量原樣。
        XCTAssertEqual(vectors[1], [0.0, 0.0])
    }

    func testParseOpenAIRespectsIndexOrder() throws {
        let response = """
        {"data":[{"embedding":[1.0,0.0],"index":1},{"embedding":[0.0,1.0],"index":0}]}
        """.data(using: .utf8)!
        let vectors = try EmbeddingClient.parseOpenAI(response)
        // index 0 應排在前 → [0,1]
        XCTAssertEqual(vectors[0], [0.0, 1.0])
        XCTAssertEqual(vectors[1], [1.0, 0.0])
    }

    func testNormalizeUnitLength() {
        let n = EmbeddingClient.normalize([1, 2, 2])   // |v| = 3
        let magnitude = sqrt(n.map { $0 * $0 }.reduce(0, +))
        XCTAssertEqual(magnitude, 1.0, accuracy: 1e-5)
    }

    func testVectorDataRoundtrip() {
        let original: [Float] = [0.1, -0.5, 3.14159, 0.0, 42.0]
        let data = EmbeddingClient.floatsToData(original)
        XCTAssertEqual(data.count, original.count * 4)
        let restored = EmbeddingClient.dataToFloats(data)
        XCTAssertEqual(restored.count, original.count)
        for (a, b) in zip(original, restored) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }
}
