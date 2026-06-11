import Foundation

public enum PricingEngine {
    public static func estimate(record: UsageRecord, pricing: [ModelPricing]) -> Decimal {
        let match = pricing.first { $0.tool == record.source && $0.model == record.model }
            ?? pricing.first { $0.model == record.model }
            ?? ModelPricing(tool: record.source, model: record.model, inputPerMillion: 3, outputPerMillion: 15, cachePerMillion: 0.3)
        return estimate(inputTokens: record.inputTokens, outputTokens: record.outputTokens, cacheTokens: record.cacheTokens, pricing: match)
    }

    public static func estimate(inputTokens: Int, outputTokens: Int, cacheTokens: Int, pricing: ModelPricing) -> Decimal {
        let million = Decimal(1_000_000)
        return Decimal(inputTokens) / million * pricing.inputPerMillion
            + Decimal(outputTokens) / million * pricing.outputPerMillion
            + Decimal(cacheTokens) / million * pricing.cachePerMillion
    }
}

public enum BudgetEngine {
    public static func progress(usage: AggregatedUsage, rule: BudgetRule, mode: BudgetProgressMode) -> Double {
        switch mode {
        case .tokens:
            return tokenProgress(usage: usage, rule: rule)
        case .cost:
            return costProgress(usage: usage, rule: rule)
        }
    }

    public static func progress(usage: AggregatedUsage, rule: BudgetRule) -> Double {
        max(tokenProgress(usage: usage, rule: rule), costProgress(usage: usage, rule: rule))
    }

    public static func tokenProgress(usage: AggregatedUsage, rule: BudgetRule) -> Double {
        rule.tokenLimit > 0 ? Double(usage.totalTokens) / Double(rule.tokenLimit) : 0
    }

    public static func costProgress(usage: AggregatedUsage, rule: BudgetRule) -> Double {
        let costLimit = NSDecimalNumber(decimal: rule.costLimit).doubleValue
        return costLimit > 0 ? NSDecimalNumber(decimal: usage.estimatedCost).doubleValue / costLimit : 0
    }

    public static func alertLevel(progress: Double) -> BudgetAlertLevel {
        if progress >= 1 { return .exceeded }
        if progress >= 0.8 { return .warning }
        return .normal
    }
}

public enum AggregationEngine {
    private static func filteredRecords(records: [UsageRecord], range: TimeRange, customRange: CustomDateRange?, now: Date, calendar: Calendar) -> [UsageRecord] {
        if let customRange {
            // Precompute the [startOfDay(start), 23:59:59(end)] bounds once instead of letting
            // `CustomDateRange.contains` recompute them for every record — the trend recompute
            // (triggered on every custom-date change) walks the whole record set here.
            let start = calendar.startOfDay(for: customRange.start)
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: customRange.end) ?? customRange.end
            return records.filter { $0.timestamp >= start && $0.timestamp <= end }
        }
        return records.filter { range.contains($0.timestamp, calendar: calendar, now: now) }
    }

    public static func aggregate(records: [UsageRecord], range: TimeRange, now: Date = Date(), calendar: Calendar = .current) -> AggregatedUsage {
        aggregate(records: records, range: range, customRange: nil, now: now, calendar: calendar)
    }

    public static func aggregate(records: [UsageRecord], range: TimeRange, customRange: CustomDateRange?, now: Date = Date(), calendar: Calendar = .current) -> AggregatedUsage {
        filteredRecords(records: records, range: range, customRange: customRange, now: now, calendar: calendar).reduce(into: AggregatedUsage()) { partial, record in
            partial.inputTokens += record.inputTokens
            partial.outputTokens += record.outputTokens
            partial.cacheTokens += record.cacheTokens
            partial.cacheCreationTokens += record.cacheCreationTokens
            partial.totalTokens += record.totalTokens
            partial.estimatedCost += record.estimatedCost
            partial.requestCount += 1
        }
    }

    public static func groupByTool(records: [UsageRecord], range: TimeRange, now: Date = Date(), calendar: Calendar = .current) -> [ToolKind: AggregatedUsage] {
        groupByTool(records: records, range: range, customRange: nil, now: now, calendar: calendar)
    }

    public static func groupByTool(records: [UsageRecord], range: TimeRange, customRange: CustomDateRange?, now: Date = Date(), calendar: Calendar = .current) -> [ToolKind: AggregatedUsage] {
        Dictionary(grouping: filteredRecords(records: records, range: range, customRange: customRange, now: now, calendar: calendar), by: \.source)
            .mapValues { aggregate(records: $0, range: .all, now: now, calendar: calendar) }
    }

    public static func groupByModel(records: [UsageRecord], range: TimeRange, now: Date = Date(), calendar: Calendar = .current) -> [String: AggregatedUsage] {
        groupByModel(records: records, range: range, customRange: nil, now: now, calendar: calendar)
    }

    public static func groupByModel(records: [UsageRecord], range: TimeRange, customRange: CustomDateRange?, now: Date = Date(), calendar: Calendar = .current) -> [String: AggregatedUsage] {
        Dictionary(grouping: filteredRecords(records: records, range: range, customRange: customRange, now: now, calendar: calendar), by: \.model)
            .mapValues { aggregate(records: $0, range: .all, now: now, calendar: calendar) }
    }

    public static func trend(records: [UsageRecord], range: TimeRange, now: Date = Date(), calendar: Calendar = .current) -> [TrendBucket] {
        trend(records: records, range: range, customRange: nil, now: now, calendar: calendar)
    }

    public static func trend(records: [UsageRecord], range: TimeRange, customRange: CustomDateRange?, now: Date = Date(), calendar: Calendar = .current) -> [TrendBucket] {
        let filtered = filteredRecords(records: records, range: range, customRange: customRange, now: now, calendar: calendar)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if let customRange {
            let dayCount = calendar.dateComponents([.day], from: calendar.startOfDay(for: customRange.start), to: calendar.startOfDay(for: customRange.end)).day ?? 0
            formatter.dateFormat = dayCount <= 1 ? "HH:00" : dayCount <= 92 ? "MM-dd" : "yyyy-MM"
            let component: Calendar.Component = dayCount <= 1 ? .hour : dayCount <= 92 ? .day : .month
            return buckets(filtered, component: component, formatter: formatter, calendar: calendar)
        }
        switch range {
        case .today:
            formatter.dateFormat = "HH:00"
            return buckets(filtered, component: .hour, formatter: formatter, calendar: calendar)
        case .week, .month:
            formatter.dateFormat = "MM-dd"
            return buckets(filtered, component: .day, formatter: formatter, calendar: calendar)
        case .all:
            formatter.dateFormat = "yyyy-MM"
            return buckets(filtered, component: .month, formatter: formatter, calendar: calendar)
        }
    }

    private static func buckets(_ records: [UsageRecord], component: Calendar.Component, formatter: DateFormatter, calendar: Calendar) -> [TrendBucket] {
        let grouped = Dictionary(grouping: records) { record in
            calendar.dateInterval(of: component, for: record.timestamp)?.start ?? record.timestamp
        }
        return grouped.keys.sorted().map { date in
            let rows = grouped[date] ?? []
            let agg = aggregate(records: rows, range: .all, calendar: calendar)
            return TrendBucket(label: formatter.string(from: date), inputTokens: agg.inputTokens, outputTokens: agg.outputTokens, cacheTokens: agg.cacheTokens, totalTokens: agg.totalTokens)
        }
    }
}
