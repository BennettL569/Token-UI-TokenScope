import Foundation
import SQLite3

public final class PersistentUsageRepository: UsageCursorStore, @unchecked Sendable {
    private let dbURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(dbURL: URL = PersistentUsageRepository.defaultURL()) {
        self.dbURL = dbURL
        open()
        migrateLegacyJSONIfNeeded()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenScope", isDirectory: true)
            .appendingPathComponent("usage.sqlite")
    }

    public func upsert(_ records: [UsageRecord]) {
        guard !records.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        // Prepare the statement once and reuse it for the whole batch inside a single
        // transaction. The previous implementation re-compiled the SQL and ran an implicit
        // transaction for every row, which made full rescans (tens of thousands of rows)
        // pathologically slow and hammered the WAL. All of this runs off the main thread.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for record in records {
            bindUsageRecord(statement, record)
            sqlite3_step(statement)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    public func all() -> [UsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        SELECT id, source, account_id, api_key_hash, model, timestamp, input_tokens, output_tokens,
               cache_tokens, estimated_cost, request_id, dedupe_key, raw_source, cache_creation_tokens
        FROM usage_records
        ORDER BY timestamp DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [UsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sourceRaw = columnText(statement, 1), let source = ToolKind(rawValue: sourceRaw) else { continue }
            let idString = columnText(statement, 0) ?? UUID().uuidString
            let id = UUID(uuidString: idString) ?? UUID()
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let cost = Decimal(sqlite3_column_double(statement, 9))
            let record = UsageRecord(
                id: id,
                source: source,
                accountId: columnText(statement, 2) ?? "unknown",
                apiKeyHash: columnText(statement, 3) ?? "unknown",
                model: columnText(statement, 4) ?? "unknown",
                timestamp: timestamp,
                inputTokens: Int(sqlite3_column_int64(statement, 6)),
                outputTokens: Int(sqlite3_column_int64(statement, 7)),
                cacheTokens: Int(sqlite3_column_int64(statement, 8)),
                cacheCreationTokens: Int(sqlite3_column_int64(statement, 13)),
                estimatedCost: cost,
                requestId: columnText(statement, 10),
                dedupeKey: columnText(statement, 11),
                rawSource: columnText(statement, 12) ?? ""
            )
            rows.append(record)
        }
        return rows
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_exec(db, "DELETE FROM usage_records", nil, nil, nil)
    }

    public func clearRefreshCursors() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_exec(db, "DELETE FROM refresh_cursors", nil, nil, nil)
    }

    public func refreshCursor(source: ToolKind, rawSource: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT position FROM refresh_cursors WHERE source = ? AND raw_source = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source.rawValue)
        bind(statement, 2, rawSource)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    public func setRefreshCursor(source: ToolKind, rawSource: String, position: Double) {
        setRefreshCursor(source: source, rawSource: rawSource, position: position, model: nil)
    }

    public func refreshCursorModel(source: ToolKind, rawSource: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT model FROM refresh_cursors WHERE source = ? AND raw_source = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source.rawValue)
        bind(statement, 2, rawSource)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    public func setRefreshCursor(source: ToolKind, rawSource: String, position: Double, model: String?) {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        INSERT INTO refresh_cursors (source, raw_source, position, model, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(source, raw_source) DO UPDATE SET
            position=excluded.position,
            model=excluded.model,
            updated_at=excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source.rawValue)
        bind(statement, 2, rawSource)
        sqlite3_bind_double(statement, 3, position)
        if let model { bind(statement, 4, model) } else { sqlite3_bind_null(statement, 4) }
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        sqlite3_step(statement)
    }

    public func loadPricing() -> [ModelPricing] {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT tool, model, input_per_million, output_per_million, cache_per_million FROM model_pricing ORDER BY tool, model"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [ModelPricing] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let toolRaw = columnText(statement, 0), let tool = ToolKind(rawValue: toolRaw), let model = columnText(statement, 1) else { continue }
            rows.append(ModelPricing(
                tool: tool,
                model: model,
                inputPerMillion: Decimal(sqlite3_column_double(statement, 2)),
                outputPerMillion: Decimal(sqlite3_column_double(statement, 3)),
                cachePerMillion: Decimal(sqlite3_column_double(statement, 4))
            ))
        }
        return rows
    }

    public func savePricing(_ pricing: [ModelPricing]) {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM model_pricing", nil, nil, nil)
        for item in pricing { upsertPricingLocked(item) }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    public func upsertPricing(_ item: ModelPricing) {
        lock.lock()
        defer { lock.unlock() }
        upsertPricingLocked(item)
    }

    public func deletePricing(_ item: ModelPricing) {
        lock.lock()
        defer { lock.unlock() }
        let sql = "DELETE FROM model_pricing WHERE tool = ? AND model = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, item.tool.rawValue)
        bind(statement, 2, item.model)
        sqlite3_step(statement)
    }

    public func loadBudgets() -> [BudgetRule] {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT period, token_limit, cost_limit FROM budget_rules ORDER BY period"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [BudgetRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let periodRaw = columnText(statement, 0), let period = BudgetPeriod(rawValue: periodRaw) else { continue }
            rows.append(BudgetRule(period: period, tokenLimit: Int(sqlite3_column_int64(statement, 1)), costLimit: Decimal(sqlite3_column_double(statement, 2))))
        }
        return rows
    }

    public func saveBudgets(_ budgets: [BudgetRule]) {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM budget_rules", nil, nil, nil)
        for item in budgets { upsertBudgetLocked(item) }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    public func upsertBudget(_ item: BudgetRule) {
        lock.lock()
        defer { lock.unlock() }
        upsertBudgetLocked(item)
    }

    private func open() {
        do {
            try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return
        }
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS usage_records (
            dedupe_key TEXT PRIMARY KEY,
            id TEXT NOT NULL,
            source TEXT NOT NULL,
            account_id TEXT NOT NULL,
            api_key_hash TEXT NOT NULL,
            model TEXT NOT NULL,
            timestamp REAL NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_tokens INTEGER NOT NULL,
            cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL,
            estimated_cost REAL NOT NULL,
            request_id TEXT,
            raw_source TEXT NOT NULL
        )
        """, nil, nil, nil)
        // Migration for databases created before cache_creation_tokens existed. The ALTER fails
        // harmlessly (and is ignored) once the column is present.
        sqlite3_exec(db, "ALTER TABLE usage_records ADD COLUMN cache_creation_tokens INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_usage_source_time ON usage_records(source, timestamp)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_usage_account ON usage_records(account_id)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_usage_model ON usage_records(model)", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS model_pricing (
            tool TEXT NOT NULL,
            model TEXT NOT NULL,
            input_per_million REAL NOT NULL,
            output_per_million REAL NOT NULL,
            cache_per_million REAL NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (tool, model)
        )
        """, nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS budget_rules (
            period TEXT PRIMARY KEY,
            token_limit INTEGER NOT NULL,
            cost_limit REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """, nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS refresh_cursors (
            source TEXT NOT NULL,
            raw_source TEXT NOT NULL,
            position REAL NOT NULL,
            model TEXT,
            updated_at REAL NOT NULL,
            PRIMARY KEY (source, raw_source)
        )
        """, nil, nil, nil)
        // Migrate older databases whose refresh_cursors predate the `model` column. The ADD COLUMN
        // errors harmlessly ("duplicate column") on databases that already have it; we ignore it.
        sqlite3_exec(db, "ALTER TABLE refresh_cursors ADD COLUMN model TEXT", nil, nil, nil)
    }

    private static let upsertSQL = """
        INSERT INTO usage_records (
            dedupe_key, id, source, account_id, api_key_hash, model, timestamp,
            input_tokens, output_tokens, cache_tokens, total_tokens, estimated_cost,
            request_id, raw_source, cache_creation_tokens
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(dedupe_key) DO UPDATE SET
            id=excluded.id,
            source=excluded.source,
            account_id=excluded.account_id,
            api_key_hash=excluded.api_key_hash,
            model=excluded.model,
            timestamp=excluded.timestamp,
            input_tokens=excluded.input_tokens,
            output_tokens=excluded.output_tokens,
            cache_tokens=excluded.cache_tokens,
            total_tokens=excluded.total_tokens,
            estimated_cost=excluded.estimated_cost,
            request_id=excluded.request_id,
            raw_source=excluded.raw_source,
            cache_creation_tokens=excluded.cache_creation_tokens
        """

    /// Binds a record onto an already-prepared `upsertSQL` statement. The caller owns stepping,
    /// resetting and finalizing the statement so it can be reused across a batch.
    private func bindUsageRecord(_ statement: OpaquePointer?, _ record: UsageRecord) {
        bind(statement, 1, record.dedupeKey)
        bind(statement, 2, record.id.uuidString)
        bind(statement, 3, record.source.rawValue)
        bind(statement, 4, record.accountId)
        bind(statement, 5, record.apiKeyHash)
        bind(statement, 6, record.model)
        sqlite3_bind_double(statement, 7, record.timestamp.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 8, Int64(record.inputTokens))
        sqlite3_bind_int64(statement, 9, Int64(record.outputTokens))
        sqlite3_bind_int64(statement, 10, Int64(record.cacheTokens))
        sqlite3_bind_int64(statement, 11, Int64(record.totalTokens))
        sqlite3_bind_double(statement, 12, NSDecimalNumber(decimal: record.estimatedCost).doubleValue)
        if let requestId = record.requestId { bind(statement, 13, requestId) } else { sqlite3_bind_null(statement, 13) }
        bind(statement, 14, record.rawSource)
        sqlite3_bind_int64(statement, 15, Int64(record.cacheCreationTokens))
    }

    private func upsertPricingLocked(_ item: ModelPricing) {
        let sql = """
        INSERT INTO model_pricing (tool, model, input_per_million, output_per_million, cache_per_million, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(tool, model) DO UPDATE SET
            input_per_million=excluded.input_per_million,
            output_per_million=excluded.output_per_million,
            cache_per_million=excluded.cache_per_million,
            updated_at=excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, item.tool.rawValue)
        bind(statement, 2, item.model)
        sqlite3_bind_double(statement, 3, NSDecimalNumber(decimal: item.inputPerMillion).doubleValue)
        sqlite3_bind_double(statement, 4, NSDecimalNumber(decimal: item.outputPerMillion).doubleValue)
        sqlite3_bind_double(statement, 5, NSDecimalNumber(decimal: item.cachePerMillion).doubleValue)
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        sqlite3_step(statement)
    }

    private func upsertBudgetLocked(_ item: BudgetRule) {
        let sql = """
        INSERT INTO budget_rules (period, token_limit, cost_limit, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(period) DO UPDATE SET
            token_limit=excluded.token_limit,
            cost_limit=excluded.cost_limit,
            updated_at=excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, item.period.rawValue)
        sqlite3_bind_int64(statement, 2, Int64(item.tokenLimit))
        sqlite3_bind_double(statement, 3, NSDecimalNumber(decimal: item.costLimit).doubleValue)
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        sqlite3_step(statement)
    }

    private func migrateLegacyJSONIfNeeded() {
        let legacyURL = dbURL.deletingLastPathComponent().appendingPathComponent("usage-records.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path), all().isEmpty else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: legacyURL), let records = try? decoder.decode([UsageRecord].self, from: data) else { return }
        upsert(records)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
