import Foundation

public struct AdapterCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let supportsLiveAPI = AdapterCapabilities(rawValue: 1 << 0)
    public static let supportsLocalLogs = AdapterCapabilities(rawValue: 1 << 1)
    public static let supportsImport = AdapterCapabilities(rawValue: 1 << 2)
    public static let supportsCostEstimation = AdapterCapabilities(rawValue: 1 << 3)
}

public protocol UsageAdapter: Sendable {
    var id: String { get }
    var tool: ToolKind { get }
    var displayName: String { get }
    var capabilities: AdapterCapabilities { get }
    func refresh(source: UsageSource, pricing: [ModelPricing], cursorStore: UsageCursorStore?, fullScan: Bool) async throws -> [UsageRecord]
}

public protocol UsageCursorStore: Sendable {
    func refreshCursor(source: ToolKind, rawSource: String) -> Double?
    func setRefreshCursor(source: ToolKind, rawSource: String, position: Double)
    /// Per-file resume model for stateful JSONL adapters whose usage events don't name the model on
    /// every line — Codex announces it once per turn in a `turn_context`. Persisting it lets an
    /// incremental read that resumes mid-turn (past that `turn_context`) keep the real model instead
    /// of falling back to "codex". Default no-ops, so stores/adapters that don't need it are unaffected.
    func refreshCursorModel(source: ToolKind, rawSource: String) -> String?
    func setRefreshCursor(source: ToolKind, rawSource: String, position: Double, model: String?)
}

public extension UsageCursorStore {
    func refreshCursorModel(source: ToolKind, rawSource: String) -> String? { nil }
    func setRefreshCursor(source: ToolKind, rawSource: String, position: Double, model: String?) {
        setRefreshCursor(source: source, rawSource: rawSource, position: position)
    }
}

public enum AdapterError: Error, LocalizedError {
    case sourceDisabled
    case unsupportedSource

    public var errorDescription: String? {
        switch self {
        case .sourceDisabled: return "数据源未启用"
        case .unsupportedSource: return "数据源暂不支持"
        }
    }
}

public struct PlaceholderUsageAdapter: UsageAdapter {
    public let id: String
    public let tool: ToolKind
    public let displayName: String
    public let capabilities: AdapterCapabilities

    public init(tool: ToolKind) {
        self.id = tool.rawValue.lowercased()
        self.tool = tool
        self.displayName = tool.rawValue
        self.capabilities = [.supportsLocalLogs, .supportsImport, .supportsCostEstimation]
    }

    public func refresh(source: UsageSource, pricing: [ModelPricing], cursorStore: UsageCursorStore? = nil, fullScan: Bool = false) async throws -> [UsageRecord] {
        guard source.isEnabled else { throw AdapterError.sourceDisabled }
        let now = Date()
        let models = defaultModels(for: tool)
        return (0..<12).map { index in
            let model = models[index % models.count]
            let input = 900 + index * 173 + tool.rawValue.count * 13
            let output = 420 + index * 97 + tool.rawValue.count * 7
            let cache = index.isMultiple(of: 3) ? 260 + index * 11 : 0
            var record = UsageRecord(
                source: tool,
                accountId: source.accountId,
                apiKeyHash: source.apiKeyIdentity,
                model: model,
                timestamp: Calendar.current.date(byAdding: .hour, value: -index * 3, to: now) ?? now,
                inputTokens: input,
                outputTokens: output,
                cacheTokens: cache,
                requestId: "\(source.id.uuidString)-mock-\(index)",
                rawSource: "placeholder://\(tool.rawValue)/\(index)"
            )
            record.estimatedCost = PricingEngine.estimate(record: record, pricing: pricing)
            return record
        }
    }

    private func defaultModels(for tool: ToolKind) -> [String] {
        switch tool {
        case .claudeCode: return ["claude-sonnet-4.5", "claude-opus-4.1"]
        case .codeX: return ["gpt-5.5", "gpt-5.4"]
        case .hermes: return ["gpt-5.5", "claude-sonnet-4"]
        case .openClaw: return ["openclaw-agent", "qwen3-coder"]
        case .openCode: return ["opencode", "claude-sonnet-4"]
        case .qoder, .qoderCN: return ["qoder", "claude-sonnet-4"]
        case .zCode: return ["GLM-5.2", "GLM-5"]
        }
    }
}

public struct AdapterRegistry: Sendable {
    public var adapters: [ToolKind: any UsageAdapter]

    public init(adapters: [ToolKind : any UsageAdapter] = AdapterRegistry.defaultAdapters()) {
        self.adapters = adapters
    }

    public static func defaultAdapters() -> [ToolKind: any UsageAdapter] {
        [
            .claudeCode: LocalJSONLUsageAdapter(
                tool: .claudeCode,
                displayName: "ClaudeCode Local Logs",
                defaultGlobPatterns: ["~/.claude/projects/**/*.jsonl"],
                parser: LocalUsageParser.parseClaudeLine
            ),
            .codeX: LocalJSONLUsageAdapter(
                tool: .codeX,
                displayName: "Codex Local Sessions",
                defaultGlobPatterns: ["~/.codex/sessions/**/*.jsonl", "~/.codex/archived_sessions/*.jsonl"],
                statefulParser: { line, path, pricing, context in
                    // Usage events are the hot path (gigabytes of logs), so try them first: a
                    // `token_count` line short-circuits on its cheap substring gate. The model for
                    // those events is announced earlier, once per turn, in a `turn_context` line —
                    // remember it for the records that follow. A `turn_context` whose payload omits
                    // the model is intentionally a no-op (keep the last known model) rather than a
                    // reset to nil, which would revert those records to "codex".
                    if let record = LocalUsageParser.parseCodexLine(line, filePath: path, pricing: pricing, model: context.model) {
                        return record
                    }
                    if let model = LocalUsageParser.codexModel(fromLine: line) { context.model = model }
                    return nil
                }
            ),
            .hermes: HermesSQLiteUsageAdapter(),
            .openClaw: LocalJSONLUsageAdapter(
                tool: .openClaw,
                displayName: "OpenClaw Local Logs",
                defaultGlobPatterns: ["~/.openclaw/agents/*/sessions/*.jsonl"],
                parser: LocalUsageParser.parseOpenClawLine
            ),
            .openCode: OpenCodeSQLiteUsageAdapter(),
            .qoder: QoderSQLiteUsageAdapter(),
            .qoderCN: QoderSQLiteUsageAdapter(
                tool: .qoderCN,
                displayName: "Qoder CN SQLite",
                defaultPaths: ["~/Library/Application Support/QoderCN/SharedClientCache/cache/db/local.db"]
            ),
            .zCode: LocalJSONLUsageAdapter(
                tool: .zCode,
                displayName: "ZCode Local Rollout",
                defaultGlobPatterns: ["~/.zcode/cli/rollout/*.jsonl"],
                parser: LocalUsageParser.parseZCodeLine
            )
        ]
    }

    public func adapter(for tool: ToolKind) -> (any UsageAdapter)? {
        adapters[tool]
    }
}
