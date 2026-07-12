import XCTest
import LLMkit
@testable import VoiceInk

/// 用 URLProtocol 注入假 SSE 回應,完全不出網路。
final class StreamingChatClientTests: XCTestCase {

    override func setUp() { MockSSEProtocol.reset() }

    /// AC-11:OpenAI-compat parser 依序吐出 3 段 delta,[DONE] 終止。
    func testOpenAIParserEmitsDeltasInOrder() async throws {
        MockSSEProtocol.body = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"嗎\"}}]}",
            "data: [DONE]",
        ].joined(separator: "\n\n") + "\n\n"

        let session = MockSSEProtocol.makeSession()
        var deltas: [String] = []
        let stream = StreamingChatClient.streamOpenAI(
            baseURL: URL(string: "https://mock.local/v1/chat/completions")!,
            apiKey: "k", model: "m", messages: [.user("hi")],
            systemPrompt: nil, temperature: 0.3, reasoningEffort: nil, extraBody: nil,
            timeout: 5, session: session)
        for try await d in stream { deltas.append(d) }
        XCTAssertEqual(deltas, ["你", "好", "嗎"])
    }

    /// 非 2xx → throw .http(status, body),未吐任何 delta。
    func testHTTPErrorThrowsBeforeDeltas() async {
        MockSSEProtocol.status = 500
        MockSSEProtocol.body = "upstream boom"
        let session = MockSSEProtocol.makeSession()
        let stream = StreamingChatClient.streamOpenAI(
            baseURL: URL(string: "https://mock.local/v1/chat/completions")!,
            apiKey: "k", model: "m", messages: [.user("hi")],
            systemPrompt: nil, temperature: 0.3, reasoningEffort: nil, extraBody: nil,
            timeout: 5, session: session)
        do {
            for try await _ in stream { XCTFail("不該吐 delta") }
            XCTFail("應 throw")
        } catch let StreamingChatError.http(code, body) {
            XCTAssertEqual(code, 500); XCTAssertTrue(body.contains("boom"))
        } catch { XCTFail("錯誤型別: \(error)") }
    }

    func testMissingKeyThrows() async {
        let stream = StreamingChatClient.streamOpenAI(
            baseURL: URL(string: "https://mock.local/x")!, apiKey: "", model: "m",
            messages: [.user("hi")], systemPrompt: nil, temperature: 0.3,
            reasoningEffort: nil, extraBody: nil, timeout: 5, session: .shared)
        do { for try await _ in stream {}; XCTFail("應 throw") }
        catch StreamingChatError.missingAPIKey {} catch { XCTFail("錯誤型別") }
    }

    /// AC-12:Anthropic parser 依序吐 text_delta,message_stop 終止;header 為 x-api-key(非 Bearer)。
    func testAnthropicParserEmitsTextDeltasAndTerminatesOnMessageStop() async throws {
        MockSSEProtocol.body = [
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"分\"}}",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"片\"}}",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
        ].joined(separator: "\n") + "\n\n"
        let session = MockSSEProtocol.makeSession()
        var deltas: [String] = []
        let stream = StreamingChatClient.streamAnthropic(
            apiKey: "k", model: "claude-x", messages: [.user("hi")], systemPrompt: "你是專家",
            maxTokens: 1024, timeout: 5, session: session)
        for try await d in stream { deltas.append(d) }
        XCTAssertEqual(deltas, ["分", "片"])
        XCTAssertEqual(MockSSEProtocol.lastHeaders["x-api-key"], "k")
        XCTAssertEqual(MockSSEProtocol.lastHeaders["anthropic-version"], "2023-06-01")
        XCTAssertNil(MockSSEProtocol.lastHeaders["Authorization"])
    }
}

/// 最小 URLProtocol:把 body 當成一個「完整回應」回放(bytes(for:) 會逐行讀)。
final class MockSSEProtocol: URLProtocol {
    static var body = ""
    static var status = 200
    static var lastHeaders: [String: String] = [:]
    static func reset() { body = ""; status = 200; lastHeaders = [:] }
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockSSEProtocol.self]
        return URLSession(configuration: cfg)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastHeaders = request.allHTTPHeaderFields ?? [:]
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
