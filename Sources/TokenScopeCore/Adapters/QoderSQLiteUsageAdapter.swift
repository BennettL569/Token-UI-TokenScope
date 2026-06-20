import Foundation
import SQLite3

/// Reads Qoder (Alibaba's AI IDE) token usage from its local SQLite cache, by default
/// `~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db`. Each row of the
/// `chat_message` table is one message; usage is a JSON blob in `token_info` and the model in
/// `model_info` (also JSON, or a bare model string). Opened read-only.
///
/// NOTE: this database lives under a *cache* directory and the exact `token_info` schema has not yet
/// been confirmed against real data (the table is empty until Qoder is actually used), so the parser
/// in `LocalUsageParser.parseQoderMessageRow` is intentionally lenient — it accepts flat or nested
/// usage shapes and the usual snake/camel-case field names. Re-verify the field mapping once real
/// rows exist.
public struct QoderSQLiteUsageAdapter: UsageAdapter {
    public let id = "qoder-sqlite"
    public let tool: ToolKind = .qoder
    public let displayName = "Qoder SQLite"
    public let capabilities: AdapterCapabilities = [.supportsLocalLogs, .supportsCostEstimation]
    private let defaultPaths = ["~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db"]
    private let incrementalLookbackSeconds: Double = 24 * 60 * 60

    public init() {}

    public func refresh(source: UsageSource, pricing: [ModelPricing], cursorStore: UsageCursorStore? = nil, fullScan: Bool = false) async throws -> [UsageRecord] {
        guard source.isEnabled else { throw AdapterError.sourceDisabled }
        let paths = FileDiscovery.expand(paths: source.localLogPath.isEmpty ? defaultPaths : [source.localLogPath])
        var all: [UsageRecord] = []
        for path in paths {
            let since = fullScan ? nil : cursorStore?.refreshCursor(source: tool, rawSource: path)
            let effectiveSince = since.map { max(0, $0 - incrementalLookbackSeconds) }
            let records = readMessages(path: path, pricing: pricing, since: effectiveSince)
            all.append(contentsOf: records)
            if let maxTimestamp = records.map(\.timestamp.timeIntervalSince1970).max() {
                cursorStore?.setRefreshCursor(source: tool, rawSource: path, position: maxTimestamp)
            } else if fullScan {
                cursorStore?.setRefreshCursor(source: tool, rawSource: path, position: Date().timeIntervalSince1970)
            }
        }
        return all
    }

    private func readMessages(path: String, pricing: [ModelPricing], since: Double?) -> [UsageRecord] {
        guard let db = ReadOnlySQLite.open(path) else { return [] }
        defer { sqlite3_close(db) }

        var sql = """
        SELECT id, session_id, token_info, model_info, gmt_create
        FROM chat_message
        WHERE token_info IS NOT NULL AND token_info != ''
        """
        // gmt_create can be stored in seconds or milliseconds; compare against both forms of the
        // cursor (which is kept in seconds), mirroring the OpenCode adapter.
        if since != nil { sql += "\nAND ((gmt_create < 10000000000 AND gmt_create > ?) OR (gmt_create >= 10000000000 AND gmt_create > ?))" }
        sql += "\nORDER BY gmt_create ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        if let since {
            sqlite3_bind_double(statement, 1, since)
            sqlite3_bind_double(statement, 2, since * 1000.0)
        }
        defer { sqlite3_finalize(statement) }

        var records: [UsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // Skip rows without a stable id: a random UUID fallback would change the dedupe key on
            // every scan and re-insert the same row as a duplicate within the 24h lookback window.
            guard let id = columnText(statement, 0), !id.isEmpty else { continue }
            let sessionId = columnText(statement, 1) ?? "Qoder Local"
            guard let tokenInfo = columnText(statement, 2) else { continue }
            let modelInfo = columnText(statement, 3)
            let gmtCreate = sqlite3_column_double(statement, 4)
            if let record = LocalUsageParser.parseQoderMessageRow(id: id, sessionId: sessionId, tokenInfo: tokenInfo, modelInfo: modelInfo, gmtCreate: gmtCreate, rawSource: "\(path):chat_message", pricing: pricing) {
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
