import Foundation

/// How Codex usage events are keyed, and the migration from the old key.
///
/// Codex events carry no id of their own, so the request id is built from the session file plus the
/// event's timestamp and token counts. It used to embed the file's full path, but Codex moves a
/// session's file from `sessions/YYYY/MM/DD/` to `archived_sessions/` when it is archived, so every
/// archived session was counted twice: the same events under two paths. The file name embeds the
/// session's UUID, so it is unique on its own — and the same on every machine, so backups merge.
public enum CodexDedupeKey {
    /// `<session file name>#<timestamp>#<input>#<output>#<cache>`.
    public static func requestId(filePath: String, timestamp: Date, input: Int, output: Int, cache: Int) -> String {
        "\((filePath as NSString).lastPathComponent)#\(timestamp.timeIntervalSince1970)#\(input)#\(output)#\(cache)"
    }

    /// Rewrites an old full-path request id (`<rawSource>#…`) into the file-name form. Nil when the
    /// id is not in the old form — already migrated, or not a Codex id.
    public static func migratedRequestId(_ requestId: String, rawSource: String) -> String? {
        let oldPrefix = rawSource + "#"
        let fileName = (rawSource as NSString).lastPathComponent
        guard fileName != rawSource, requestId.hasPrefix(oldPrefix) else { return nil }
        return fileName + "#" + requestId.dropFirst(oldPrefix.count)
    }

    /// The dedupe key `UsageRecord` derives from a Codex request id.
    public static func dedupeKey(requestId: String) -> String {
        // `Dedupe.makeKey` ignores the remaining fields when a request id is present.
        Dedupe.makeKey(source: .codeX, requestId: requestId, timestamp: Date(timeIntervalSince1970: 0), model: "", inputTokens: 0, outputTokens: 0, cacheTokens: 0, rawSource: "")
    }

    public struct StoredRow: Sendable, Equatable {
        public var dedupeKey: String
        public var requestId: String
        public var rawSource: String

        public init(dedupeKey: String, requestId: String, rawSource: String) {
            self.dedupeKey = dedupeKey
            self.requestId = requestId
            self.rawSource = rawSource
        }
    }

    public struct Rekey: Sendable, Equatable {
        public var oldKey: String
        public var newKey: String
        public var newRequestId: String

        public init(oldKey: String, newKey: String, newRequestId: String) {
            self.oldKey = oldKey
            self.newKey = newKey
            self.newRequestId = newRequestId
        }
    }

    public struct MigrationPlan: Sendable, Equatable {
        public var rekey: [Rekey] = []
        /// Duplicates of an event another row already holds.
        public var delete: [String] = []
        public var isEmpty: Bool { rekey.isEmpty && delete.isEmpty }
    }

    /// Plans the migration of rows still keyed the old way. Rows that turn out to be the same event
    /// (one session file under its old and its archived path) collapse into one. A row already
    /// stored under the new key wins outright, since it came from the current parser; otherwise
    /// the row whose log still exists is kept, so its `rawSource` points at a live file.
    public static func migrationPlan(oldRows: [StoredRow], existingKeys: Set<String>, fileExists: (String) -> Bool) -> MigrationPlan {
        var groups: [String: [(row: StoredRow, requestId: String)]] = [:]
        for row in oldRows {
            guard let requestId = migratedRequestId(row.requestId, rawSource: row.rawSource) else { continue }
            groups[dedupeKey(requestId: requestId), default: []].append((row, requestId))
        }
        var plan = MigrationPlan()
        for (newKey, members) in groups.sorted(by: { $0.key < $1.key }) {
            if existingKeys.contains(newKey) {
                plan.delete += members.map(\.row.dedupeKey)
                continue
            }
            let ordered = members.sorted { a, b in
                let aExists = fileExists(a.row.rawSource), bExists = fileExists(b.row.rawSource)
                return aExists != bExists ? aExists : a.row.rawSource < b.row.rawSource
            }
            plan.rekey.append(Rekey(oldKey: ordered[0].row.dedupeKey, newKey: newKey, newRequestId: ordered[0].requestId))
            plan.delete += ordered.dropFirst().map(\.row.dedupeKey)
        }
        return plan
    }
}
