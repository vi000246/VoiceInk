import Foundation
import LLMkit

/// In-repo 非串流 chat client(OpenAI-compat + Anthropic),回傳文字**與 usage**。
///
/// 存在理由(照 `StreamingChatClient` 先例):LLMkit 是遠端不可編輯的 SPM 套件,其
/// `OpenAILLMClient`/`AnthropicLLMClient` 只回 content 字串、response struct 全 private,
/// 拿不到 usage(prompt/completion tokens)——AI 用量統計(`AIUsageEvent`)需要供應商
/// 回報的真實數字,估算只是退路。
///
/// 請求格式、429/5xx 退避重試、錯誤語意**鏡射 LLMkit**(丟同一個 `LLMKitError`),
/// 呼叫端既有的錯誤處理(如 `AIEnhancementService.mapLLMKitError`)完全不用改。
enum ChatCompletionClient {

    struct Completion {
        let text: String
        /// 供應商回報的 usage;沒回(或解析不到)= nil,由呼叫端決定要不要估算。
        let usage: ChatUsage?
    }

    // MARK: - OpenAI-compat(/v1/chat/completions)

    static func completeOpenAI(
        baseURL: URL,
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        temperature: Double = 0.3,
        reasoningEffort: String? = nil,
        extraBody: [String: Any]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Completion {
        try validateKey(apiKey)

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var allMessages = messages
        if let systemPrompt, !systemPrompt.isEmpty {
            allMessages.insert(.system(systemPrompt), at: 0)
        }

        var bodyDict: [String: Any] = [
            "model": model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "stream": false
        ]
        if let reasoningEffort {
            bodyDict["reasoning_effort"] = reasoningEffort
        }
        if let extraBody {
            for (key, value) in extraBody {
                bodyDict[key] = value
            }
        }

        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            throw LLMKitError.encodingError
        }
        request.httpBody = body

        let (data, response) = try await performWithRetry(request, timeout: timeout)
        try validateStatus(response, data: data)
        return try parseOpenAI(data)
    }

    /// OpenAI-compat 回應解析(pure,可測)。content 缺 choices → decodingError,鏡射 LLMkit。
    static func parseOpenAI(_ data: Data) throws -> Completion {
        struct Usage: Decodable { let prompt_tokens: Int?; let completion_tokens: Int? }
        struct Message: Decodable { let content: String? }
        struct Choice: Decodable { let message: Message? }
        struct Response: Decodable { let choices: [Choice]; let usage: Usage? }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LLMKitError.decodingError(error.localizedDescription)
        }
        let usage = decoded.usage.map {
            ChatUsage(inputTokens: $0.prompt_tokens ?? 0, outputTokens: $0.completion_tokens ?? 0)
        }
        return Completion(text: decoded.choices.first?.message?.content ?? "", usage: usage)
    }

    // MARK: - Anthropic(/v1/messages)

    static func completeAnthropic(
        apiKey: String,
        model: String,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        maxTokens: Int = 8192,
        timeout: TimeInterval = 30
    ) async throws -> Completion {
        try validateKey(apiKey)

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // system 抽出為 top-level 欄位:顯式參數優先,否則彙整 messages 裡的 system role。
        let system: String?
        if let systemPrompt, !systemPrompt.isEmpty {
            system = systemPrompt
        } else {
            let joined = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
            system = joined.isEmpty ? nil : joined
        }
        let nonSystem = messages.filter { $0.role != "system" }

        var bodyDict: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": nonSystem.map { ["role": $0.role, "content": $0.content] },
        ]
        if let system { bodyDict["system"] = system }

        guard let body = try? JSONSerialization.data(withJSONObject: bodyDict) else {
            throw LLMKitError.encodingError
        }
        request.httpBody = body

        let (data, response) = try await performWithRetry(request, timeout: timeout)
        try validateStatus(response, data: data)
        return try parseAnthropic(data)
    }

    /// Anthropic 回應解析(pure,可測)。
    static func parseAnthropic(_ data: Data) throws -> Completion {
        struct Usage: Decodable { let input_tokens: Int?; let output_tokens: Int? }
        struct Block: Decodable { let type: String; let text: String? }
        struct Response: Decodable { let content: [Block]; let usage: Usage? }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw LLMKitError.decodingError(error.localizedDescription)
        }
        let usage = decoded.usage.map {
            ChatUsage(inputTokens: $0.input_tokens ?? 0, outputTokens: $0.output_tokens ?? 0)
        }
        return Completion(text: decoded.content.first { $0.type == "text" }?.text ?? "", usage: usage)
    }

    // MARK: - 傳輸層(鏡射 LLMkit HTTPClient.performRequest / validateHTTPResponse)

    private static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    private static func validateKey(_ apiKey: String) throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMKitError.missingAPIKey
        }
    }

    private static func validateStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMKitError.networkError("No HTTP response received.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "No error details"
            throw LLMKitError.httpError(statusCode: http.statusCode, message: message)
        }
    }

    /// 429/5xx 與網路錯誤指數退避重試(1s、2s,共 3 次嘗試),逾時映射 `LLMKitError.timeout`。
    private static func performWithRetry(
        _ request: URLRequest,
        timeout: TimeInterval,
        maxRetries: Int = 2
    ) async throws -> (Data, URLResponse) {
        var req = request
        req.timeoutInterval = timeout
        var lastError: (any Error)?

        for attempt in 0...maxRetries {
            if attempt > 0 {
                let delay = UInt64(pow(2.0, Double(attempt - 1)) * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }

            do {
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse,
                   retryableStatusCodes.contains(http.statusCode),
                   attempt < maxRetries {
                    lastError = LLMKitError.httpError(
                        statusCode: http.statusCode,
                        message: String(data: data, encoding: .utf8) ?? "")
                    continue
                }
                return (data, response)
            } catch let error as LLMKitError {
                throw error
            } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
                throw LLMKitError.timeout
            } catch {
                lastError = error
                if attempt < maxRetries { continue }
            }
        }

        throw lastError ?? LLMKitError.networkError("Request failed after \(maxRetries + 1) attempts")
    }
}
