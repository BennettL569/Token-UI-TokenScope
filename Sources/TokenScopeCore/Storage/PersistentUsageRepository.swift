import Foundation
import SQLite3

public final class PersistentUsageRepository: UsageCursorStore, @unchecked Sendable {
    private let dbURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(dbURL: URL = PersistentUsageRepository.defaultURL()) {
        self.dbURL = dbURL
        open()
        migrateCodexDedupeKeys()
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

    public var databaseURL: URL { dbURL }

    /// Where `SafetyBackups` keeps automatic snapshots of this database: a `Backups` folder next to it.
    public var safetyBackupDirectory: URL {
        dbURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    /// Writes a consistent, compacted copy of the whole database to `url` (`VACUUM INTO`); safe
    /// while the app keeps using the database. Fails if `url` already exists.
    public func writeSnapshot(to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw RepositoryError.databaseUnavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "VACUUM INTO ?", -1, &statement, nil) == SQLITE_OK else {
            throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, url.path)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RepositoryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
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

    public func deleteRecords(dedupeKeys: [String]) {
        guard !dedupeKeys.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM usage_records WHERE dedupe_key = ?", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for key in dedupeKeys {
            bind(statement, 1, key)
            sqlite3_step(statement)
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    public func clearRefreshCursors() {
        lock.lock()
        defer { lock.unlock() }
        sqlite3_exec(db, "DELETE FROM refresh_cursors", nil, nil, nil)
    }

    public func allRefreshCursors() -> [RefreshCursorKey: Double] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT source, raw_source, position FROM refresh_cursors", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var cursors: [RefreshCursorKey: Double] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sourceRaw = columnText(statement, 0), let tool = ToolKind(rawValue: sourceRaw),
                  let rawSource = columnText(statement, 1) else { continue }
            cursors[RefreshCursorKey(tool: tool, rawSource: rawSource)] = sqlite3_column_double(statement, 2)
        }
        return cursors
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

    // MARK: - Backup

    /// Every stored row exactly as stored (including rows of tools this version doesn't know),
    /// plus pricing and budgets. Throws rather than return a partial backup.
    public func exportBackup(exportedAt: Date = Date(), appVersion: String? = nil) throws -> UsageBackup {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { throw RepositoryError.databaseUnavailable }
        let records = try queryLocked("""
            SELECT dedupe_key, id, source, account_id, api_key_hash, model, timestamp, input_tokens, output_tokens,
                   cache_tokens, cache_creation_tokens, estimated_cost, request_id, raw_source
            FROM usage_records ORDER BY timestamp, dedupe_key
            """) { statement in
            UsageBackup.Record(
                dedupeKey: columnText(statement, 0) ?? "",
                id: columnText(statement, 1) ?? "",
                source: columnText(statement, 2) ?? "",
                accountId: columnText(statement, 3) ?? "",
                apiKeyHash: columnText(statement, 4) ?? "",
                model: columnText(statement, 5) ?? "",
                timestamp: sqlite3_column_double(statement, 6),
                inputTokens: Int(sqlite3_column_int64(statement, 7)),
                outputTokens: Int(sqlite3_column_int64(statement, 8)),
                cacheTokens: Int(sqlite3_column_int64(statement, 9)),
                cacheCreationTokens: Int(sqlite3_column_int64(statement, 10)),
                estimatedCost: sqlite3_column_double(statement, 11),
                requestId: columnText(statement, 12),
                rawSource: columnText(statement, 13) ?? ""
            )
        }
        let pricing = try queryLocked("SELECT tool, model, input_per_million, output_per_million, cache_per_million FROM model_pricing ORDER BY tool, model") { statement in
            UsageBackup.Pricing(
                tool: columnText(statement, 0) ?? "",
                model: columnText(statement, 1) ?? "",
                inputPerMillion: sqlite3_column_double(statement, 2),
                outputPerMillion: sqlite3_column_double(statement, 3),
                cachePerMillion: sqlite3_column_double(statement, 4)
            )
        }
        let budgets = try queryLocked("SELECT period, token_limit, cost_limit FROM budget_rules ORDER BY period") { statement in
            UsageBackup.Budget(period: columnText(statement, 0) ?? "", tokenLimit: Int(sqlite3_column_int64(statement, 1)), costLimit: sqlite3_column_double(statement, 2))
        }
        return UsageBackup(exportedAt: exportedAt, appVersion: appVersion, records: records, pricing: pricing, budgets: budgets)
    }

    public func allDedupeKeys() throws -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { throw RepositoryError.databaseUnavailable }
        return Set(try queryLocked("SELECT dedupe_key FROM usage_records") { columnText($0, 0) ?? "" })
    }

    /// Inserts the backup rows whose dedupe key isn't stored yet and leaves every existing row
    /// exactly as it is: a local row comes from this machine's current parser, so an imported copy
    /// never replaces it. All-or-nothing. Returns how many rows were inserted.
    public func importBackupRecords(_ records: [UsageBackup.Record]) throws -> Int {
        guard !records.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { throw RepositoryError.databaseUnavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT OR IGNORE INTO usage_records (
                dedupe_key, id, source, account_id, api_key_hash, model, timestamp,
                input_tokens, output_tokens, cache_tokens, total_tokens, estimated_cost,
                request_id, raw_source, cache_creation_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, -1, &statement, nil) == SQLITE_OK else { throw RepositoryError.sqlite(lastErrorMessage) }
        defer { sqlite3_finalize(statement) }
        return try inTransactionLocked {
            var inserted = 0
            for record in records {
                bind(statement, 1, record.dedupeKey)
                bind(statement, 2, record.id)
                bind(statement, 3, record.source)
                bind(statement, 4, record.accountId)
                bind(statement, 5, record.apiKeyHash)
                bind(statement, 6, record.model)
                sqlite3_bind_double(statement, 7, record.timestamp)
                sqlite3_bind_int64(statement, 8, Int64(record.inputTokens))
                sqlite3_bind_int64(statement, 9, Int64(record.outputTokens))
                sqlite3_bind_int64(statement, 10, Int64(record.cacheTokens))
                sqlite3_bind_int64(statement, 11, Int64(record.inputTokens + record.outputTokens + record.cacheTokens))
                sqlite3_bind_double(statement, 12, record.estimatedCost)
                if let requestId = record.requestId { bind(statement, 13, requestId) } else { sqlite3_bind_null(statement, 13) }
                bind(statement, 14, record.rawSource)
                sqlite3_bind_int64(statement, 15, Int64(record.cacheCreationTokens))
                guard sqlite3_step(statement) == SQLITE_DONE else { throw RepositoryError.sqlite(lastErrorMessage) }
                inserted += Int(sqlite3_changes(db))
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            return inserted
        }
    }

    /// Writes a backup's pricing rows (replacing the same tool + model) and budget rules (replacing
    /// the same period). Rows that only exist locally are kept. All-or-nothing.
    public func restoreSettings(pricing: [UsageBackup.Pricing], budgets: [UsageBackup.Budget]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard db != nil else { throw RepositoryError.databaseUnavailable }
        let now = Date().timeIntervalSince1970
        try inTransactionLocked {
            for item in pricing {
                try executeLocked("""
                    INSERT INTO model_pricing (tool, model, input_per_million, output_per_million, cache_per_million, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(tool, model) DO UPDATE SET
                        input_per_million=excluded.input_per_million,
                        output_per_million=excluded.output_per_million,
                        cache_per_million=excluded.cache_per_million,
                        updated_at=excluded.updated_at
                    """) { statement in
                    bind(statement, 1, item.tool)
                    bind(statement, 2, item.model)
                    sqlite3_bind_double(statement, 3, item.inputPerMillion)
                    sqlite3_bind_double(statement, 4, item.outputPerMillion)
                    sqlite3_bind_double(statement, 5, item.cachePerMillion)
                    sqlite3_bind_double(statement, 6, now)
                }
            }
            for item in budgets {
                try executeLocked("""
                    INSERT INTO budget_rules (period, token_limit, cost_limit, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(period) DO UPDATE SET
                        token_limit=excluded.token_limit,
                        cost_limit=excluded.cost_limit,
                        updated_at=excluded.updated_at
                    """) { statement in
                    bind(statement, 1, item.period)
                    sqlite3_bind_int64(statement, 2, Int64(item.tokenLimit))
                    sqlite3_bind_double(statement, 3, item.costLimit)
                    sqlite3_bind_double(statement, 4, now)
                }
            }
        }
    }

    private var lastErrorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
    }

    /// Runs a query and maps every row, throwing instead of returning a partial result if any step
    /// fails. Caller holds `lock`.
    private func queryLocked<T>(_ sql: String, _ row: (OpaquePointer?) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw RepositoryError.sqlite(lastErrorMessage) }
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(row(statement))
            case SQLITE_DONE: return rows
            default: throw RepositoryError.sqlite(lastErrorMessage)
            }
        }
    }

    /// Prepares, binds and runs one statement, throwing on failure. Caller holds `lock`.
    private func executeLocked(_ sql: String, bindings: (OpaquePointer?) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw RepositoryError.sqlite(lastErrorMessage) }
        defer { sqlite3_finalize(statement) }
        bindings(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw RepositoryError.sqlite(lastErrorMessage) }
    }

    /// Runs `body` in a transaction that commits only if it succeeds. Caller holds `lock`.
    private func inTransactionLocked<T>(_ body: () throws -> T) throws -> T {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw RepositoryError.sqlite(lastErrorMessage) }
        do {
            let result = try body()
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw RepositoryError.sqlite(lastErrorMessage) }
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
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

    /// Re-keys Codex rows still keyed by full file path (see `CodexDedupeKey`), collapsing the
    /// duplicates archived sessions left behind. Runs on every open, but once nothing is left it is
    /// a single cheap query. Rewriting stored records needs a `SafetyBackups` snapshot first; if one
    /// can't be written, the migration waits for the next open.
    private func migrateCodexDedupeKeys() {
        guard db != nil else { return }
        let oldRows: [CodexDedupeKey.StoredRow]
        let existingKeys: Set<String>
        lock.lock()
        do {
            oldRows = try queryLocked("""
                SELECT dedupe_key, request_id, raw_source FROM usage_records
                WHERE source = 'CodeX' AND request_id IS NOT NULL
                  AND substr(request_id, 1, length(raw_source) + 1) = raw_source || '#'
                """) { CodexDedupeKey.StoredRow(dedupeKey: columnText($0, 0) ?? "", requestId: columnText($0, 1) ?? "", rawSource: columnText($0, 2) ?? "") }
            existingKeys = oldRows.isEmpty ? [] : Set(try queryLocked("SELECT dedupe_key FROM usage_records WHERE source = 'CodeX'") { columnText($0, 0) ?? "" })
        } catch {
            lock.unlock()
            return
        }
        lock.unlock()
        let plan = CodexDedupeKey.migrationPlan(oldRows: oldRows, existingKeys: existingKeys) { FileManager.default.fileExists(atPath: $0) }
        guard !plan.isEmpty, (try? SafetyBackups.create(of: self, reason: "before-codex-key-migration")) != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        var delete: OpaquePointer?
        var update: OpaquePointer?
        defer {
            sqlite3_finalize(delete)
            sqlite3_finalize(update)
        }
        guard sqlite3_prepare_v2(db, "DELETE FROM usage_records WHERE dedupe_key = ?", -1, &delete, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "UPDATE usage_records SET dedupe_key = ?, request_id = ? WHERE dedupe_key = ?", -1, &update, nil) == SQLITE_OK else { return }
        // All-or-nothing: on any failure the transaction rolls back and the next open retries.
        try? inTransactionLocked {
            for key in plan.delete {
                bind(delete, 1, key)
                guard sqlite3_step(delete) == SQLITE_DONE else { throw RepositoryError.sqlite(lastErrorMessage) }
                sqlite3_reset(delete)
            }
            for item in plan.rekey {
                bind(update, 1, item.newKey)
                bind(update, 2, item.newRequestId)
                bind(update, 3, item.oldKey)
                guard sqlite3_step(update) == SQLITE_DONE else { throw RepositoryError.sqlite(lastErrorMessage) }
                sqlite3_reset(update)
            }
        }
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

public enum RepositoryError: Error, LocalizedError {
    case databaseUnavailable
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "The usage database could not be opened."
        case .sqlite(let message): return "SQLite error: \(message)"
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
