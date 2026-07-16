import SwiftUI
import SwiftData
import Charts

/// AI 用量與費用 dashboard:日期區間篩選、日/月/年聚合圖、依模型/功能分組、
/// 依單價表(`AIModelPricingStore`)即時計費。資料來源 = `AIUsageEvent`(stats.store)。
struct AIUsageDashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var pricing = AIModelPricingStore.shared

    /// 日期區間預設選項。
    enum RangePreset: String, CaseIterable, Identifiable {
        case today = "今天"
        case week = "近 7 天"
        case month = "本月"
        case year = "今年"
        case all = "全部"
        case custom = "自訂"
        var id: String { rawValue }
    }

    enum ChartMetric: String, CaseIterable, Identifiable {
        case tokens = "Tokens"
        case cost = "費用"
        var id: String { rawValue }
    }

    @State private var preset: RangePreset = .month
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var granularity: AIUsageAggregator.Granularity = .day
    @State private var chartMetric: ChartMetric = .tokens
    @State private var events: [AIUsageAggregator.EventRow] = []
    @State private var showPricingEditor = false
    @State private var reloadTick = 0

    // MARK: - 日期區間

    private var dateRange: ClosedRange<Date> {
        let calendar = Calendar.current
        let now = Date()
        switch preset {
        case .today:
            return calendar.startOfDay(for: now)...now
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
            return start...now
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: now)
            return (calendar.date(from: comps) ?? now)...now
        case .year:
            let comps = calendar.dateComponents([.year], from: now)
            return (calendar.date(from: comps) ?? now)...now
        case .all:
            return Date.distantPast...now
        case .custom:
            let start = Calendar.current.startOfDay(for: customStart)
            let end = Calendar.current.date(
                byAdding: .day, value: 1,
                to: Calendar.current.startOfDay(for: customEnd)) ?? customEnd
            return start...(max(start, end))
        }
    }

    /// 觸發重抓的關鍵字(preset/自訂日期/手動刷新)。
    private var fetchKey: String {
        "\(preset.rawValue)|\(customStart.timeIntervalSince1970)|\(customEnd.timeIntervalSince1970)|\(reloadTick)"
    }

    // MARK: - 聚合(純函式,單價即時查)

    private func priceLookup(_ model: String) -> AIModelPricingStore.Price? {
        pricing.price(for: model)
    }

    private var summary: AIUsageAggregator.Summary {
        AIUsageAggregator.summary(events: events, price: priceLookup)
    }

    private var buckets: [AIUsageAggregator.Bucket] {
        AIUsageAggregator.buckets(events: events, granularity: granularity, price: priceLookup)
    }

    private var modelRows: [AIUsageAggregator.ModelRow] {
        AIUsageAggregator.modelRows(events: events, price: priceLookup)
    }

    private var featureRows: [AIUsageAggregator.FeatureRow] {
        AIUsageAggregator.featureRows(events: events, price: priceLookup)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "AI 用量",
                infoMessage: "每次雲端 LLM/嵌入呼叫都會記一筆 token 用量;費用依「單價表」即時計算,調價後歷史費用自動重算。標「估算」的是供應商沒回報 usage、以字元數推估的近似值。本機模型（Ollama / Local CLI）免費不列入。",
                infoURL: nil
            ) {
                HStack(spacing: 8) {
                    Button {
                        reloadTick += 1
                    } label: {
                        Label("重新整理", systemImage: "arrow.clockwise")
                    }
                    Button {
                        showPricingEditor = true
                    } label: {
                        Label("單價表", systemImage: "dollarsign.circle")
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    summaryCards
                    chartCard
                    modelTable
                    featureTable
                    footnotes
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: fetchKey) { reload() }
        .sheet(isPresented: $showPricingEditor) {
            AIModelPricingEditorSheet(modelsInUse: modelRows.map(\.model))
        }
    }

    private func reload() {
        let range = dateRange
        let start = range.lowerBound
        let end = range.upperBound
        var descriptor = FetchDescriptor<AIUsageEvent>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp <= end },
            sortBy: [SortDescriptor(\.timestamp)])
        descriptor.propertiesToFetch = [\.timestamp, \.provider, \.model, \.feature,
                                        \.inputTokens, \.outputTokens, \.isEstimated]
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        events = fetched.map {
            AIUsageAggregator.EventRow(
                timestamp: $0.timestamp, provider: $0.provider, model: $0.model,
                feature: $0.feature, inputTokens: $0.inputTokens,
                outputTokens: $0.outputTokens, isEstimated: $0.isEstimated)
        }
    }

    // MARK: - 控制列

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("區間", selection: $preset) {
                    ForEach(RangePreset.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Spacer()

                Picker("聚合", selection: $granularity) {
                    ForEach(AIUsageAggregator.Granularity.allCases) { g in Text(g.displayName).tag(g) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            if preset == .custom {
                HStack(spacing: 10) {
                    DatePicker("從", selection: $customStart, displayedComponents: .date)
                    DatePicker("到", selection: $customEnd, displayedComponents: .date)
                    Spacer()
                }
                .datePickerStyle(.compact)
            }
        }
    }

    // MARK: - 摘要卡

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(title: "估算費用", value: Self.usd(summary.cost), accent: true)
            summaryCard(title: "輸入 tokens", value: Formatters.formattedCompactNumber(summary.inputTokens))
            summaryCard(title: "輸出 tokens", value: Formatters.formattedCompactNumber(summary.outputTokens))
            summaryCard(title: "呼叫次數", value: Formatters.formattedNumber(summary.calls))
        }
    }

    private func summaryCard(title: String, value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(accent ? AppTheme.Accent.primary : Color.primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppCardBackground(cornerRadius: 10))
    }

    // MARK: - 圖表

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("用量趨勢").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $chartMetric) {
                    ForEach(ChartMetric.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            if buckets.isEmpty {
                Text("此區間沒有 AI 呼叫記錄。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if chartMetric == .tokens {
                Chart(buckets) { b in
                    BarMark(x: .value("期間", b.label), y: .value("Tokens", b.inputTokens))
                        .foregroundStyle(by: .value("方向", "輸入"))
                    BarMark(x: .value("期間", b.label), y: .value("Tokens", b.outputTokens))
                        .foregroundStyle(by: .value("方向", "輸出"))
                }
                .chartForegroundStyleScale(["輸入": AppTheme.Accent.primary, "輸出": Color.orange])
                .frame(height: 220)
            } else {
                Chart(buckets) { b in
                    BarMark(x: .value("期間", b.label), y: .value("費用", b.cost))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
                .frame(height: 220)
            }
        }
        .padding(14)
        .background(AppCardBackground(cornerRadius: 10))
    }

    // MARK: - 依模型

    private var modelTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("依模型").font(.system(size: 13, weight: .semibold))
            if modelRows.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                tableHeader(["模型", "次數", "輸入", "輸出", "單價（in/out $/1M）", "費用"])
                ForEach(modelRows) { row in
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Text(row.model).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if row.hasEstimated {
                                Text("估").font(.system(size: 9))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cell(Formatters.formattedNumber(row.calls), width: 60)
                        cell(Formatters.formattedCompactNumber(row.inputTokens), width: 70)
                        cell(Formatters.formattedCompactNumber(row.outputTokens), width: 70)
                        Group {
                            if let p = row.price {
                                cell(String(format: "%.2f / %.2f", p.inputPerMillion, p.outputPerMillion), width: 130)
                            } else {
                                Text("未定價")
                                    .font(.system(size: 11)).foregroundStyle(.orange)
                                    .frame(width: 130, alignment: .trailing)
                            }
                        }
                        cell(Self.usd(row.cost), width: 90, bold: true)
                    }
                    .padding(.vertical, 3)
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(14)
        .background(AppCardBackground(cornerRadius: 10))
    }

    // MARK: - 依功能

    private var featureTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("依功能").font(.system(size: 13, weight: .semibold))
            if featureRows.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                tableHeader(["功能", "次數", "輸入", "輸出", "費用"])
                ForEach(featureRows) { row in
                    HStack(spacing: 8) {
                        Text(AIUsageFeature.displayName(forRaw: row.featureRaw))
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        cell(Formatters.formattedNumber(row.calls), width: 60)
                        cell(Formatters.formattedCompactNumber(row.inputTokens), width: 70)
                        cell(Formatters.formattedCompactNumber(row.outputTokens), width: 70)
                        cell(Self.usd(row.cost), width: 90, bold: true)
                    }
                    .padding(.vertical, 3)
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(14)
        .background(AppCardBackground(cornerRadius: 10))
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if summary.estimatedCount > 0 {
                Label("\(summary.estimatedCount) 筆呼叫的供應商沒回報 usage,以字元數估算(標「估」)。",
                      systemImage: "info.circle")
            }
            if !summary.unpricedModels.isEmpty {
                Label("未定價模型(費用計 0):\(summary.unpricedModels.joined(separator: "、"))——到右上「單價表」補上。",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Label("費用為估算值(依單價表計算),實際帳單以供應商為準;不含快取折扣/批次折扣。",
                  systemImage: "dollarsign.circle")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: - 小工具

    private func tableHeader(_ titles: [String]) -> some View {
        HStack(spacing: 8) {
            Text(titles[0]).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(titles.dropFirst().enumerated()), id: \.offset) { index, t in
                // 欄寬與資料列一致:次數 60 / 輸入 70 / 輸出 70 / (單價 130) / 費用 90
                Text(t).frame(width: headerWidth(index: index, count: titles.count - 1), alignment: .trailing)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private func headerWidth(index: Int, count: Int) -> CGFloat {
        // 模型表 5 欄:60/70/70/130/90;功能表 4 欄:60/70/70/90。
        let widths: [CGFloat] = count == 5 ? [60, 70, 70, 130, 90] : [60, 70, 70, 90]
        return widths[min(index, widths.count - 1)]
    }

    private func cell(_ text: String, width: CGFloat, bold: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12, weight: bold ? .semibold : .regular))
            .monospacedDigit()
            .frame(width: width, alignment: .trailing)
    }

    /// 美元字串:一般兩位小數;小於 0.1 顯示四位,避免長期顯示 $0.00。
    static func usd(_ value: Double) -> String {
        value >= 0.1 || value == 0
            ? String(format: "US$%.2f", value)
            : String(format: "US$%.4f", value)
    }
}

// MARK: - 單價編輯器

/// 模型單價編輯 sheet。列出「本期有用量的模型 + 已覆寫 + 內建」的聯集;
/// 改完按「儲存」寫回覆寫表(清空兩欄 = 移除覆寫、回落內建)。
private struct AIModelPricingEditorSheet: View {
    let modelsInUse: [String]
    @ObservedObject private var pricing = AIModelPricingStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 編輯中的字串(model → (in, out));空字串 = 未設定。
    @State private var edits: [String: (input: String, output: String)] = [:]
    @State private var allModels: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模型單價表（USD / 1M tokens）")
                .font(.system(size: 15, weight: .semibold))
            Text("內建價涵蓋常見模型;新/調價模型請自行填寫。填了就以你的值為準（覆寫），清空兩欄即回落內建價。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("模型").frame(maxWidth: .infinity, alignment: .leading)
                Text("輸入 $/1M").frame(width: 90, alignment: .trailing)
                Text("輸出 $/1M").frame(width: 90, alignment: .trailing)
                Text("來源").frame(width: 56, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(allModels, id: \.self) { model in
                        HStack(spacing: 8) {
                            Text(model)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TextField("—", text: binding(for: model).input)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            TextField("—", text: binding(for: model).output)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text(sourceLabel(for: model))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(minHeight: 260, maxHeight: 380)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("儲存") {
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { load() }
    }

    private func load() {
        var names = Set(modelsInUse.map { $0.lowercased() })
        names.formUnion(pricing.overrides.keys)
        names.formUnion(AIModelPricingStore.builtin.keys)
        allModels = names.sorted()
        for model in allModels {
            if let override = pricing.overrides[model] {
                edits[model] = (Self.trimmed(override.inputPerMillion), Self.trimmed(override.outputPerMillion))
            } else if let builtin = AIModelPricingStore.builtin[model] {
                edits[model] = (Self.trimmed(builtin.inputPerMillion), Self.trimmed(builtin.outputPerMillion))
            } else if let resolved = pricing.price(for: model) {
                // 靠前綴比對命中的(如帶日期字尾的版本名)——顯示解析價,但不主動存成覆寫。
                edits[model] = (Self.trimmed(resolved.inputPerMillion), Self.trimmed(resolved.outputPerMillion))
            } else {
                edits[model] = ("", "")
            }
        }
    }

    private func binding(for model: String) -> (input: Binding<String>, output: Binding<String>) {
        (
            Binding(
                get: { edits[model]?.input ?? "" },
                set: { edits[model] = ($0, edits[model]?.output ?? "") }),
            Binding(
                get: { edits[model]?.output ?? "" },
                set: { edits[model] = (edits[model]?.input ?? "", $0) })
        )
    }

    private func sourceLabel(for model: String) -> String {
        if pricing.overrides[model] != nil { return "覆寫" }
        if AIModelPricingStore.builtin[model] != nil { return "內建" }
        return pricing.price(for: model) != nil ? "前綴" : "未定價"
    }

    /// 寫回:與「目前有效值」不同才動;兩欄皆空 = 清除覆寫。
    private func apply() {
        for model in allModels {
            guard let edit = edits[model] else { continue }
            let inputText = edit.input.trimmingCharacters(in: .whitespaces)
            let outputText = edit.output.trimmingCharacters(in: .whitespaces)

            if inputText.isEmpty && outputText.isEmpty {
                if pricing.overrides[model] != nil { pricing.setOverride(nil, for: model) }
                continue
            }
            guard let input = Double(inputText), let output = Double(outputText.isEmpty ? "0" : outputText),
                  input >= 0, output >= 0 else { continue }
            let newPrice = AIModelPricingStore.Price(inputPerMillion: input, outputPerMillion: output)
            // 與內建同值就不必留覆寫;不同才寫。
            if AIModelPricingStore.builtin[model] == newPrice {
                if pricing.overrides[model] != nil { pricing.setOverride(nil, for: model) }
            } else if pricing.overrides[model] != newPrice {
                pricing.setOverride(newPrice, for: model)
            }
        }
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() && value < 1000
            ? String(format: "%.0f", value)
            : String(format: "%g", value)
    }
}
