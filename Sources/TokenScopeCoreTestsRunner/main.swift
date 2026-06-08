import Foundation
import SQLite3
import TokenScopeCore

@main
struct TokenScopeCoreTestsRunner {
    static func main() async throws {
        try pricingEngineCalculatesInputOutputAndCacheCost()
        try dedupeUsesRequestIdWhenAvailable()
        try dedupeFallbackIsStableForSamePayload()
        try maskingDoesNotExposeFullAPIKey()
        try aggregationFiltersToday()
        try aggregationFiltersCustomDateRange()
        try budgetAlertLevels()
        try exportRedactsIdentifiersByDefault()
        try await repositoryDeduplicatesRecords()
        try claudeParserReadsUsageLine()
        try codexParserReadsTokenCountLine()
        try openClawParserReadsUsageLine()
        try hermesParserIncludesReasoningTokens()
        try await hermesSQLiteAdapterUsesLatestMessageTimestamp()
        try openCodeParserReadsMessageRow()
        try openCodeParserReadsNestedTokensCacheShape()
        try await persistentRepositoryKeepsHistoricalRecords()
        try pricingPersistsInSQLite()
        try budgetsPersistInSQLite()
        try budgetProgressCanUseTokenOrCostMode()
        print("TokenScopeCoreTestsRunner: 20 checks passed")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message) }
    }

    static func pricingEngineCalculatesInputOutputAndCacheCost() throws {
        let pricing = ModelPricing(tool: .hermes, model: "gpt-5.5", inputPerMillion: 2, outputPerMillion: 10, cachePerMillion: 1)
        let cost = PricingEngine.estimate(inputTokens: 1_000_000, outputTokens: 500_000, cacheTokens: 250_000, pricing: pricing)
        try expect(abs(NSDecimalNumber(decimal: cost).doubleValue - 7.25) < 0.0001, "pricing cost mismatch")
    }

    static func dedupeUsesRequestIdWhenAvailable() throws {
        let key = Dedupe.makeKey(source: .hermes, requestId: "req_123", timestamp: Date(timeIntervalSince1970: 1), model: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 3, rawSource: "raw")
        try expect(key == "Hermes::request::req_123", "request id dedupe mismatch")
    }

    static func dedupeFallbackIsStableForSamePayload() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Dedupe.makeKey(source: .codeX, requestId: nil, timestamp: date, model: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 3, rawSource: "raw")
        let second = Dedupe.makeKey(source: .codeX, requestId: nil, timestamp: date, model: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 3, rawSource: "raw")
        try expect(first == second, "fallback dedupe is not stable")
        try expect(first.hasPrefix("CodeX::fallback::"), "fallback dedupe prefix mismatch")
    }

    static func maskingDoesNotExposeFullAPIKey() throws {
        let masked = Masking.maskAPIKey("sk-test-secret-abcd")
        try expect(masked == "sk--...abcd", "mask format mismatch")
        try expect(!masked.contains("secret"), "mask leaked secret segment")
    }

    static func aggregationFiltersToday() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = calendar.date(byAdding: .day, value: -2, to: now)!
        let records = [
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 10, outputTokens: 20, cacheTokens: 5, estimatedCost: 1, rawSource: "1"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: old, inputTokens: 100, outputTokens: 200, cacheTokens: 50, estimatedCost: 10, rawSource: "2")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .today, now: now, calendar: calendar)
        try expect(usage.totalTokens == 35, "today aggregation total mismatch")
        try expect(NSDecimalNumber(decimal: usage.estimatedCost).doubleValue == 1, "today aggregation cost mismatch")
    }

    static func aggregationFiltersCustomDateRange() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let inRange = calendar.date(byAdding: .day, value: 2, to: start)!
        let end = calendar.date(byAdding: .day, value: 3, to: start)!
        let outOfRange = calendar.date(byAdding: .day, value: 5, to: start)!
        let records = [
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: inRange, inputTokens: 10, outputTokens: 20, cacheTokens: 5, estimatedCost: 1, rawSource: "custom-1"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: outOfRange, inputTokens: 100, outputTokens: 200, cacheTokens: 50, estimatedCost: 10, rawSource: "custom-2")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .all, customRange: CustomDateRange(start: start, end: end), calendar: calendar)
        try expect(usage.totalTokens == 35, "custom range aggregation total mismatch")
        try expect(NSDecimalNumber(decimal: usage.estimatedCost).doubleValue == 1, "custom range aggregation cost mismatch")
    }

    static func budgetAlertLevels() throws {
        try expect(BudgetEngine.alertLevel(progress: 0.5) == .normal, "normal budget mismatch")
        try expect(BudgetEngine.alertLevel(progress: 0.8) == .warning, "warning budget mismatch")
        try expect(BudgetEngine.alertLevel(progress: 1.0) == .exceeded, "exceeded budget mismatch")
    }

    static func exportRedactsIdentifiersByDefault() throws {
        let record = UsageRecord(source: .claudeCode, accountId: "account", apiKeyHash: "sk-...abcd", model: "claude", timestamp: Date(timeIntervalSince1970: 0), inputTokens: 1, outputTokens: 2, cacheTokens: 3, estimatedCost: 0.1, rawSource: "raw")
        let csv = try ExportService.export(records: [record], format: .csv, includeIdentifiers: false)
        try expect(csv.contains("redacted"), "export did not redact identifiers")
        try expect(!csv.contains(",account,"), "export leaked account")
    }

    static func repositoryDeduplicatesRecords() async throws {
        let repository = UsageRepository()
        let first = UsageRecord(source: .openClaw, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 1, outputTokens: 1, cacheTokens: 0, requestId: "same", rawSource: "raw")
        let second = UsageRecord(source: .openClaw, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 2, outputTokens: 2, cacheTokens: 0, requestId: "same", rawSource: "raw")
        await repository.upsert([first, second])
        let all = await repository.all()
        try expect(all.count == 1, "repository did not dedupe")
        try expect(all[0].totalTokens == 4, "repository did not keep latest record")
    }
    static func claudeParserReadsUsageLine() throws {
        let line = """
        {"type":"assistant","uuid":"u1","timestamp":"2026-05-11T19:59:41.206Z","message":{"id":"m1","model":"claude-sonnet-4.5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}
        """
        let record = LocalUsageParser.parseClaudeLine(line, filePath: "/tmp/claude.jsonl", pricing: [])
        try expect(record?.source == .claudeCode, "claude source mismatch")
        try expect(record?.inputTokens == 10, "claude input mismatch")
        try expect(record?.outputTokens == 20, "claude output mismatch")
        try expect(record?.cacheTokens == 7, "claude cache mismatch")
    }

    static func codexParserReadsTokenCountLine() throws {
        let line = """
        {"timestamp":"2026-04-18T15:41:12.238Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3,"reasoning_output_tokens":2,"total_tokens":20}}}}
        """
        let record = LocalUsageParser.parseCodexLine(line, filePath: "/tmp/codex.jsonl", pricing: [])
        try expect(record?.source == .codeX, "codex source mismatch")
        try expect(record?.inputTokens == 17, "codex input mismatch")
        try expect(record?.outputTokens == 5, "codex output mismatch")
        try expect(record?.cacheTokens == 7, "codex cache mismatch")
    }

    static func openClawParserReadsUsageLine() throws {
        let line = """
        {"type":"message","id":"o1","timestamp":"2026-04-28T12:19:08.945Z","message":{"role":"assistant","provider":"micu","model":"gpt-5.4","usage":{"input":11,"output":22,"cacheRead":3,"cacheWrite":4,"totalTokens":40,"cost":{"total":0.123}}}}
        """
        let record = LocalUsageParser.parseOpenClawLine(line, filePath: "/tmp/openclaw.jsonl", pricing: [])
        try expect(record?.source == .openClaw, "openclaw source mismatch")
        try expect(record?.inputTokens == 11, "openclaw input mismatch")
        try expect(record?.outputTokens == 22, "openclaw output mismatch")
        try expect(record?.cacheTokens == 7, "openclaw cache mismatch")
        try expect(abs(NSDecimalNumber(decimal: record?.estimatedCost ?? 0).doubleValue - 0.123) < 0.0001, "openclaw cost mismatch")
    }

    static func hermesParserIncludesReasoningTokens() throws {
        let record = LocalUsageParser.parseHermesSessionRow(id: "h1", source: "webui", userId: "u1", model: "gpt-5.5", activityAt: 1_777_777_777, input: 10, output: 20, cacheRead: 3, cacheWrite: 4, reasoning: 5, cost: nil, provider: "provider", pricing: [])
        try expect(record?.source == .hermes, "hermes source mismatch")
        try expect(record?.inputTokens == 10, "hermes input mismatch")
        try expect(record?.outputTokens == 25, "hermes reasoning tokens not included in output")
        try expect(record?.cacheTokens == 7, "hermes cache mismatch")
        try expect(record?.totalTokens == 42, "hermes total mismatch")
    }

    static func hermesSQLiteAdapterUsesLatestMessageTimestamp() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-hermes-adapter-test-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let db = try SQLiteTestDB(path: url.path)
        try db.exec("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            user_id TEXT,
            model TEXT,
            started_at REAL NOT NULL,
            ended_at REAL,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            estimated_cost_usd REAL,
            billing_provider TEXT
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            role TEXT NOT NULL,
            timestamp REAL NOT NULL,
            token_count INTEGER
        );
        INSERT INTO sessions (id, source, user_id, model, started_at, ended_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, estimated_cost_usd, billing_provider)
        VALUES ('s1', 'webui', 'u1', 'gpt-5.5', 1779374334, NULL, 100, 20, 3, 4, 5, NULL, 'provider');
        INSERT INTO messages (session_id, role, timestamp, token_count)
        VALUES ('s1', 'assistant', 1779493000, NULL);
        """)
        let adapter = HermesSQLiteUsageAdapter()
        let source = UsageSource(tool: .hermes, name: "Hermes Test", accountId: "u1", apiKeyIdentity: "provider", localLogPath: url.path)
        let records = try await adapter.refresh(source: source, pricing: [], cursorStore: nil, fullScan: true)
        try expect(records.count == 1, "hermes sqlite adapter did not read session")
        try expect(records[0].timestamp.timeIntervalSince1970 == 1779493000, "hermes sqlite adapter did not use latest message timestamp")
        try expect(records[0].outputTokens == 25, "hermes sqlite adapter did not include reasoning tokens")
        try expect(records[0].totalTokens == 132, "hermes sqlite adapter total mismatch")
    }

    static func openCodeParserReadsMessageRow() throws {
        let data = """
        {"id":"msg_1","providerID":"anthropic","modelID":"claude-sonnet-4","role":"assistant","usage":{"inputTokens":31,"outputTokens":41,"cacheReadTokens":5,"cacheWriteTokens":7,"cost":0.234}}
        """
        let record = LocalUsageParser.parseOpenCodeMessageRow(id: "row_1", sessionId: "ses_1", timeCreated: 1_777_777_777_000, data: data, rawSource: "/tmp/opencode.db:message", pricing: [])
        try expect(record?.source == .openCode, "opencode source mismatch")
        try expect(record?.accountId == "ses_1", "opencode session mismatch")
        try expect(record?.apiKeyHash == "anthropic", "opencode provider mismatch")
        try expect(record?.model == "claude-sonnet-4", "opencode model mismatch")
        try expect(record?.inputTokens == 31, "opencode input mismatch")
        try expect(record?.outputTokens == 41, "opencode output mismatch")
        try expect(record?.cacheTokens == 12, "opencode cache mismatch")
        try expect(abs(NSDecimalNumber(decimal: record?.estimatedCost ?? 0).doubleValue - 0.234) < 0.0001, "opencode cost mismatch")
    }

    static func openCodeParserReadsNestedTokensCacheShape() throws {
        let data = """
        {"role":"assistant","modelID":"gpt-5.5","providerID":"xomodel-opencode-gpt","tokens":{"total":9807,"input":299,"output":292,"reasoning":11,"cache":{"write":13,"read":9216}},"time":{"created":1778759081253,"completed":1778759095240},"finish":"stop"}
        """
        let record = LocalUsageParser.parseOpenCodeMessageRow(id: "row_nested", sessionId: "ses_nested", timeCreated: 1_778_759_081_253, data: data, rawSource: "/tmp/opencode.db:message", pricing: [])
        try expect(record?.source == .openCode, "opencode nested source mismatch")
        try expect(record?.apiKeyHash == "xomodel-opencode-gpt", "opencode nested provider mismatch")
        try expect(record?.model == "gpt-5.5", "opencode nested model mismatch")
        try expect(record?.inputTokens == 299, "opencode nested input mismatch")
        try expect(record?.outputTokens == 303, "opencode nested output+reasoning mismatch")
        try expect(record?.cacheTokens == 9229, "opencode nested cache mismatch")
        try expect(record?.totalTokens == 9831, "opencode nested total mismatch")
    }

    static func persistentRepositoryKeepsHistoricalRecords() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-test-\(UUID().uuidString).sqlite")
        let repository = PersistentUsageRepository(dbURL: url)
        let record = UsageRecord(source: .hermes, accountId: "deleted-account", apiKeyHash: "deleted-key", model: "m", timestamp: Date(), inputTokens: 1, outputTokens: 2, cacheTokens: 3, requestId: "persist", rawSource: "test")
        repository.upsert([record])
        let reloaded = PersistentUsageRepository(dbURL: url)
        let all = reloaded.all()
        try expect(all.count == 1, "persistent repository did not reload")
        try expect(all[0].accountId == "deleted-account", "historical account not retained")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    static func pricingPersistsInSQLite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-pricing-test-\(UUID().uuidString).sqlite")
        let repository = PersistentUsageRepository(dbURL: url)
        let item = ModelPricing(tool: .codeX, model: "custom-codex-model", inputPerMillion: 1.25, outputPerMillion: 6.5, cachePerMillion: 0.25)
        repository.upsertPricing(item)
        let reloaded = PersistentUsageRepository(dbURL: url)
        let pricing = reloaded.loadPricing()
        try expect(pricing.count == 1, "pricing was not persisted")
        try expect(pricing[0].tool == .codeX, "pricing tool mismatch")
        try expect(pricing[0].model == "custom-codex-model", "pricing model mismatch")
        try expect(abs(NSDecimalNumber(decimal: pricing[0].outputPerMillion).doubleValue - 6.5) < 0.0001, "pricing value mismatch")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    static func budgetsPersistInSQLite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-budget-test-\(UUID().uuidString).sqlite")
        let repository = PersistentUsageRepository(dbURL: url)
        let budgets = [
            BudgetRule(period: .daily, tokenLimit: 123, costLimit: 4.5),
            BudgetRule(period: .weekly, tokenLimit: 456, costLimit: 78.9),
            BudgetRule(period: .monthly, tokenLimit: 789, costLimit: 123.45)
        ]
        repository.saveBudgets(budgets)
        let reloaded = PersistentUsageRepository(dbURL: url)
        let loaded = UsageStore.orderedBudgets(reloaded.loadBudgets())
        try expect(loaded.count == 3, "budgets were not persisted")
        try expect(loaded[0].period == .daily && loaded[0].tokenLimit == 123, "daily budget mismatch")
        try expect(abs(NSDecimalNumber(decimal: loaded[1].costLimit).doubleValue - 78.9) < 0.0001, "weekly budget cost mismatch")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    static func budgetProgressCanUseTokenOrCostMode() throws {
        let usage = AggregatedUsage(inputTokens: 30, outputTokens: 20, cacheTokens: 0, totalTokens: 50, estimatedCost: 80)
        let rule = BudgetRule(period: .daily, tokenLimit: 100, costLimit: 200)
        try expect(abs(BudgetEngine.progress(usage: usage, rule: rule, mode: .tokens) - 0.5) < 0.0001, "token budget progress mismatch")
        try expect(abs(BudgetEngine.progress(usage: usage, rule: rule, mode: .cost) - 0.4) < 0.0001, "cost budget progress mismatch")
    }

}

final class SQLiteTestDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = db.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "unknown sqlite open error"
            throw TestFailure(message)
        }
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite exec error"
            if let error { sqlite3_free(error) }
            throw TestFailure(message)
        }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
