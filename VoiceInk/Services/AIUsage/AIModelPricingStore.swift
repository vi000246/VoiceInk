import Foundation
import Combine

/// 模型單價表(USD / 1M tokens)。內建常見模型 + 使用者覆寫(UserDefaults JSON)。
///
/// 費用一律由 dashboard 以「當前單價 × 歷史 token」即時計算 —— 單價落在這裡、token 落在
/// `AIUsageEvent`,兩者不綁死,調價後歷史費用自動重算。
///
/// **內建價未涵蓋的模型顯示「未定價」計 0 元**,請在 dashboard 的單價編輯器補上;
/// 太新的模型(內建表查核日之後發布)刻意不猜價。單價以「模型名」為 key,不分 provider
/// (同名模型跨家價差請用覆寫解決)。
@MainActor
final class AIModelPricingStore: ObservableObject {

    struct Price: Codable, Equatable {
        /// USD / 1M input tokens。
        var inputPerMillion: Double
        /// USD / 1M output tokens。
        var outputPerMillion: Double
    }

    static let shared = AIModelPricingStore()

    private let overridesKey = "aiModelPricingOverridesV1"
    private let defaults: UserDefaults

    /// 使用者覆寫(key 一律小寫模型名)。
    @Published private(set) var overrides: [String: Price] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: overridesKey),
           let decoded = try? JSONDecoder().decode([String: Price].self, from: data) {
            overrides = decoded
        }
    }

    /// 內建單價(2026-07 整理;之後的調價/新模型請在 UI 覆寫)。key 一律小寫。
    static let builtin: [String: Price] = [
        // OpenAI
        "gpt-4.1": Price(inputPerMillion: 2.00, outputPerMillion: 8.00),
        "gpt-4.1-mini": Price(inputPerMillion: 0.40, outputPerMillion: 1.60),
        "gpt-4.1-nano": Price(inputPerMillion: 0.10, outputPerMillion: 0.40),
        "gpt-4o": Price(inputPerMillion: 2.50, outputPerMillion: 10.00),
        "gpt-4o-mini": Price(inputPerMillion: 0.15, outputPerMillion: 0.60),
        "gpt-5": Price(inputPerMillion: 1.25, outputPerMillion: 10.00),
        "gpt-5-mini": Price(inputPerMillion: 0.25, outputPerMillion: 2.00),
        "gpt-5-nano": Price(inputPerMillion: 0.05, outputPerMillion: 0.40),
        // Anthropic
        "claude-sonnet-4-5": Price(inputPerMillion: 3.00, outputPerMillion: 15.00),
        "claude-haiku-4-5": Price(inputPerMillion: 1.00, outputPerMillion: 5.00),
        "claude-opus-4-5": Price(inputPerMillion: 5.00, outputPerMillion: 25.00),
        "claude-opus-4-1": Price(inputPerMillion: 15.00, outputPerMillion: 75.00),
        // Gemini
        "gemini-2.5-pro": Price(inputPerMillion: 1.25, outputPerMillion: 10.00),
        "gemini-2.5-flash": Price(inputPerMillion: 0.30, outputPerMillion: 2.50),
        "gemini-2.5-flash-lite": Price(inputPerMillion: 0.10, outputPerMillion: 0.40),
        // Groq(open-weight 託管)
        "gpt-oss-120b": Price(inputPerMillion: 0.15, outputPerMillion: 0.75),
        "gpt-oss-20b": Price(inputPerMillion: 0.10, outputPerMillion: 0.50),
        "llama-3.3-70b-versatile": Price(inputPerMillion: 0.59, outputPerMillion: 0.79),
        "llama-3.1-8b-instant": Price(inputPerMillion: 0.05, outputPerMillion: 0.08),
        "qwen3-32b": Price(inputPerMillion: 0.29, outputPerMillion: 0.59),
        // Mistral
        "mistral-large-latest": Price(inputPerMillion: 2.00, outputPerMillion: 6.00),
        "mistral-medium-latest": Price(inputPerMillion: 0.40, outputPerMillion: 2.00),
        "mistral-small-latest": Price(inputPerMillion: 0.10, outputPerMillion: 0.30),
        // 嵌入(只計輸入)
        "text-embedding-3-small": Price(inputPerMillion: 0.02, outputPerMillion: 0),
        "gemini-embedding-001": Price(inputPerMillion: 0.15, outputPerMillion: 0),
    ]

    /// 解析模型單價。比對順序(皆用小寫):
    /// 1. 覆寫/內建的**完整模型名**;
    /// 2. 去掉 provider 前綴後再比一次("openai/gpt-oss-120b" → "gpt-oss-120b"、"qwen/qwen3-32b" → "qwen3-32b");
    /// 3. 表中 key 是模型名的**版本前綴**("gpt-4.1" 命中 "gpt-4.1-2025-04-14";取最長 key)。
    /// 全部落空 → nil(dashboard 顯示「未定價」)。
    func price(for model: String) -> Price? {
        let lowered = model.lowercased().trimmingCharacters(in: .whitespaces)
        guard !lowered.isEmpty else { return nil }
        let stripped = lowered.split(separator: "/").last.map(String.init) ?? lowered

        for candidate in [lowered, stripped] {
            if let hit = overrides[candidate] ?? Self.builtin[candidate] {
                return hit
            }
        }

        // 版本前綴比對:key + "-" 是 candidate 的前綴(避免 "gpt-5" 誤吃 "gpt-5.4")。
        var best: (key: String, price: Price)?
        for table in [overrides, Self.builtin] {
            for (key, price) in table {
                for candidate in [lowered, stripped] where candidate.hasPrefix(key + "-") {
                    if best == nil || key.count > best!.key.count {
                        best = (key, price)
                    }
                }
            }
        }
        return best?.price
    }

    /// 設定/清除覆寫(nil = 清除,回落內建)。key 正規化為小寫。
    func setOverride(_ price: Price?, for model: String) {
        let key = model.lowercased().trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        if let price {
            overrides[key] = price
        } else {
            overrides.removeValue(forKey: key)
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: overridesKey)
        }
    }
}
