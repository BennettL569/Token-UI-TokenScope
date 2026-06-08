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
    @Published public private(set) var records: [UsageRecord] = [] {
        didSet { invalidateAggregateCaches() }
    }
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

    /// Filter-independent aggregates (today / week / month / all). These depend only on
    /// `records` and the current calendar day — NOT on searchText / selectedTool /
    /// selectedRange — so they are cached and reused across the frequent filter changes
    /// instead of re-walking the entire record set on every keystroke.
    private struct BaseAggregateCache {
        var day: Date
        var today: AggregatedUsage
        var week: AggregatedUsage
        var month: AggregatedUsage
        var all: AggregatedUsage
    }
    private var baseAggregateCache: BaseAggregateCache?

    /// Trend buckets depend only on the active range (+ records + day), not on
    /// searchText / selectedTool, so they are cached keyed by the active range.
    private struct TrendCache {
        var key: String
        var buckets: [TrendBucket]
    }
    private var trendCache: TrendCache?

    /// Serial queue for pricing/budget persistence. The pricing and budget tables are
    /// edited via SwiftUI bindings that fire on every keystroke; writing them through this
    /// queue keeps the SQLite work off the main thread while still serializing writes so the
    /// last edit wins. The repository itself is internally locked and Sendable.
    private let writeQueue = DispatchQueue(label: "com.tokenscope.repository-write", qos: .utility)

    private func invalidateAggregateCaches() {
        baseAggregateCache = nil
        trendCache = nil
    }

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
        // The repository is thread-safe (NSLock) and Sendable, so its heavy synchronous
        // work (writing new rows, reloading the full table) is run off the main thread via
        // detached tasks; only the UI-facing @Published mutations happen on the main actor.
        let repo = repository
        if fullScan { await Task.detached { repo.clearRefreshCursors() }.value }
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
                let newRecords = try await adapter.refresh(source: source, pricing: pricing, cursorStore: repo, fullScan: fullScan)
                await Task.detached { repo.upsert(newRecords) }.value
                refreshedSources[index].syncStatus = SyncStatus(kind: .success, lastSync: Date(), message: "已同步 \(newRecords.count) 条新增/更新")
            } catch {
                errors.append("\(source.tool.rawValue): \(error.localizedDescription)")
                refreshedSources[index].syncStatus = SyncStatus(kind: .failed, lastSync: Date(), message: error.localizedDescription)
            }
        }
        sources = refreshedSources
        let reloaded = await Task.detached { repo.all() }.value
        records = reloaded
        rebuildDashboardSnapshot()
        // The widget summary walks the full record set several times; compute it off-main.
        let budgetsSnapshot = budgets
        let mode = budgetProgressMode
        let summary = await Task.detached { UsageStore.makeWidgetSummary(records: reloaded, budgets: budgetsSnapshot, budgetProgressMode: mode) }.value
        try? WidgetSummaryStore.save(summary)
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        refreshProgress = errors.isEmpty ? "同步完成：\(records.count) 条" : "同步完成，有 \(errors.count) 个错误"
        isRefreshing = false
    }

    @MainActor
    public func rebuildAllData() async {
        let repo = repository
        await Task.detached { repo.clear() }.value
        records = []
        rebuildDashboardSnapshot()
        await refreshAll(fullScan: true)
    }

    @MainActor
    public func clearLocalData() async {
        let repo = repository
        await Task.detached { repo.clear() }.value
        records = []
        rebuildDashboardSnapshot()
    }

    public func filteredRecords(now: Date = Date()) -> [UsageRecord] {
        // Precompute the active-range bounds once (cheap timestamp comparisons per record)
        // instead of calling Calendar membership for every row — this is re-run on every
        // keystroke by the details view / export, over the full record set.
        let bounds = ActiveRangeBounds(range: selectedRange, customRange: usesCustomDateRange ? customDateRange : nil, now: now, calendar: .current)
        let search = searchText
        let tool = selectedTool
        let hasSearch = !search.isEmpty
        return records.filter { record in
            guard bounds.contains(record.timestamp) else { return false }
            if let tool, tool != record.source { return false }
            if hasSearch {
                return record.accountId.localizedCaseInsensitiveContains(search)
                    || record.model.localizedCaseInsensitiveContains(search)
                    || record.apiKeyHash.localizedCaseInsensitiveContains(search)
            }
            return true
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
        let calendar = Calendar.current
        let customRange = usesCustomDateRange ? customDateRange : nil
        let selectedRangeForSnapshot = selectedRange
        let selectedToolForSnapshot = selectedTool
        let searchTextForSnapshot = searchText

        // (1) Filter-independent aggregates — cached per (records, calendar day). These do
        // not depend on the active range / tool / search text, so a keystroke in the search
        // field reuses them instead of re-walking the record set four more times.
        let base: BaseAggregateCache
        if let cached = baseAggregateCache, calendar.isDate(cached.day, inSameDayAs: now) {
            base = cached
        } else {
            base = BaseAggregateCache(
                day: now,
                today: AggregationEngine.aggregate(records: records, range: .today, now: now, calendar: calendar),
                week: AggregationEngine.aggregate(records: records, range: .week, now: now, calendar: calendar),
                month: AggregationEngine.aggregate(records: records, range: .month, now: now, calendar: calendar),
                all: AggregationEngine.aggregate(records: records, range: .all, now: now, calendar: calendar)
            )
            baseAggregateCache = base
        }

        // (2) Trend — depends only on the active range (+ records + day). Cached by range key,
        // so it is not recomputed when only searchText / selectedTool change.
        let trendKey = Self.trendCacheKey(range: selectedRangeForSnapshot, customRange: customRange, now: now, calendar: calendar)
        let trend: [TrendBucket]
        if let cached = trendCache, cached.key == trendKey {
            trend = cached.buckets
        } else {
            trend = AggregationEngine.trend(records: records, range: selectedRangeForSnapshot, customRange: customRange, now: now, calendar: calendar)
            trendCache = TrendCache(key: trendKey, buckets: trend)
        }

        // (3) Filter-dependent values — computed in a single pass over `records` using
        // precomputed active-range bounds (cheap timestamp comparisons) instead of a
        // per-record Calendar membership call. `records` is ordered newest-first, so the
        // first six matches are the most recent ones (matching the previous prefix(6)).
        let bounds = ActiveRangeBounds(range: selectedRangeForSnapshot, customRange: customRange, now: now, calendar: calendar)
        let hasSearch = !searchTextForSnapshot.isEmpty
        var selected = AggregatedUsage()
        var toolGroups: [ToolKind: AggregatedUsage] = [:]
        var recentRecords: [UsageRecord] = []
        recentRecords.reserveCapacity(6)
        for record in records {
            guard bounds.contains(record.timestamp) else { continue }
            if let selectedToolForSnapshot, selectedToolForSnapshot != record.source { continue }
            if hasSearch {
                guard record.accountId.localizedCaseInsensitiveContains(searchTextForSnapshot)
                    || record.model.localizedCaseInsensitiveContains(searchTextForSnapshot)
                    || record.apiKeyHash.localizedCaseInsensitiveContains(searchTextForSnapshot) else { continue }
            }
            selected.inputTokens += record.inputTokens
            selected.outputTokens += record.outputTokens
            selected.cacheTokens += record.cacheTokens
            selected.totalTokens += record.totalTokens
            selected.estimatedCost += record.estimatedCost
            var group = toolGroups[record.source] ?? AggregatedUsage()
            group.inputTokens += record.inputTokens
            group.outputTokens += record.outputTokens
            group.cacheTokens += record.cacheTokens
            group.totalTokens += record.totalTokens
            group.estimatedCost += record.estimatedCost
            toolGroups[record.source] = group
            if recentRecords.count < 6 { recentRecords.append(record) }
        }

        let usageByBudgetPeriod: [BudgetPeriod: AggregatedUsage] = [
            .daily: base.today,
            .weekly: base.week,
            .monthly: base.month
        ]
        let budgetRows = budgets.map { rule in
            BudgetProgressSnapshot(rule: rule, usage: usageByBudgetPeriod[rule.period] ?? AggregatedUsage(), mode: budgetProgressMode)
        }
        dashboardSnapshot = DashboardSnapshot(today: base.today, week: base.week, month: base.month, selected: selected, all: base.all, trend: trend, toolGroups: toolGroups, recentRecords: recentRecords, budgetRows: budgetRows)
    }

    private static func trendCacheKey(range: TimeRange, customRange: CustomDateRange?, now: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: now).timeIntervalSince1970
        if let customRange {
            return "custom|\(customRange.start.timeIntervalSince1970)|\(customRange.end.timeIntervalSince1970)|\(day)"
        }
        return "range|\(range.rawValue)|\(day)"
    }

    public func activeRangeContains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if usesCustomDateRange {
            return customDateRange.contains(date, calendar: calendar)
        }
        return selectedRange.contains(date, calendar: calendar, now: now)
    }

    public func widgetSummary(now: Date = Date()) -> WidgetSummary {
        Self.makeWidgetSummary(records: records, budgets: budgets, budgetProgressMode: budgetProgressMode, now: now)
    }

    /// Pure, off-actor-callable widget-summary computation. Takes only Sendable inputs so it
    /// can run inside a detached task (it walks the full record set several times).
    public static func makeWidgetSummary(records: [UsageRecord], budgets: [BudgetRule], budgetProgressMode: BudgetProgressMode, now: Date = Date()) -> WidgetSummary {
        let today = AggregationEngine.aggregate(records: records, range: .today, now: now)
        let week = AggregationEngine.aggregate(records: records, range: .week, now: now)
        let month = AggregationEngine.aggregate(records: records, range: .month, now: now)
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
        let repo = repository
        writeQueue.async { repo.upsertPricing(item) }
    }

    public func saveAllPricing() {
        let repo = repository
        let snapshot = pricing
        writeQueue.async { repo.savePricing(snapshot) }
    }

    public func setBudget(_ item: BudgetRule) {
        if let index = budgets.firstIndex(where: { $0.period == item.period }) {
            budgets[index] = item
        } else {
            budgets.append(item)
            budgets = Self.orderedBudgets(budgets)
        }
        let repo = repository
        writeQueue.async { repo.upsertBudget(item) }
    }

    public func saveAllBudgets() {
        budgets = Self.orderedBudgets(budgets)
        let repo = repository
        let snapshot = budgets
        writeQueue.async { repo.saveBudgets(snapshot) }
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

/// Precomputed time bounds for the active range, so membership is a couple of cheap
/// `Date` comparisons per record instead of a `Calendar` granularity call per record.
/// The bounds are derived to match `TimeRange.contains` / `CustomDateRange.contains`
/// exactly: today/week/month are half-open `[start, end)` intervals (equivalent to
/// `Calendar.isDate(_:equalTo:toGranularity:)`), and the custom range is the closed
/// `[startOfDay(start), 23:59:59(end)]` interval `CustomDateRange.contains` uses.
private struct ActiveRangeBounds {
    private enum Kind {
        case all
        case halfOpen(Date, Date)
        case closed(Date, Date)
    }
    private let kind: Kind

    init(range: TimeRange, customRange: CustomDateRange?, now: Date, calendar: Calendar) {
        if let customRange {
            let start = calendar.startOfDay(for: customRange.start)
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: customRange.end) ?? customRange.end
            kind = .closed(start, end)
            return
        }
        switch range {
        case .all:
            kind = .all
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            kind = .halfOpen(start, end)
        case .week:
            if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                kind = .halfOpen(interval.start, interval.end)
            } else {
                kind = .all
            }
        case .month:
            if let interval = calendar.dateInterval(of: .month, for: now) {
                kind = .halfOpen(interval.start, interval.end)
            } else {
                kind = .all
            }
        }
    }

    func contains(_ date: Date) -> Bool {
        switch kind {
        case .all:
            return true
        case .halfOpen(let start, let end):
            return date >= start && date < end
        case .closed(let start, let end):
            return date >= start && date <= end
        }
    }
}
