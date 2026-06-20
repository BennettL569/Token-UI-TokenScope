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
    public let id: String
    public let tool: ToolKind
    public let displayName: String
    public let capabilities: AdapterCapabilities = [.supportsLocalLogs, .supportsCostEstimation]
    private let defaultPaths: [String]
    private let incrementalLookbackSeconds: Double = 24 * 60 * 60

    /// Defaults to the international Qoder install. The CN build (`Qoder CN.app`) writes the same
    /// `chat_message` schema under `~/Library/Application Support/QoderCN/...`, so it is registered
    /// as a separate tool by passing `tool: .qoderCN` and the CN `defaultPaths`.
    public init(
        tool: ToolKind = .qoder,
        displayName: String = "Qoder SQLite",
        defaultPaths: [String] = ["~/Library/Application Support/Qoder/SharedClientCache/cache/db/local.db"]
    ) {
        self.tool = tool
        self.id = tool.rawValue.lowercased() + "-sqlite"
        self.displayName = displayName
        self.defaultPaths = defaultPaths
    }

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

        // Qoder leaves chat_message.model_info empty; the real model lives in chat_record.extra
        // (modelConfig.key, per request) and chat_session.preferred_model_info (per session). Build
        // lookup maps up front, tolerating either table being absent in some Qoder versions.
        let recordModels = modelMap(db: db, sql: "SELECT request_id, extra FROM chat_record", extract: Self.modelFromRecordExtra)
        let sessionModels = modelMap(db: db, sql: "SELECT session_id, preferred_model_info FROM chat_session", extract: Self.modelFromSessionInfo)

        var sql = """
        SELECT id, session_id, request_id, token_info, model_info, gmt_create
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
            let requestId = columnText(statement, 2)
            guard let tokenInfo = columnText(statement, 3) else { continue }
            let modelInfo = columnText(statement, 4)
            let gmtCreate = sqlite3_column_double(statement, 5)
            let fallbackModel = (requestId.flatMap { recordModels[$0] }) ?? sessionModels[sessionId]
            if let record = LocalUsageParser.parseQoderMessageRow(tool: tool, id: id, sessionId: sessionId, tokenInfo: tokenInfo, modelInfo: modelInfo, gmtCreate: gmtCreate, fallbackModel: fallbackModel, rawSource: "\(path):chat_message", pricing: pricing) {
                records.append(record)
            }
        }
        return records
    }

    /// Builds a `[key: model]` map from an auxiliary table, tolerating the table being absent
    /// (`sqlite3_prepare_v2` fails → empty map). First non-empty value per key wins.
    private func modelMap(db: OpaquePointer?, sql: String, extract: (String) -> String?) -> [String: String] {
        var map: [String: String] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return map }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let key = columnText(stmt, 0), !key.isEmpty,
                  let raw = columnText(stmt, 1), let model = extract(raw) else { continue }
            if map[key] == nil { map[key] = model }
        }
        return map
    }

    /// chat_record.extra → modelConfig.key (e.g. "qmodel_latest").
    static func modelFromRecordExtra(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelConfig = obj["modelConfig"] as? [String: Any],
              let key = modelConfig["key"] as? String, !key.isEmpty else { return nil }
        return key
    }

    /// chat_session.preferred_model_info → preferred_model.
    static func modelFromSessionInfo(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = obj["preferred_model"] as? String, !model.isEmpty else { return nil }
        return model
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }
}
