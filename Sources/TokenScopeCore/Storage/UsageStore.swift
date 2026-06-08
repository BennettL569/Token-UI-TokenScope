import Foundation

public actor UsageRepository {
    private var recordsByDedupeKey: [String: UsageRecord] = [:]

    public init(records: [UsageRecord] = []) {
        for record in records {
            recordsByDedupeKey[record.dedupeKey] = record
        }
    }

    public func upsert(_ records: [UsageRecord]) {
        for record in records {
            recordsByDedupeKey[record.dedupeKey] = record
        }
    }

    public func all() -> [UsageRecord] {
        recordsByDedupeKey.values.sorted { $0.timestamp > $1.timestamp }
    }

    public func clear() {
        recordsByDedupeKey.removeAll()
    }
}

public final class UsageStore: ObservableObject {
    @Published public private(set) var records: [UsageRecord] = []
    @Published public private(set) var dashboardSnapshot = DashboardSnapshot()
    @Published public var sources: [UsageSource]
    @Published public var pricing: [ModelPricing]
    @Published public var budgets: [BudgetRule] {
        didSet { rebuildDashboardSnapshot() }
    }
    @Published public var selectedRange: TimeRange = .today {
        didSet { rebuildDashboardSnapshot() }
    }
    @Published public var usesCustomDateRange = false {
        didSet { rebuildDashboardSnapshot() }
    }
    @Published public var customDateRange: CustomDateRange {
        didSet { rebuildDashboardSnapshot() }
    }
    @Published public var searchText: String = "" {
        didSet { rebuildDashboardSnapshot() }
    }
    @Published public var selectedTool: ToolKind? {
        didSet { rebuildDashboardSnapshot() }
    }
    @Published public var errorMessage: String?
    @Published public var isRefreshing = false
    @Published public var menuBarShowsCost = false
    @Published public var refreshProgress: String = ""
    @Published public var budgetProgressMode: BudgetProgressMode = .tokens {
        didSet { rebuildDashboardSnapshot() }
    }

    private let repository: PersistentUsageRepository
    private let registry: AdapterRegistry

    public init(repository: PersistentUsageRepository = PersistentUsageRepository(), registry: AdapterRegistry = AdapterRegistry()) {
        self.repository = repository
        self.registry = registry
        self.sources = Self.defaultSources()
        let calendar = Calendar.current
        let now = Date()
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: now) ?? now
        self.customDateRange = CustomDateRange(start: sevenDaysAgo, end: now)
        let persistedPricing = repository.loadPricing()
        if persistedPricing.isEmpty {
            let defaults = Self.defaultPricing()
            self.pricing = defaults
            repository.savePricing(defaults)
        } else {
            self.pricing = persistedPricing
        }
        let persistedBudgets = repository.loadBudgets()
        if persistedBudgets.isEmpty {
            let defaults = Self.defaultBudgets()
            self.budgets = defaults
            repository.saveBudgets(defaults)
        } else {
            self.budgets = Self.orderedBudgets(persistedBudgets)
        }
        self.records = repository.all()
        rebuildDashboardSnapshot()
    }

    @MainActor
    public func refreshAll(fullScan: Bool = false) async {
        isRefreshing = true
        refreshProgress = fullScan ? "准备全量重读" : "准备增量同步"
        errorMessage = nil
        if fullScan { repository.clearRefreshCursors() }
        var refreshedSources = sources
        var errors: [String] = []
        for index in refreshedSources.indices where refreshedSources[index].isEnabled {
            let source = refreshedSources[index]
            guard let adapter = registry.adapter(for: source.tool) else { continue }
            let modeText = fullScan ? "全量读取中" : "增量读取中"
            refreshedSources[index].syncStatus = SyncStatus(kind: .syncing, lastSync: Date(), message: modeText)
            sources = refreshedSources
            refreshProgress = "正在\(fullScan ? "全量" : "增量")读取 \(source.tool.rawValue)…"
            do {
                let newRecords = try await adapter.refresh(source: source, pricing: pricing, cursorStore: repository, fullScan: fullScan)
                repository.upsert(newRecords)
                refreshedSources[index].syncStatus = SyncStatus(kind: .success, lastSync: Date(), message: "已同步 \(newRecords.count) 条新增/更新")
            } catch {
                errors.append("\(source.tool.rawValue): \(error.localizedDescription)")
                refreshedSources[index].syncStatus = SyncStatus(kind: .failed, lastSync: Date(), message: error.localizedDescription)
            }
        }
        sources = refreshedSources
        records = repository.all()
        rebuildDashboardSnapshot()
        try? WidgetSummaryStore.save(widgetSummary())
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        refreshProgress = errors.isEmpty ? "同步完成：\(records.count) 条" : "同步完成，有 \(errors.count) 个错误"
        isRefreshing = false
    }

    @MainActor
    public func rebuildAllData() async {
        repository.clear()
        records = []
        rebuildDashboardSnapshot()
        await refreshAll(fullScan: true)
    }

    @MainActor
    public func clearLocalData() async {
        repository.clear()
        records = []
        rebuildDashboardSnapshot()
    }

    public func filteredRecords(now: Date = Date()) -> [UsageRecord] {
        records.filter { record in
            activeRangeContains(record.timestamp, now: now)
            && (selectedTool == nil || selectedTool == record.source)
            && (searchText.isEmpty || record.accountId.localizedCaseInsensitiveContains(searchText) || record.model.localizedCaseInsensitiveContains(searchText) || record.apiKeyHash.localizedCaseInsensitiveContains(searchText))
        }
    }

    public func aggregate(range: TimeRange? = nil, now: Date = Date()) -> AggregatedUsage {
        let useCustomRange = range == nil && usesCustomDateRange
        return AggregationEngine.aggregate(records: records, range: range ?? selectedRange, customRange: useCustomRange ? customDateRange : nil, now: now)
    }

    public func trend(now: Date = Date()) -> [TrendBucket] {
        AggregationEngine.trend(records: records, range: selectedRange, customRange: usesCustomDateRange ? customDateRange : nil, now: now)
    }

    public func rebuildDashboardSnapshot(now: Date = Date()) {
        let customRange = usesCustomDateRange ? customDateRange : nil
        let selectedRangeForSnapshot = selectedRange
        let selectedToolForSnapshot = selectedTool
        let searchTextForSnapshot = searchText
        let visibleRecords = records.filter { record in
            let inRange: Bool
            if let customRange {
                inRange = customRange.contains(record.timestamp)
            } else {
                inRange = selectedRangeForSnapshot.contains(record.timestamp, now: now)
            }
            return inRange
                && (selectedToolForSnapshot == nil || selectedToolForSnapshot == record.source)
                && (searchTextForSnapshot.isEmpty || record.accountId.localizedCaseInsensitiveContains(searchTextForSnapshot) || record.model.localizedCaseInsensitiveContains(searchTextForSnapshot) || record.apiKeyHash.localizedCaseInsensitiveContains(searchTextForSnapshot))
        }

        let today = AggregationEngine.aggregate(records: records, range: .today, now: now)
        let week = AggregationEngine.aggregate(records: records, range: .week, now: now)
        let month = AggregationEngine.aggregate(records: records, range: .month, now: now)
        let selected = visibleRecords.reduce(into: AggregatedUsage()) { partial, record in
            partial.inputTokens += record.inputTokens
            partial.outputTokens += record.outputTokens
            partial.cacheTokens += record.cacheTokens
            partial.totalTokens += record.totalTokens
            partial.estimatedCost += record.estimatedCost
        }
        let all = AggregationEngine.aggregate(records: records, range: .all, now: now)
        let trend = AggregationEngine.trend(records: records, range: selectedRangeForSnapshot, customRange: customRange, now: now)
        let toolGroups = Dictionary(grouping: visibleRecords, by: \.source).mapValues { rows in
            rows.reduce(into: AggregatedUsage()) { partial, record in
                partial.inputTokens += record.inputTokens
                partial.outputTokens += record.outputTokens
                partial.cacheTokens += record.cacheTokens
                partial.totalTokens += record.totalTokens
                partial.estimatedCost += record.estimatedCost
            }
        }
        let recentRecords = Array(visibleRecords.prefix(6))
        let usageByBudgetPeriod: [BudgetPeriod: AggregatedUsage] = [
            .daily: today,
            .weekly: week,
            .monthly: month
        ]
        let budgetRows = budgets.map { rule in
            BudgetProgressSnapshot(rule: rule, usage: usageByBudgetPeriod[rule.period] ?? AggregatedUsage(), mode: budgetProgressMode)
        }
        dashboardSnapshot = DashboardSnapshot(today: today, week: week, month: month, selected: selected, all: all, trend: trend, toolGroups: toolGroups, recentRecords: recentRecords, budgetRows: budgetRows)
    }

    public func activeRangeContains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if usesCustomDateRange {
            return customDateRange.contains(date, calendar: calendar)
        }
        return selectedRange.contains(date, calendar: calendar, now: now)
    }

    public func widgetSummary(now: Date = Date()) -> WidgetSummary {
        let today = aggregate(range: .today, now: now)
        let week = aggregate(range: .week, now: now)
        let month = aggregate(range: .month, now: now)
        let dailyBudget = budgets.first { $0.period == .daily } ?? BudgetRule(period: .daily, tokenLimit: 1, costLimit: 1)
        let toolTotals = AggregationEngine.groupByTool(records: records, range: .today, now: now).mapKeys { $0.rawValue }.mapValues { $0.totalTokens }
        let modelTotals = AggregationEngine.groupByModel(records: records, range: .today, now: now).mapValues { $0.totalTokens }
        return WidgetSummary(generatedAt: now, todayTokens: today.totalTokens, weekTokens: week.totalTokens, monthTokens: month.totalTokens, todayCost: today.estimatedCost, weekCost: week.estimatedCost, monthCost: month.estimatedCost, budgetProgress: BudgetEngine.progress(usage: today, rule: dailyBudget, mode: budgetProgressMode), toolTotals: toolTotals, modelTotals: modelTotals, trend: AggregationEngine.trend(records: records, range: .today, now: now))
    }

    public func setPricing(_ item: ModelPricing) {
        if let index = pricing.firstIndex(where: { $0.tool == item.tool && $0.model.caseInsensitiveCompare(item.model) == .orderedSame }) {
            pricing[index] = item
        } else {
            pricing.append(item)
        }
        repository.upsertPricing(item)
    }

    public func saveAllPricing() {
        repository.savePricing(pricing)
    }

    public func setBudget(_ item: BudgetRule) {
        if let index = budgets.firstIndex(where: { $0.period == item.period }) {
            budgets[index] = item
        } else {
            budgets.append(item)
            budgets = Self.orderedBudgets(budgets)
        }
        repository.upsertBudget(item)
    }

    public func saveAllBudgets() {
        budgets = Self.orderedBudgets(budgets)
        repository.saveBudgets(budgets)
    }

    public static func defaultSources() -> [UsageSource] {
        ToolKind.allCases.map { tool in
            UsageSource(tool: tool, name: "\(tool.rawValue) 自动发现", accountId: "auto-\(tool.rawValue.lowercased())", apiKeyIdentity: "auto-discovered", localLogPath: "")
        }
    }

    public static func defaultBudgets() -> [BudgetRule] {
        [
            BudgetRule(period: .daily, tokenLimit: 100_000, costLimit: 10),
            BudgetRule(period: .weekly, tokenLimit: 500_000, costLimit: 50),
            BudgetRule(period: .monthly, tokenLimit: 2_000_000, costLimit: 200)
        ]
    }

    public static func orderedBudgets(_ budgets: [BudgetRule]) -> [BudgetRule] {
        BudgetPeriod.allCases.compactMap { period in budgets.first { $0.period == period } }
    }

    public static func defaultPricing() -> [ModelPricing] {
        [
            ModelPricing(tool: .claudeCode, model: "claude-sonnet-4.5", inputPerMillion: 3, outputPerMillion: 15, cachePerMillion: 0.3),
            ModelPricing(tool: .claudeCode, model: "claude-opus-4.1", inputPerMillion: 15, outputPerMillion: 75, cachePerMillion: 1.5),
            ModelPricing(tool: .codeX, model: "gpt-5.1-codex", inputPerMillion: 5, outputPerMillion: 20, cachePerMillion: 0.5),
            ModelPricing(tool: .codeX, model: "gpt-5-mini", inputPerMillion: 0.5, outputPerMillion: 2, cachePerMillion: 0.1),
            ModelPricing(tool: .hermes, model: "gpt-5.5", inputPerMillion: 5, outputPerMillion: 20, cachePerMillion: 0.5),
            ModelPricing(tool: .hermes, model: "claude-sonnet-4", inputPerMillion: 3, outputPerMillion: 15, cachePerMillion: 0.3),
            ModelPricing(tool: .openClaw, model: "openclaw-agent", inputPerMillion: 1, outputPerMillion: 3, cachePerMillion: 0.1),
            ModelPricing(tool: .openClaw, model: "qwen3-coder", inputPerMillion: 0.8, outputPerMillion: 2.4, cachePerMillion: 0.08),
            ModelPricing(tool: .openCode, model: "opencode", inputPerMillion: 1, outputPerMillion: 3, cachePerMillion: 0.1),
            ModelPricing(tool: .openCode, model: "claude-sonnet-4", inputPerMillion: 3, outputPerMillion: 15, cachePerMillion: 0.3),
            ModelPricing(tool: .openCode, model: "gpt-5.1-codex", inputPerMillion: 5, outputPerMillion: 20, cachePerMillion: 0.5)
        ]
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}
