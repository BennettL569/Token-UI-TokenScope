import Foundation
import SQLite3

public struct OpenCodeSQLiteUsageAdapter: UsageAdapter {
    public let id = "opencode-sqlite"
    public let tool: ToolKind = .openCode
    public let displayName = "OpenCode SQLite"
    public let capabilities: AdapterCapabilities = [.supportsLocalLogs, .supportsCostEstimation]
    private let defaultPaths = ["~/.local/share/opencode/opencode.db"]
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
        SELECT id, session_id, time_created, data
        FROM message
        """
        if since != nil { sql += "\nWHERE ((time_created < 10000000000 AND time_created > ?) OR (time_created >= 10000000000 AND time_created > ?))" }
        sql += "\nORDER BY time_created ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        if let since {
            sqlite3_bind_double(statement, 1, since)
            sqlite3_bind_double(statement, 2, since * 1000.0)
        }
        defer { sqlite3_finalize(statement) }

        var records: [UsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = columnText(statement, 0) ?? UUID().uuidString
            let sessionId = columnText(statement, 1) ?? "OpenCode Local"
            let timeCreated = sqlite3_column_double(statement, 2)
            guard let data = columnText(statement, 3) else { continue }
            if let record = LocalUsageParser.parseOpenCodeMessageRow(id: id, sessionId: sessionId, timeCreated: timeCreated, data: data, rawSource: "\(path):message", pricing: pricing) {
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
