import Foundation

/// AI 用量的純聚合層(dashboard 的資料引擎;無 SwiftData/UI 依賴,可單元測試)。
///
/// 費用 = Σ(input/1M × 單價.in + output/1M × 單價.out),單價由呼叫端注入
/// (`AIModelPricingStore.price(for:)`),查無單價的模型費用計 0 並列入 `unpricedModels`。
enum AIUsageAggregator {

    /// 與 `AIUsageEvent` 同構的素 struct(聚合層不碰 @Model,測試不必開 container)。
    struct EventRow {
        let timestamp: Date
        let provider: String
        let model: String
        let feature: String
        let inputTokens: Int
        let outputTokens: Int
        let isEstimated: Bool
    }

    enum Granularity: String, CaseIterable, Identifiable {
        case day, month, year
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .day: return "日"
            case .month: return "月"
            case .year: return "年"
            }
        }
    }

    struct Bucket: Identifiable {
        var id: Date { start }
        let start: Date
        let label: String
        let inputTokens: Int
        let outputTokens: Int
        let cost: Double
    }

    struct ModelRow: Identifiable {
        var id: String { model }
        let model: String
        let calls: Int
        let inputTokens: Int
        let outputTokens: Int
        /// nil = 查無單價(顯示「未定價」,費用計 0)。
        let price: AIModelPricingStore.Price?
        let cost: Double
        let hasEstimated: Bool
    }

    struct FeatureRow: Identifiable {
        var id: String { featureRaw }
        let featureRaw: String
        let calls: Int
        let inputTokens: Int
        let outputTokens: Int
        let cost: Double
    }

    struct Summary {
        let calls: Int
        let inputTokens: Int
        let outputTokens: Int
        let cost: Double
        let estimatedCount: Int
        let unpricedModels: [String]
    }

    static func cost(input: Int, output: Int, price: AIModelPricingStore.Price?) -> Double {
        guard let price else { return 0 }
        return Double(input) / 1_000_000 * price.inputPerMillion
            + Double(output) / 1_000_000 * price.outputPerMillion
    }

    /// 事件的時間桶起點(日/月/年對齊)。
    static func bucketStart(for date: Date, granularity: Granularity, calendar: Calendar = .current) -> Date {
        switch granularity {
        case .day:
            return calendar.startOfDay(for: date)
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
        case .year:
            let comps = calendar.dateComponents([.year], from: date)
            return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
        }
    }

    static func bucketLabel(for start: Date, granularity: Granularity, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: start)
        switch granularity {
        case .day: return String(format: "%d/%02d/%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        case .month: return String(format: "%d/%02d", comps.year ?? 0, comps.month ?? 0)
        case .year: return String(format: "%d", comps.year ?? 0)
        }
    }

    /// 時間序列(依桶起點排序;只含有資料的桶)。
    static func buckets(
        events: [EventRow],
        granularity: Granularity,
        calendar: Calendar = .current,
        price: (String) -> AIModelPricingStore.Price?
    ) -> [Bucket] {
        var acc: [Date: (input: Int, output: Int, cost: Double)] = [:]
        for event in events {
            let start = bucketStart(for: event.timestamp, granularity: granularity, calendar: calendar)
            var slot = acc[start] ?? (0, 0, 0)
            slot.input += event.inputTokens
            slot.output += event.outputTokens
            slot.cost += cost(input: event.inputTokens, output: event.outputTokens, price: price(event.model))
            acc[start] = slot
        }
        return acc.keys.sorted().map { start in
            let slot = acc[start]!
            return Bucket(
                start: start,
                label: bucketLabel(for: start, granularity: granularity, calendar: calendar),
                inputTokens: slot.input, outputTokens: slot.output, cost: slot.cost)
        }
    }

    /// 依模型分組(費用高→低,同費用依 tokens)。
    static func modelRows(
        events: [EventRow],
        price: (String) -> AIModelPricingStore.Price?
    ) -> [ModelRow] {
        var acc: [String: (calls: Int, input: Int, output: Int, estimated: Bool)] = [:]
        for event in events {
            var slot = acc[event.model] ?? (0, 0, 0, false)
            slot.calls += 1
            slot.input += event.inputTokens
            slot.output += event.outputTokens
            slot.estimated = slot.estimated || event.isEstimated
            acc[event.model] = slot
        }
        let rows: [ModelRow] = acc.map { model, slot in
            let p = price(model)
            return ModelRow(
                model: model, calls: slot.calls,
                inputTokens: slot.input, outputTokens: slot.output,
                price: p, cost: cost(input: slot.input, output: slot.output, price: p),
                hasEstimated: slot.estimated)
        }
        return rows.sorted { a, b in
            if a.cost != b.cost { return a.cost > b.cost }
            return a.inputTokens + a.outputTokens > b.inputTokens + b.outputTokens
        }
    }

    /// 依功能分組(費用高→低)。
    static func featureRows(
        events: [EventRow],
        price: (String) -> AIModelPricingStore.Price?
    ) -> [FeatureRow] {
        var acc: [String: (calls: Int, input: Int, output: Int, cost: Double)] = [:]
        for event in events {
            var slot = acc[event.feature] ?? (0, 0, 0, 0)
            slot.calls += 1
            slot.input += event.inputTokens
            slot.output += event.outputTokens
            slot.cost += cost(input: event.inputTokens, output: event.outputTokens, price: price(event.model))
            acc[event.feature] = slot
        }
        let rows: [FeatureRow] = acc.map { feature, slot in
            FeatureRow(featureRaw: feature, calls: slot.calls,
                       inputTokens: slot.input, outputTokens: slot.output, cost: slot.cost)
        }
        return rows.sorted { a, b in
            if a.cost != b.cost { return a.cost > b.cost }
            return a.inputTokens + a.outputTokens > b.inputTokens + b.outputTokens
        }
    }

    static func summary(
        events: [EventRow],
        price: (String) -> AIModelPricingStore.Price?
    ) -> Summary {
        var calls = 0, input = 0, output = 0, estimated = 0
        var total = 0.0
        var unpriced = Set<String>()
        for event in events {
            calls += 1
            input += event.inputTokens
            output += event.outputTokens
            if event.isEstimated { estimated += 1 }
            if let p = price(event.model) {
                total += cost(input: event.inputTokens, output: event.outputTokens, price: p)
            } else {
                unpriced.insert(event.model)
            }
        }
        return Summary(calls: calls, inputTokens: input, outputTokens: output,
                       cost: total, estimatedCount: estimated, unpricedModels: unpriced.sorted())
    }
}
