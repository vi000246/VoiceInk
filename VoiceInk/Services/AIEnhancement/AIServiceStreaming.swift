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

/// 串流期間承接 usage 回報的信箱(`onUsage` 是 @Sendable closure,不能直接寫 Task 區域變數)。
private final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: ChatUsage?
    var value: ChatUsage? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

extension AIService {
    /// 確認支援 `stream_options.include_usage` 的 OpenAI-compat providers。
    /// 不在清單的(Gemini proxy、Mistral、custom…)不送——不支援的家可能把整個請求 4xx 掉;
    /// 它們之中有些(Gemini、Mistral、Groq 的 x_groq)本來就會在最後一個 chunk 自帶 usage,
    /// 解析端一律照收,沒收到就退回估算。
    private static let streamUsageOptionProviders: Set<AIProvider> = [.openAI, .openRouter, .groq, .cerebras]

    /// `completeChat` 的串流並存版。只做 `.anthropic` 與 default(OpenAI-compat) 兩分支
    /// (`.ollama`/`.localCLI`/`.custom` 的串流不在 M3 範圍)。鏡射 completeChat 的
    /// model/key/reasoning 解析(AIChatCompletionService.swift:4-101)。
    ///
    /// - Parameter usageFeature: 用量統計標籤。串流結束(或中途失敗)時落一筆 AIUsageEvent:
    ///   供應商回報的 usage 優先,沒有就以請求＋已收到的輸出估算(標 isEstimated)。
    func streamChat(
        provider: AIProvider, modelName: String?, messages: [ChatMessage],
        systemPrompt: String?, images: [Data] = [], timeout: TimeInterval = 60,
        usageFeature: AIUsageFeature = .other
    ) -> AsyncThrowingStream<String, Error> {
        let resolvedModel = modelName?.isEmpty == false ? modelName! : selectedModel(for: provider)
        // key 解析照抄 chatAPIKey(它是 file-private)。
        func key() throws -> String {
            guard let k = APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue), !k.isEmpty
            else { throw EnhancementError.notConfigured }
            return k
        }

        // 串流結束時落用量:回報優先、退回估算。中途斷線的部分輸出也記——供應商照收費;
        // 整包連線失敗(一個字都沒收到、也沒 usage)不記,避免幫失敗請求灌水。
        let usageBox = UsageBox()
        @Sendable func recordUsage(accumulatedOutput: String, failed: Bool) {
            if let reported = usageBox.value {
                AIUsageRecorder.shared.record(
                    provider: provider.rawValue, model: resolvedModel,
                    feature: usageFeature, usage: reported)
            } else if !failed || !accumulatedOutput.isEmpty {
                AIUsageRecorder.shared.record(
                    provider: provider.rawValue, model: resolvedModel, feature: usageFeature,
                    usage: ChatUsage(
                        inputTokens: TokenEstimator.estimateInput(
                            system: systemPrompt, messages: messages, imageCount: images.count),
                        outputTokens: TokenEstimator.estimate(accumulatedOutput),
                        isEstimated: true))
            }
        }

        switch provider {
        case .anthropic:
            return AsyncThrowingStream { c in
                let t = Task {
                    var accumulated = ""
                    do {
                        let inner = StreamingChatClient.streamAnthropic(
                            apiKey: try key(), model: resolvedModel, messages: messages,
                            systemPrompt: systemPrompt, maxTokens: 4096, images: images, timeout: timeout,
                            onUsage: { usageBox.value = $0 })
                        for try await d in inner { accumulated += d; c.yield(d) }
                        recordUsage(accumulatedOutput: accumulated, failed: false)
                        c.finish()
                    } catch {
                        recordUsage(accumulatedOutput: accumulated, failed: true)
                        c.finish(throwing: error)
                    }
                }
                c.onTermination = { _ in t.cancel() }
            }
        default:
            return AsyncThrowingStream { c in
                let t = Task {
                    var accumulated = ""
                    do {
                        guard let baseURL = URL(string: provider.baseURL) else { throw EnhancementError.notConfigured }
                        let temp = resolvedModel.lowercased().hasPrefix("gpt-5") ? 1.0 : 0.3
                        let inner = StreamingChatClient.streamOpenAI(
                            baseURL: baseURL, apiKey: try key(), model: resolvedModel,
                            messages: messages, systemPrompt: systemPrompt, temperature: temp,
                            reasoningEffort: ReasoningConfig.getReasoningParameter(for: provider, modelName: resolvedModel),
                            extraBody: ReasoningConfig.getExtraBodyParameters(for: provider, modelName: resolvedModel),
                            images: images, timeout: timeout,
                            includeUsageOption: Self.streamUsageOptionProviders.contains(provider),
                            onUsage: { usageBox.value = $0 })
                        for try await d in inner { accumulated += d; c.yield(d) }
                        recordUsage(accumulatedOutput: accumulated, failed: false)
                        c.finish()
                    } catch {
                        recordUsage(accumulatedOutput: accumulated, failed: true)
                        c.finish(throwing: error)
                    }
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
    /// 用量統計標籤(建構點決定:會議即答/深答、即時翻譯…)。
    var usageFeature: AIUsageFeature = .other

    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        aiService.streamChat(provider: provider, modelName: modelName,
                             messages: [.user(user)], systemPrompt: system, timeout: 60,
                             usageFeature: usageFeature)
    }

    func stream(system: String, user: String, images: [Data]) -> AsyncThrowingStream<String, Error> {
        aiService.streamChat(provider: provider, modelName: modelName,
                             messages: [.user(user)], systemPrompt: system, images: images, timeout: 60,
                             usageFeature: usageFeature)
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
