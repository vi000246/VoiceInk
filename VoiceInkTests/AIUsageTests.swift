import XCTest
@testable import VoiceInk
import LLMkit

/// AI 用量統計的純 seam 測試:token 估算、單價解析、回應 usage 解析、聚合。
/// 不碰網路、不碰 SwiftData container、不碰 UserDefaults.standard
/// (pricing store 用獨立 suite,見 voiceink-tests-never-touch-userdefaults 教訓)。
@MainActor
final class AIUsageTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AIUsageTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - TokenEstimator

    func testEstimateCJKRoughlyOnePerChar() {
        // 10 個漢字 ≈ 10 tokens(無其他字元)。
        XCTAssertEqual(TokenEstimator.estimate("會議紀錄與待辦事項整"), 10)
    }

    func testEstimateASCIIRoughlyQuarter() {
        // 8 個 ASCII 字元 → 8/4 = 2(重用 RecorderAutomation 的 TokenEstimator,空字串下限 1)。
        XCTAssertEqual(TokenEstimator.estimate("abcdefgh"), 2)
        XCTAssertEqual(TokenEstimator.estimate(""), 1)
    }

    func testEstimateMixed() {
        // 2 漢字 + 4 ASCII("test")→ 2 + 1 = 3。
        XCTAssertEqual(TokenEstimator.estimate("測試test"), 3)
    }

    func testEstimateInputAddsMessageOverheadAndImages() {
        let messages: [ChatMessage] = [.user("abcd")]   // 1 token + 4 overhead
        let noImage = TokenEstimator.estimateInput(system: nil, messages: messages)
        XCTAssertEqual(noImage, 5)
        let withImages = TokenEstimator.estimateInput(system: nil, messages: messages, imageCount: 2)
        XCTAssertEqual(withImages, 5 + 2200)
    }

    // MARK: - AIModelPricingStore

    func testBuiltinLookupAndProviderPrefixStrip() {
        let store = AIModelPricingStore(defaults: defaults)
        XCTAssertEqual(store.price(for: "gpt-4.1")?.inputPerMillion, 2.00)
        // provider 前綴("openai/")去掉後命中內建。
        XCTAssertEqual(store.price(for: "openai/gpt-oss-120b")?.outputPerMillion, 0.75)
        // 大小寫不敏感。
        XCTAssertNotNil(store.price(for: "GPT-4.1"))
    }

    func testVersionPrefixMatchRequiresDashBoundary() {
        let store = AIModelPricingStore(defaults: defaults)
        // 帶日期字尾的版本名靠前綴命中。
        XCTAssertEqual(store.price(for: "gpt-4.1-2025-04-14")?.inputPerMillion, 2.00)
        // "gpt-5.4" 不得誤吃 "gpt-5" 的價(邊界必須是 "-")。
        XCTAssertNil(store.price(for: "gpt-5.4"))
        XCTAssertNil(store.price(for: "完全未知模型"))
    }

    func testOverrideWinsAndPersists() {
        let store = AIModelPricingStore(defaults: defaults)
        store.setOverride(.init(inputPerMillion: 9, outputPerMillion: 99), for: "GPT-4.1")
        XCTAssertEqual(store.price(for: "gpt-4.1")?.inputPerMillion, 9)

        let reloaded = AIModelPricingStore(defaults: defaults)
        XCTAssertEqual(reloaded.price(for: "gpt-4.1")?.outputPerMillion, 99)

        reloaded.setOverride(nil, for: "gpt-4.1")
        XCTAssertEqual(reloaded.price(for: "gpt-4.1")?.inputPerMillion, 2.00)   // 回落內建
    }

    // MARK: - ChatCompletionClient 回應解析

    func testParseOpenAIWithUsage() throws {
        let json = """
        {"choices":[{"message":{"content":"哈囉"}}],
         "usage":{"prompt_tokens":12,"completion_tokens":34}}
        """.data(using: .utf8)!
        let completion = try ChatCompletionClient.parseOpenAI(json)
        XCTAssertEqual(completion.text, "哈囉")
        XCTAssertEqual(completion.usage, ChatUsage(inputTokens: 12, outputTokens: 34))
    }

    func testParseOpenAIWithoutUsage() throws {
        let json = #"{"choices":[{"message":{"content":"hi"}}]}"#.data(using: .utf8)!
        let completion = try ChatCompletionClient.parseOpenAI(json)
        XCTAssertEqual(completion.text, "hi")
        XCTAssertNil(completion.usage)
    }

    func testParseAnthropicUsage() throws {
        let json = """
        {"content":[{"type":"text","text":"回答"}],
         "usage":{"input_tokens":100,"output_tokens":7}}
        """.data(using: .utf8)!
        let completion = try ChatCompletionClient.parseAnthropic(json)
        XCTAssertEqual(completion.text, "回答")
        XCTAssertEqual(completion.usage, ChatUsage(inputTokens: 100, outputTokens: 7))
    }

    // MARK: - 串流 usage chunk 解析

    func testStreamingUsageChunkTopLevelAndXGroq() throws {
        let topLevel = """
        {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":6}}
        """.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(StreamingChatClient.OpenAIChunk.self, from: topLevel)
        XCTAssertEqual(StreamingChatClient.usageFromOpenAIChunk(chunk),
                       ChatUsage(inputTokens: 5, outputTokens: 6))

        let groq = """
        {"choices":[{"delta":{"content":"x"}}],"x_groq":{"usage":{"prompt_tokens":1,"completion_tokens":2}}}
        """.data(using: .utf8)!
        let groqChunk = try JSONDecoder().decode(StreamingChatClient.OpenAIChunk.self, from: groq)
        XCTAssertEqual(StreamingChatClient.usageFromOpenAIChunk(groqChunk),
                       ChatUsage(inputTokens: 1, outputTokens: 2))

        let none = #"{"choices":[{"delta":{"content":"y"}}]}"#.data(using: .utf8)!
        let noneChunk = try JSONDecoder().decode(StreamingChatClient.OpenAIChunk.self, from: none)
        XCTAssertNil(StreamingChatClient.usageFromOpenAIChunk(noneChunk))
    }

    // MARK: - AIUsageAggregator

    private func row(_ iso: String, model: String = "gpt-4.1", feature: String = "askai",
                     input: Int = 100, output: Int = 10, estimated: Bool = false) -> AIUsageAggregator.EventRow {
        let formatter = ISO8601DateFormatter()
        return AIUsageAggregator.EventRow(
            timestamp: formatter.date(from: iso)!, provider: "OpenAI", model: model,
            feature: feature, inputTokens: input, outputTokens: output, isEstimated: estimated)
    }

    func testBucketsGroupByDayAndSorted() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let events = [
            row("2026-07-15T23:50:00+08:00"),
            row("2026-07-16T00:10:00+08:00"),
            row("2026-07-16T12:00:00+08:00"),
        ]
        let buckets = AIUsageAggregator.buckets(
            events: events, granularity: .day, calendar: calendar,
            price: { model in AIModelPricingStore.builtin[model.lowercased()] })
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].label, "2026/07/15")
        XCTAssertEqual(buckets[1].label, "2026/07/16")
        XCTAssertEqual(buckets[1].inputTokens, 200)
    }

    func testBucketsMonthAndYearLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let events = [row("2026-01-05T10:00:00+08:00"), row("2026-07-16T10:00:00+08:00")]
        let months = AIUsageAggregator.buckets(events: events, granularity: .month, calendar: calendar, price: { _ in nil })
        XCTAssertEqual(months.map(\.label), ["2026/01", "2026/07"])
        let years = AIUsageAggregator.buckets(events: events, granularity: .year, calendar: calendar, price: { _ in nil })
        XCTAssertEqual(years.map(\.label), ["2026"])
        XCTAssertEqual(years[0].inputTokens, 200)
    }

    func testCostMathAndSummaryUnpriced() {
        let price = AIModelPricingStore.Price(inputPerMillion: 2, outputPerMillion: 8)
        // 1M 輸入 + 0.5M 輸出 → 2 + 4 = 6 美元。
        XCTAssertEqual(AIUsageAggregator.cost(input: 1_000_000, output: 500_000, price: price), 6.0, accuracy: 0.0001)

        let events = [
            row("2026-07-16T10:00:00+08:00", model: "gpt-4.1", input: 1_000_000, output: 0),
            row("2026-07-16T11:00:00+08:00", model: "unknown-x", input: 50, output: 5, estimated: true),
        ]
        let summary = AIUsageAggregator.summary(events: events) { model in
            model == "gpt-4.1" ? price : nil
        }
        XCTAssertEqual(summary.calls, 2)
        XCTAssertEqual(summary.cost, 2.0, accuracy: 0.0001)
        XCTAssertEqual(summary.estimatedCount, 1)
        XCTAssertEqual(summary.unpricedModels, ["unknown-x"])
    }

    func testModelRowsSortByCostThenTokens() {
        let events = [
            row("2026-07-16T10:00:00+08:00", model: "cheap", input: 10, output: 0),
            row("2026-07-16T10:01:00+08:00", model: "expensive", input: 1_000_000, output: 0),
        ]
        let rows = AIUsageAggregator.modelRows(events: events) { model in
            model == "expensive" ? .init(inputPerMillion: 10, outputPerMillion: 10) : nil
        }
        XCTAssertEqual(rows.first?.model, "expensive")
        XCTAssertNil(rows.last?.price)
        XCTAssertEqual(rows.last?.cost, 0)
    }
}
