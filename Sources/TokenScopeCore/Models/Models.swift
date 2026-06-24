import Foundation

public enum ToolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode = "ClaudeCode"
    case codeX = "CodeX"
    case hermes = "Hermes"
    case openClaw = "OpenClaw"
    case openCode = "OpenCode"
    case qoder = "Qoder"
    case qoderCN = "QoderCN"
    case zCode = "ZCode"

    public var id: String { rawValue }

    /// Whether this tool reports cache *creation* (write) tokens as a distinct, billed category.
    /// Only Claude Code (Anthropic's API) does: OpenAI-style providers (Codex, Qoder) report cache
    /// *reads* only and have no cache-write concept, and the tools that do carry a cache-write field
    /// (Hermes, OpenCode, ZCode, …) are fed by providers that leave it 0. So for every tool except
    /// Claude Code a 0 means "not reported", not "measured zero" — the UI shows "N/A" instead of a
    /// misleading 0. A genuine non-zero is still shown (see `UsageRecord.showsCacheCreation`).
    public var reportsCacheCreation: Bool {
        self == .claudeCode
    }
}

public enum TimeRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case today = "今日"
    case week = "本周"
    case month = "本月"
    case all = "全部"

    public var id: String { rawValue }

    public func contains(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> Bool {
        switch self {
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .week:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .month:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .all:
            return true
        }
    }
}

public struct CustomDateRange: Codable, Equatable, Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        if start <= end {
            self.start = start
            self.end = end
        } else {
            self.start = end
            self.end = start
        }
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let startOfDay = calendar.startOfDay(for: start)
        let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: end) ?? end
        return date >= startOfDay && date <= endOfDay
    }
}

public enum SyncStatusKind: String, Codable, Sendable {
    case idle
    case syncing
    case success
    case warning
    case failed
}

public struct SyncStatus: Codable, Equatable, Hashable, Sendable {
    public var kind: SyncStatusKind
    public var lastSync: Date?
    public var message: String

    public init(kind: SyncStatusKind = .idle, lastSync: Date? = nil, message: String = "Not synced yet") {
        self.kind = kind
        self.lastSync = lastSync
        self.message = message
    }
}

public struct UsageRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: ToolKind
    public var accountId: String
    public var apiKeyHash: String
    public var model: String
    public var timestamp: Date
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheTokens: Int
    /// The portion of `cacheTokens` that is cache *creation* (a.k.a. cache write). The remainder
    /// is cache read (`cacheReadTokens`). Tracked separately so the UI can report cache creation.
    public var cacheCreationTokens: Int
    public var totalTokens: Int
    public var estimatedCost: Decimal
    public var requestId: String?
    public var dedupeKey: String
    public var rawSource: String

    /// Cache read tokens = total cache minus the cache-creation portion.
    public var cacheReadTokens: Int { max(0, cacheTokens - cacheCreationTokens) }

    /// Whether the cache-creation count is meaningful enough to render as a number rather than
    /// "N/A". Tools that report cache creation (Claude Code) always show their value, including a
    /// genuine 0; for every other tool a 0 means "not reported" and renders as "N/A", while a real
    /// non-zero (e.g. a future Anthropic-backed run routed through another tool) is still shown.
    public var showsCacheCreation: Bool {
        source.reportsCacheCreation || cacheCreationTokens > 0
    }

    public init(
        id: UUID = UUID(),
        source: ToolKind,
        accountId: String,
        apiKeyHash: String,
        model: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        cacheCreationTokens: Int = 0,
        estimatedCost: Decimal = 0,
        requestId: String? = nil,
        dedupeKey: String? = nil,
        rawSource: String
    ) {
        self.id = id
        self.source = source
        self.accountId = accountId
        self.apiKeyHash = apiKeyHash
        self.model = model
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.cacheCreationTokens = min(max(0, cacheCreationTokens), cacheTokens)
        self.totalTokens = inputTokens + outputTokens + cacheTokens
        self.estimatedCost = estimatedCost
        self.requestId = requestId
        self.rawSource = rawSource
        self.dedupeKey = dedupeKey ?? Dedupe.makeKey(source: source, requestId: requestId, timestamp: timestamp, model: model, inputTokens: inputTokens, outputTokens: outputTokens, cacheTokens: cacheTokens, rawSource: rawSource)
    }
}

public struct UsageSource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var tool: ToolKind
    public var name: String
    public var accountId: String
    public var apiKeyIdentity: String
    public var localLogPath: String
    public var isEnabled: Bool
    public var syncStatus: SyncStatus

    public init(id: UUID = UUID(), tool: ToolKind, name: String, accountId: String, apiKeyIdentity: String, localLogPath: String = "", isEnabled: Bool = true, syncStatus: SyncStatus = SyncStatus()) {
        self.id = id
        self.tool = tool
        self.name = name
        self.accountId = accountId
        self.apiKeyIdentity = apiKeyIdentity
        self.localLogPath = localLogPath
        self.isEnabled = isEnabled
        self.syncStatus = syncStatus
    }
}

public struct Account: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var tool: ToolKind
    public var displayName: String
}

public struct APIKeyIdentity: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var accountId: String
    public var maskedValue: String
    public var createdAt: Date
}

public struct ModelPricing: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(tool.rawValue)::\(model)" }
    public var tool: ToolKind
    public var model: String
    public var inputPerMillion: Decimal
    public var outputPerMillion: Decimal
    public var cachePerMillion: Decimal

    public init(tool: ToolKind, model: String, inputPerMillion: Decimal, outputPerMillion: Decimal, cachePerMillion: Decimal) {
        self.tool = tool
        self.model = model
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cachePerMillion = cachePerMillion
    }
}

public enum BudgetPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily = "每日"
    case weekly = "每周"
    case monthly = "每月"
    public var id: String { rawValue }
}

public enum BudgetAlertLevel: String, Codable, Sendable {
    case normal
    case warning
    case exceeded
}

public enum BudgetProgressMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case tokens = "Tokens"
    case cost = "费用"
    public var id: String { rawValue }
}

public struct BudgetRule: Identifiable, Codable, Hashable, Sendable {
    public var id: BudgetPeriod { period }
    public var period: BudgetPeriod
    public var tokenLimit: Int
    public var costLimit: Decimal

    public init(period: BudgetPeriod, tokenLimit: Int, costLimit: Decimal) {
        self.period = period
        self.tokenLimit = tokenLimit
        self.costLimit = costLimit
    }
}

public struct AggregatedUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheTokens: Int
    /// Cache-creation (write) portion of `cacheTokens`.
    public var cacheCreationTokens: Int
    public var totalTokens: Int
    public var estimatedCost: Decimal
    /// Number of usage records (≈ API requests) covered by this aggregate.
    public var requestCount: Int

    public var billableTokens: Int {
        inputTokens + outputTokens
    }

    /// Cache read portion = total cache minus the cache-creation portion.
    public var cacheReadTokens: Int { max(0, cacheTokens - cacheCreationTokens) }

    public var cacheHitRate: Double {
        let denominator = inputTokens + cacheTokens
        guard denominator > 0 else { return 0 }
        return Double(cacheTokens) / Double(denominator)
    }

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheTokens: Int = 0, cacheCreationTokens: Int = 0, totalTokens: Int = 0, estimatedCost: Decimal = 0, requestCount: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.requestCount = requestCount
    }
}

public struct BudgetProgressSnapshot: Identifiable, Equatable, Sendable {
    public var id: BudgetPeriod { rule.period }
    public var rule: BudgetRule
    public var usage: AggregatedUsage
    public var tokenProgress: Double
    public var costProgress: Double
    public var activeProgress: Double

    public init(rule: BudgetRule, usage: AggregatedUsage, mode: BudgetProgressMode) {
        self.rule = rule
        self.usage = usage
        self.tokenProgress = BudgetEngine.tokenProgress(usage: usage, rule: rule)
        self.costProgress = BudgetEngine.costProgress(usage: usage, rule: rule)
        self.activeProgress = BudgetEngine.progress(usage: usage, rule: rule, mode: mode)
    }
}

public struct DashboardSnapshot: Equatable, Sendable {
    public var today: AggregatedUsage
    public var week: AggregatedUsage
    public var month: AggregatedUsage
    public var selected: AggregatedUsage
    public var all: AggregatedUsage
    public var trend: [TrendBucket]
    public var toolGroups: [ToolKind: AggregatedUsage]
    public var recentRecords: [UsageRecord]
    public var budgetRows: [BudgetProgressSnapshot]

    public init(today: AggregatedUsage = AggregatedUsage(), week: AggregatedUsage = AggregatedUsage(), month: AggregatedUsage = AggregatedUsage(), selected: AggregatedUsage = AggregatedUsage(), all: AggregatedUsage = AggregatedUsage(), trend: [TrendBucket] = [], toolGroups: [ToolKind: AggregatedUsage] = [:], recentRecords: [UsageRecord] = [], budgetRows: [BudgetProgressSnapshot] = []) {
        self.today = today
        self.week = week
        self.month = month
        self.selected = selected
        self.all = all
        self.trend = trend
        self.toolGroups = toolGroups
        self.recentRecords = recentRecords
        self.budgetRows = budgetRows
    }
}

public struct TrendBucket: Identifiable, Codable, Hashable, Sendable {
    public var id: String { label }
    public var label: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheTokens: Int
    public var totalTokens: Int
}



public struct WidgetSummary: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var todayTokens: Int
    public var weekTokens: Int
    public var monthTokens: Int
    public var todayCost: Decimal
    public var weekCost: Decimal
    public var monthCost: Decimal
    public var budgetProgress: Double
    public var toolTotals: [String: Int]
    public var modelTotals: [String: Int]
    public var trend: [TrendBucket]

    public init(generatedAt: Date, todayTokens: Int, weekTokens: Int, monthTokens: Int, todayCost: Decimal, weekCost: Decimal, monthCost: Decimal, budgetProgress: Double, toolTotals: [String : Int], modelTotals: [String : Int], trend: [TrendBucket]) {
        self.generatedAt = generatedAt
        self.todayTokens = todayTokens
        self.weekTokens = weekTokens
        self.monthTokens = monthTokens
        self.todayCost = todayCost
        self.weekCost = weekCost
        self.monthCost = monthCost
        self.budgetProgress = budgetProgress
        self.toolTotals = toolTotals
        self.modelTotals = modelTotals
        self.trend = trend
    }
}
