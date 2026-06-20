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

// `@unchecked Sendable`: the store is a main-thread-confined UI hub. Its mutable `@Published`
// state is only read/written on the main thread; the only background work (the dashboard
// aggregation) reads an immutable Sendable input snapshot and applies its result back on main.
public final class UsageStore: ObservableObject, @unchecked Sendable {
    @Published public private(set) var records: [UsageRecord] = []
    @Published public private(set) var dashboardSnapshot = DashboardSnapshot()
    @Published public var sources: [UsageSource]
    @Published public var pricing: [ModelPricing]
    @Published public var budgets: [BudgetRule] {
        didSet { scheduleDashboardRebuild() }
    }
    @Published public var selectedRange: TimeRange = .today {
        didSet { scheduleDashboardRebuild() }
    }
    @Published public var usesCustomDateRange = false {
        didSet { scheduleDashboardRebuild() }
    }
    @Published public var customDateRange: CustomDateRange {
        didSet { scheduleDashboardRebuild() }
    }
    @Published public var searchText: String = "" {
        didSet { scheduleDashboardRebuild() }
    }
    @Published public var selectedTool: ToolKind? {
        didSet { scheduleDashboardRebuild() }
    }
    @Published public var errorMessage: String?
    @Published public var isRefreshing = false
    @Published public var menuBarShowsCost = false
    /// UI language. Defaults to English; the choice is persisted to `UserDefaults` and applied
    /// live (every view observing the store re-renders when it changes).
    @Published public var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageDefaultsKey)
        }
    }
    @Published public var refreshProgress: String = ""
    @Published public var budgetProgressMode: BudgetProgressMode = .tokens {
        didSet { scheduleDashboardRebuild() }
    }

    private let repository: PersistentUsageRepository
    private let registry: AdapterRegistry

    static let languageDefaultsKey = "TokenScopeLanguage"
    /// Bumped whenever token parsing changes in a way that makes previously-imported records
    /// wrong. On launch, a stored value behind this triggers a one-time full reparse so the fix
    /// reaches historical data (incremental sync alone only re-reads newly appended log bytes).
    /// v2: Claude cache-creation double-count fixed; Codex cached/reasoning tokens de-duplicated.
    /// v3: record the cache-creation (write) portion of cache tokens separately.
    /// v4: Codex records carry the real model (e.g. gpt-5.5) read from the turn's `turn_context`
    ///     event instead of a hardcoded "codex".
    static let parserVersion = 4
    static let parserVersionDefaultsKey = "TokenScopeParserVersion"

    /// Localizes an inline English/Chinese pair for the current `language`.
    public func L(_ english: String, _ chinese: String) -> String {
        language.select(english, chinese)
    }

    /// Monotonic id for the latest scheduled dashboard rebuild. Filter changes (range / custom
    /// date / search / tool / budget) run the heavy aggregation off the main thread; only the
    /// newest generation's result is published, so superseded results are discarded. Walking the
    /// full record set therefore never blocks the UI, no matter how large the dataset is.
    private var rebuildGeneration = 0

    /// Serial queue for pricing/budget persistence. The pricing and budget tables are
    /// edited via SwiftUI bindings that fire on every keystroke; writing them through this
    /// queue keeps the SQLite work off the main thread while still serializing writes so the
    /// last edit wins. The repository itself is internally locked and Sendable.
    private let writeQueue = DispatchQueue(label: "com.tokenscope.repository-write", qos: .utility)

    public init(repository: PersistentUsageRepository = PersistentUsageRepository(), registry: AdapterRegistry = AdapterRegistry()) {
        self.repository = repository
        self.registry = registry
        self.language = UserDefaults.standard.string(forKey: Self.languageDefaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .english
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
        refreshProgress = fullScan ? L("Preparing full rescan", "准备全量重读") : L("Preparing incremental sync", "准备增量同步")
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
            let modeText = fullScan ? L("Full read in progress", "全量读取中") : L("Incremental read in progress", "增量读取中")
            refreshedSources[index].syncStatus = SyncStatus(kind: .syncing, lastSync: Date(), message: modeText)
            sources = refreshedSources
            refreshProgress = L("Reading \(source.tool.rawValue)…", "正在\(fullScan ? "全量" : "增量")读取 \(source.tool.rawValue)…")
            do {
                let newRecords = try await adapter.refresh(source: source, pricing: pricing, cursorStore: repo, fullScan: fullScan)
                await Task.detached { repo.upsert(newRecords) }.value
                refreshedSources[index].syncStatus = SyncStatus(kind: .success, lastSync: Date(), message: L("Synced \(newRecords.count) new/updated", "已同步 \(newRecords.count) 条新增/更新"))
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
        refreshProgress = errors.isEmpty ? L("Sync complete: \(records.count) records", "同步完成：\(records.count) 条") : L("Sync finished with \(errors.count) error(s)", "同步完成，有 \(errors.count) 个错误")
        isRefreshing = false
    }

    /// Entry point for the app's launch refresh. If the parser was corrected since the data was
    /// last imported, reparse everything once so historical records reflect the fix; otherwise
    /// only do the normal incremental refresh when there is nothing loaded yet.
    @MainActor
    public func refreshOnLaunch() async {
        let storedParserVersion = UserDefaults.standard.integer(forKey: Self.parserVersionDefaultsKey)
        if storedParserVersion < Self.parserVersion {
            // A parser-version bump can newly recognize models that didn't exist before (Codex
            // gpt-5.5 / gpt-5.4 / gpt-5.4-mini, surfaced once the real model replaced the hardcoded
            // "codex"). Seed their default pricing before the reparse so cost estimates are right;
            // otherwise they fall through to the generic pricing fallback.
            mergeMissingDefaultPricing(for: Self.modelsAddedInParserV4)
            await rebuildAllData()
            // Record the version only after the seed + reparse complete, so an upgrade interrupted
            // partway re-runs cleanly next launch instead of being silently skipped.
            UserDefaults.standard.set(Self.parserVersion, forKey: Self.parserVersionDefaultsKey)
        } else if records.isEmpty {
            await refreshAll()
        }
    }

    /// `(tool, model)` pairs first recognized in parser version 4. Deliberately narrow: re-seeding
    /// the whole default set would resurrect default rows a user deleted via the deletable-pricing
    /// feature. These models only began appearing once the real Codex model replaced "codex", so
    /// they cannot have existed — let alone been deleted — in a pre-v4 database.
    public static let modelsAddedInParserV4: [(tool: ToolKind, model: String)] = [
        (.codeX, "gpt-5.5"), (.codeX, "gpt-5.4"), (.codeX, "gpt-5.4-mini")
    ]

    /// Pure merge (exposed for testing): `existing` plus any `defaults` row matching an allowlisted
    /// `(tool, model)` that is absent from `existing`. Model names compare case-insensitively, to
    /// match the rest of the pricing system; user-edited rows are never overwritten.
    public static func pricingByAddingMissingDefaults(_ allow: [(tool: ToolKind, model: String)], to existing: [ModelPricing], from defaults: [ModelPricing]) -> [ModelPricing] {
        let key: (ToolKind, String) -> String = { "\($0.rawValue)\u{1}\($1.lowercased())" }
        let known = Set(existing.map { key($0.tool, $0.model) })
        let allowed = Set(allow.map { key($0.tool, $0.model) })
        let missing = defaults.filter { allowed.contains(key($0.tool, $0.model)) && !known.contains(key($0.tool, $0.model)) }
        return missing.isEmpty ? existing : existing + missing
    }

    /// Adds default pricing rows for the allowlisted models that the persisted table is missing.
    /// The fresh-install seed in `init` only runs on an empty table, so this is how upgrading users
    /// receive pricing for models added in a later release.
    private func mergeMissingDefaultPricing(for allow: [(tool: ToolKind, model: String)]) {
        let merged = Self.pricingByAddingMissingDefaults(allow, to: pricing, from: Self.defaultPricing())
        guard merged.count != pricing.count else { return }
        pricing = merged
        let snapshot = pricing
        let repo = repository
        writeQueue.async { repo.savePricing(snapshot) }
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

    /// Synchronous rebuild used at init, after a refresh, and by tests. Bumps the generation so an
    /// in-flight off-main rebuild's (now stale) result is discarded instead of overwriting this.
    public func rebuildDashboardSnapshot(now: Date = Date()) {
        rebuildGeneration &+= 1
        dashboardSnapshot = Self.computeSnapshot(snapshotInputs(now: now))
    }

    /// Schedules a dashboard rebuild OFF the main thread, coalescing rapid filter changes so only
    /// the latest one is published. This is what every filter `didSet` calls: walking the full
    /// record set (Calendar-heavy trend bucketing, Decimal accumulation) no longer blocks the
    /// main thread, so changing the range / dates / search / tool never drops frames.
    private func scheduleDashboardRebuild() {
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        let input = snapshotInputs(now: Date())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = UsageStore.computeSnapshot(input)
            DispatchQueue.main.async {
                guard let self, self.rebuildGeneration == generation else { return }
                self.dashboardSnapshot = snapshot
            }
        }
    }

    private func snapshotInputs(now: Date) -> SnapshotInputs {
        SnapshotInputs(
            records: records,
            selectedRange: selectedRange,
            customRange: usesCustomDateRange ? customDateRange : nil,
            searchText: searchText,
            selectedTool: selectedTool,
            budgets: budgets,
            budgetProgressMode: budgetProgressMode,
            now: now
        )
    }

    /// All inputs the dashboard snapshot depends on. Sendable, so the computation can run inside a
    /// detached task off the main actor.
    private struct SnapshotInputs: Sendable {
        let records: [UsageRecord]
        let selectedRange: TimeRange
        let customRange: CustomDateRange?
        let searchText: String
        let selectedTool: ToolKind?
        let budgets: [BudgetRule]
        let budgetProgressMode: BudgetProgressMode
        let now: Date
    }

    private struct BaseAggregates {
        var today: AggregatedUsage
        var week: AggregatedUsage
        var month: AggregatedUsage
        var all: AggregatedUsage
    }

    /// Pure dashboard computation over a Sendable input snapshot. Safe to run off the main actor.
    private static func computeSnapshot(_ input: SnapshotInputs) -> DashboardSnapshot {
        let calendar = Calendar.current
        let now = input.now
        let records = input.records
        let customRange = input.customRange

        // (1) Filter-independent aggregates (today / week / month / all) in one bounds pass.
        let base = computeBaseAggregates(records: records, now: now, calendar: calendar)

        // (2) Trend for the active range.
        let trend = AggregationEngine.trend(records: records, range: input.selectedRange, customRange: customRange, now: now, calendar: calendar)

        // (3) Filter-dependent values in a single pass using precomputed active-range bounds.
        // `records` is ordered newest-first, so the first six matches are the most recent ones.
        let bounds = ActiveRangeBounds(range: input.selectedRange, customRange: customRange, now: now, calendar: calendar)
        let search = input.searchText
        let hasSearch = !search.isEmpty
        let selectedTool = input.selectedTool
        var selected = AggregatedUsage()
        var toolGroups: [ToolKind: AggregatedUsage] = [:]
        var recentRecords: [UsageRecord] = []
        recentRecords.reserveCapacity(6)
        for record in records {
            guard bounds.contains(record.timestamp) else { continue }
            if let selectedTool, selectedTool != record.source { continue }
            if hasSearch {
                guard record.accountId.localizedCaseInsensitiveContains(search)
                    || record.model.localizedCaseInsensitiveContains(search)
                    || record.apiKeyHash.localizedCaseInsensitiveContains(search) else { continue }
            }
            accumulate(&selected, record)
            var group = toolGroups[record.source] ?? AggregatedUsage()
            accumulate(&group, record)
            toolGroups[record.source] = group
            if recentRecords.count < 6 { recentRecords.append(record) }
        }

        let usageByBudgetPeriod: [BudgetPeriod: AggregatedUsage] = [
            .daily: base.today,
            .weekly: base.week,
            .monthly: base.month
        ]
        let budgetRows = input.budgets.map { rule in
            BudgetProgressSnapshot(rule: rule, usage: usageByBudgetPeriod[rule.period] ?? AggregatedUsage(), mode: input.budgetProgressMode)
        }
        return DashboardSnapshot(today: base.today, week: base.week, month: base.month, selected: selected, all: base.all, trend: trend, toolGroups: toolGroups, recentRecords: recentRecords, budgetRows: budgetRows)
    }

    /// Computes today/week/month/all in a single pass using precomputed half-open bounds (cheap
    /// `Date` comparisons), matching `TimeRange.contains` exactly.
    private static func computeBaseAggregates(records: [UsageRecord], now: Date, calendar: Calendar) -> BaseAggregates {
        let todayBounds = ActiveRangeBounds(range: .today, customRange: nil, now: now, calendar: calendar)
        let weekBounds = ActiveRangeBounds(range: .week, customRange: nil, now: now, calendar: calendar)
        let monthBounds = ActiveRangeBounds(range: .month, customRange: nil, now: now, calendar: calendar)
        var today = AggregatedUsage()
        var week = AggregatedUsage()
        var month = AggregatedUsage()
        var all = AggregatedUsage()
        for record in records {
            let timestamp = record.timestamp
            accumulate(&all, record)
            if todayBounds.contains(timestamp) { accumulate(&today, record) }
            if weekBounds.contains(timestamp) { accumulate(&week, record) }
            if monthBounds.contains(timestamp) { accumulate(&month, record) }
        }
        return BaseAggregates(today: today, week: week, month: month, all: all)
    }

    private static func accumulate(_ aggregate: inout AggregatedUsage, _ record: UsageRecord) {
        aggregate.inputTokens += record.inputTokens
        aggregate.outputTokens += record.outputTokens
        aggregate.cacheTokens += record.cacheTokens
        aggregate.cacheCreationTokens += record.cacheCreationTokens
        aggregate.totalTokens += record.totalTokens
        aggregate.estimatedCost += record.estimatedCost
        aggregate.requestCount += 1
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

    public func deletePricing(_ item: ModelPricing) {
        pricing.removeAll { $0.id == item.id }
        let repo = repository
        writeQueue.async { repo.deletePricing(item) }
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
            UsageSource(tool: tool, name: "\(tool.rawValue) auto-discovery", accountId: "auto-\(tool.rawValue.lowercased())", apiKeyIdentity: "auto-discovered", localLogPath: "")
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
            ModelPricing(tool: .codeX, model: "gpt-5.5", inputPerMillion: 5, outputPerMillion: 20, cachePerMillion: 0.5),
            ModelPricing(tool: .codeX, model: "gpt-5.4", inputPerMillion: 5, outputPerMillion: 20, cachePerMillion: 0.5),
            ModelPricing(tool: .codeX, model: "gpt-5.4-mini", inputPerMillion: 0.5, outputPerMillion: 2, cachePerMillion: 0.1),
            ModelPricing(tool: .codeX, model: "gpt-5.1-codex", inputPerMillion: 5, outputPerMillion: 20, cachePerMillion: 0.5),
            ModelPricing(tool: .codeX, model: "gpt-5-mini", inputPerMillion: 0.5, outputPerMillion: 2, cachePerMillion: 0.1),
            ModelPricing(tool: .hermes, model: "gpt-5.5", inputPerMillion: 5, outputPerMillion: 20, cachePerMillion: 0.5),
            ModelPricing(tool: .hermes, model: "claude-sonnet-4", inputPerMillion: 3, outputPerMillion: 15, cachePerMillion: 0.3),
            ModelPricing(tool: .openClaw, model: "openclaw-agent", inputPerMillion: 1, outputPerMillion: 3, cachePerMillion: 0.1),
            ModelPricing(tool: .openClaw, model: "qwen3-coder", inputPerMillion: 0.8, outputPerMillion: 2.4, cachePerMillion: 0.08),
            ModelPricing(tool: .openCode, model: "opencode", inputPerMillion: 1, outputPerMillion: 3, cachePerMillion: 0.1),
            ModelPricing(tool: .openCode, model: "claude-sonnet-4", inputPerMillion: 3, outputPerMillion: 15, cachePerMillion: 0.3),
            ModelPricing(tool: .openCode, model: "gpt-5.1-codex", inputPerMillion: 5, outputPerMillion: 20, cachePerMillion: 0.5),
            ModelPricing(tool: .qoder, model: "qoder", inputPerMillion: 1, outputPerMillion: 3, cachePerMillion: 0.1),
            ModelPricing(tool: .qoder, model: "claude-sonnet-4", inputPerMillion: 3, outputPerMillion: 15, cachePerMillion: 0.3)
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
