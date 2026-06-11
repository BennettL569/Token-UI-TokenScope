import Foundation
import SQLite3

public struct HermesSQLiteUsageAdapter: UsageAdapter {
    public let id = "hermes-sqlite"
    public let tool: ToolKind = .hermes
    public let displayName = "Hermes SQLite"
    public let capabilities: AdapterCapabilities = [.supportsLocalLogs, .supportsCostEstimation]
    private let defaultPaths = ["~/.hermes/state.db"]
    private let incrementalLookbackSeconds: Double = 24 * 60 * 60

    public init() {}

    public func refresh(source: UsageSource, pricing: [ModelPricing], cursorStore: UsageCursorStore? = nil, fullScan: Bool = false) async throws -> [UsageRecord] {
        guard source.isEnabled else { throw AdapterError.sourceDisabled }
        let paths = FileDiscovery.expand(paths: source.localLogPath.isEmpty ? defaultPaths : [source.localLogPath])
        var all: [UsageRecord] = []
        for path in paths {
            let since = fullScan ? nil : cursorStore?.refreshCursor(source: tool, rawSource: path)
            let effectiveSince = since.map { max(0, $0 - incrementalLookbackSeconds) }
            let records = readSessions(path: path, pricing: pricing, since: effectiveSince)
            all.append(contentsOf: records)
            if let maxTimestamp = records.map(\.timestamp.timeIntervalSince1970).max() {
                cursorStore?.setRefreshCursor(source: tool, rawSource: path, position: maxTimestamp)
            } else if fullScan {
                cursorStore?.setRefreshCursor(source: tool, rawSource: path, position: Date().timeIntervalSince1970)
            }
        }
        return all
    }

    private func readSessions(path: String, pricing: [ModelPricing], since: Double?) -> [UsageRecord] {
        guard let db = ReadOnlySQLite.open(path) else { return [] }
        defer { sqlite3_close(db) }
        var sql = """
        SELECT s.id, s.source, s.user_id, s.model,
               COALESCE(MAX(m.timestamp), s.ended_at, s.started_at) AS activity_at,
               s.input_tokens, s.output_tokens,
               s.cache_read_tokens, s.cache_write_tokens, s.reasoning_tokens,
               s.estimated_cost_usd, s.billing_provider
        FROM sessions s
        LEFT JOIN messages m ON m.session_id = s.id
        WHERE COALESCE(s.input_tokens, 0) + COALESCE(s.output_tokens, 0) + COALESCE(s.cache_read_tokens, 0) + COALESCE(s.cache_write_tokens, 0) + COALESCE(s.reasoning_tokens, 0) > 0
        GROUP BY s.id
        """
        if since != nil { sql += "\nHAVING activity_at > ?" }
        sql += "\nORDER BY activity_at ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        if let since { sqlite3_bind_double(statement, 1, since) }
        defer { sqlite3_finalize(statement) }
        var records: [UsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = columnText(statement, 0) ?? UUID().uuidString
            let source = columnText(statement, 1)
            let userId = columnText(statement, 2)
            let model = columnText(statement, 3)
            let startedAt = sqlite3_column_double(statement, 4)
            let input = Int(sqlite3_column_int64(statement, 5))
            let output = Int(sqlite3_column_int64(statement, 6))
            let cacheRead = Int(sqlite3_column_int64(statement, 7))
            let cacheWrite = Int(sqlite3_column_int64(statement, 8))
            let reasoning = Int(sqlite3_column_int64(statement, 9))
            let cost = sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 10)
            let provider = columnText(statement, 11)
            if let record = LocalUsageParser.parseHermesSessionRow(id: id, source: source, userId: userId, model: model, activityAt: startedAt, input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning, cost: cost, provider: provider, pricing: pricing) {
                records.append(record)
            }
        }
        return records
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}
