import Foundation
import LLMkit

/// 串流版可注入 seam(與既有 `ChatCompleting` 並列,AskAIService.swift:6-8)。
protocol StreamingChatCompleting {
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error>
    /// 帶圖片的變體(截圖深答)。有預設實作忽略圖片,所以非視覺 completer 與測試 fake 都免改;
    /// 只有正式的 `LiveStreamingChatCompleter` override 它真的送圖。
    func stream(system: String, user: String, images: [Data]) -> AsyncThrowingStream<String, Error>
}

extension StreamingChatCompleting {
    func stream(system: String, user: String, images: [Data]) -> AsyncThrowingStream<String, Error> {
        stream(system: system, user: user)   // 預設:忽略圖片
    }
}

extension AIService {
    /// `completeChat` 的串流並存版。只做 `.anthropic` 與 default(OpenAI-compat) 兩分支
    /// (`.ollama`/`.localCLI`/`.custom` 的串流不在 M3 範圍)。鏡射 completeChat 的
    /// model/key/reasoning 解析(AIChatCompletionService.swift:4-101)。
    func streamChat(
        provider: AIProvider, modelName: String?, messages: [ChatMessage],
        systemPrompt: String?, images: [Data] = [], timeout: TimeInterval = 60
    ) -> AsyncThrowingStream<String, Error> {
        let resolvedModel = modelName?.isEmpty == false ? modelName! : selectedModel(for: provider)
        // key 解析照抄 chatAPIKey(它是 file-private)。
        func key() throws -> String {
            guard let k = APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue), !k.isEmpty
            else { throw EnhancementError.notConfigured }
            return k
        }
        switch provider {
        case .anthropic:
            return AsyncThrowingStream { c in
                let t = Task {
                    do {
                        let inner = StreamingChatClient.streamAnthropic(
                            apiKey: try key(), model: resolvedModel, messages: messages,
                            systemPrompt: systemPrompt, maxTokens: 4096, images: images, timeout: timeout)
                        for try await d in inner { c.yield(d) }
                        c.finish()
                    } catch { c.finish(throwing: error) }
                }
                c.onTermination = { _ in t.cancel() }
            }
        default:
            return AsyncThrowingStream { c in
                let t = Task {
                    do {
                        guard let baseURL = URL(string: provider.baseURL) else { throw EnhancementError.notConfigured }
                        let temp = resolvedModel.lowercased().hasPrefix("gpt-5") ? 1.0 : 0.3
                        let inner = StreamingChatClient.streamOpenAI(
                            baseURL: baseURL, apiKey: try key(), model: resolvedModel,
                            messages: messages, systemPrompt: systemPrompt, temperature: temp,
                            reasoningEffort: ReasoningConfig.getReasoningParameter(for: provider, modelName: resolvedModel),
                            extraBody: ReasoningConfig.getExtraBodyParameters(for: provider, modelName: resolvedModel),
                            images: images, timeout: timeout)
                        for try await d in inner { c.yield(d) }
                        c.finish()
                    } catch { c.finish(throwing: error) }
                }
                c.onTermination = { _ in t.cancel() }
            }
        }
    }
}

/// 正式 completer:包 streamChat(system+user → messages)。
struct LiveStreamingChatCompleter: StreamingChatCompleting {
    let aiService: AIService
    let provider: AIProvider
    var modelName: String?
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        aiService.streamChat(provider: provider, modelName: modelName,
                             messages: [.user(user)], systemPrompt: system, timeout: 60)
    }

    func stream(system: String, user: String, images: [Data]) -> AsyncThrowingStream<String, Error> {
        aiService.streamChat(provider: provider, modelName: modelName,
                             messages: [.user(user)], systemPrompt: system, images: images, timeout: 60)
    }
}

/// 測試用:腳本化 delta,忽略輸入。
final class FakeStreamingChatCompleting: StreamingChatCompleting, @unchecked Sendable {
    private let script: [String]
    private let error: Error?
    private let lock = NSLock()
    private var _callCount = 0
    private var _lastUser = ""
    private var _lastSystem = ""
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
    var lastUser: String { lock.lock(); defer { lock.unlock() }; return _lastUser }
    var lastSystem: String { lock.lock(); defer { lock.unlock() }; return _lastSystem }

    init(script: [String] = [], error: Error? = nil) { self.script = script; self.error = error }

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        lock.lock(); _callCount += 1; _lastUser = user; _lastSystem = system; lock.unlock()
        let script = self.script; let error = self.error
        return AsyncThrowingStream { c in
            for s in script { c.yield(s) }
            if let error { c.finish(throwing: error) } else { c.finish() }
        }
    }
}
