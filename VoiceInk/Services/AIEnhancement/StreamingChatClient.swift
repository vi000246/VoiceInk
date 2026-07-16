import Foundation
import LLMkit

enum StreamingChatError: Error {
    case missingAPIKey
    case http(Int, String)
    case emptyResponse
}

/// In-repo SSE streaming chat client。兩 parser:OpenAI-compat 與 Anthropic。
///
/// 存在理由(照 `ElevenLabsDiarizingClient` 先例):LLMkit 是遠端不可編輯的 SPM 套件,其
/// `OpenAILLMClient`/`AnthropicLLMClient` 的 body 寫死 `"stream": false`,且 request/response
/// struct 全 private。SSE 需 `URLSession.bytes(for:)`,**先檢查 HTTP status 再消費 byte stream**。
///
/// 兩種線格式完全不同(canon §3.3):
/// - OpenAI-compat:`data: {json}` 行,delta 在 `choices[0].delta.content`,終止 `data: [DONE]`,auth `Bearer`。
/// - Anthropic:`event:<type>` + `data:` 成對,text 在 `delta.text`(type==text_delta),終止 `message_stop`,
///   auth `x-api-key` + `anthropic-version`,system 為 top-level 欄位。
enum StreamingChatClient {

    /// 串流專用的 URLSession。
    ///
    /// `req.timeoutInterval`(= `timeoutIntervalForRequest`)只是**閒置**計時器:每收到一個 byte 就
    /// 重置,所以死連線會在 timeout 秒後斷,但**行為異常的伺服器持續 dribble 無內容的 SSE 心跳行**
    /// 會不斷重置它 → 永不逾時。手動深答走 `await task.value`,一旦卡在這種 dribble,overlay 的
    /// 「深度分析中…」會無上限空轉。`timeoutIntervalForResource` 是**整個請求**的 wall-clock 上限,
    /// 不會被 byte 重置——設它才封得住這個洞。`.shared` 的預設是 7 天,等於沒有上限。
    ///
    /// 180s:遠比正常深答(十餘秒)寬鬆,只砍真正掛住的請求;不學 AI-overlay 那種 60s 硬砍
    /// (會誤殺慢但有進度的長回應)。
    static let pooledSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 180
        return URLSession(configuration: cfg)
    }()

    // MARK: - OpenAI-compat(data: {json} + [DONE])

    private struct OpenAIChunk: Decodable {
        struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta? }
        let choices: [Choice]?
    }

    static func streamOpenAI(
        baseURL: URL, apiKey: String, model: String, messages: [ChatMessage],
        systemPrompt: String?, temperature: Double, reasoningEffort: String?,
        extraBody: [String: Any]?, images: [Data] = [], timeout: TimeInterval,
        session: URLSession = StreamingChatClient.pooledSession
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw StreamingChatError.missingAPIKey }
                    var req = URLRequest(url: baseURL)
                    req.httpMethod = "POST"
                    req.timeoutInterval = timeout
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    var all = messages
                    if let systemPrompt, !systemPrompt.isEmpty { all.insert(.system(systemPrompt), at: 0) }
                    var body: [String: Any] = [
                        "model": model,
                        "messages": Self.openAIMessages(all, images: images),
                        "temperature": temperature,
                        "stream": true,
                    ]
                    if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
                    if let extraBody { for (k, v) in extraBody { body[k] = v } }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: req)
                    try await Self.checkStatus(response, bytes: bytes)

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OpenAIChunk.self, from: data),
                              let piece = chunk.choices?.first?.delta?.content, !piece.isEmpty
                        else { continue }
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Anthropic(event:<type> + data: / message_stop)

    private struct AnthropicChunk: Decodable {
        struct Delta: Decodable { let type: String?; let text: String? }
        let type: String?
        let delta: Delta?
    }

    static func streamAnthropic(
        apiKey: String, model: String, messages: [ChatMessage], systemPrompt: String?,
        maxTokens: Int, images: [Data] = [], timeout: TimeInterval,
        session: URLSession = StreamingChatClient.pooledSession
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw StreamingChatError.missingAPIKey }
                    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = timeout
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    // system 拆成 top-level;messages 濾掉 system role
                    let sys: String?
                    if let systemPrompt, !systemPrompt.isEmpty { sys = systemPrompt }
                    else {
                        let s = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
                        sys = s.isEmpty ? nil : s
                    }
                    let nonSystem = messages.filter { $0.role != "system" }
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "messages": Self.anthropicMessages(nonSystem, images: images),
                        "stream": true,
                    ]
                    if let sys { body["system"] = sys }   // nil 時省略 key(等價 LLMkit custom encoder)
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: req)
                    try await Self.checkStatus(response, bytes: bytes)

                    for try await line in bytes.lines {
                        // Anthropic:只取 data: 行且 type==content_block_delta / delta.type==text_delta
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(AnthropicChunk.self, from: data)
                        else { continue }
                        if chunk.type == "message_stop" { break }
                        if chunk.type == "content_block_delta",
                           chunk.delta?.type == "text_delta",
                           let text = chunk.delta?.text, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 多模態訊息組裝(截圖深答)

    /// OpenAI-compat:圖片以 `image_url` content part 併進**最後一則 user 訊息**。
    /// 無圖時退化成原本的 `content: String`(行為完全不變)。
    private static func openAIMessages(_ messages: [ChatMessage], images: [Data]) -> [[String: Any]] {
        var arr: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.content] }
        guard !images.isEmpty,
              let idx = arr.lastIndex(where: { ($0["role"] as? String) == "user" }) else { return arr }
        let text = (arr[idx]["content"] as? String) ?? ""
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for img in images {
            parts.append(["type": "image_url",
                          "image_url": ["url": "data:image/jpeg;base64,\(img.base64EncodedString())"]])
        }
        arr[idx]["content"] = parts
        return arr
    }

    /// Anthropic:圖片以 `image`/`source.base64` content part 併進最後一則 user 訊息。
    private static func anthropicMessages(_ messages: [ChatMessage], images: [Data]) -> [[String: Any]] {
        var arr: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.content] }
        guard !images.isEmpty,
              let idx = arr.lastIndex(where: { ($0["role"] as? String) == "user" }) else { return arr }
        let text = (arr[idx]["content"] as? String) ?? ""
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for img in images {
            parts.append(["type": "image",
                          "source": ["type": "base64", "media_type": "image/jpeg",
                                     "data": img.base64EncodedString()]])
        }
        arr[idx]["content"] = parts
        return arr
    }

    // MARK: - Shared

    /// 消費 byte stream **之前**先檢查 HTTP status(照 ElevenLabsDiarizingClient:578-583)。
    private static func checkStatus(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        // 錯誤時 body 常是小段 JSON,收集起來塞進 .http
        var collected = ""
        for try await line in bytes.lines { collected += line; if collected.count > 2000 { break } }
        throw StreamingChatError.http(http.statusCode, collected)
    }
}
