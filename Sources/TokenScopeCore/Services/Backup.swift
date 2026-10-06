import Foundation
import SQLite3

/// A full, lossless backup of the usage database: every record plus pricing and budgets.
///
/// Unlike `ExportService` (a report of the filtered view, identifiers redacted by default) this
/// keeps every field, including the dedupe key, so importing it restores exactly what was exported.
/// Values are kept as the database stores them — timestamps as Unix seconds and money as Double —
/// so a round trip loses nothing. `totalTokens` is not stored: it is always input + output + cache.
public struct UsageBackup: Codable, Sendable, Equatable {
    public static let formatIdentifier = "tokenscope-backup"
    public static let currentFormatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var exportedAt: Date
    public var appVersion: String?
    /// Lets a reader detect a truncated file: it must equal `records.count`.
    public var recordCount: Int
    public var records: [Record]
    public var pricing: [Pricing]
    public var budgets: [Budget]

    public init(exportedAt: Date, appVersion: String?, records: [Record], pricing: [Pricing], budgets: [Budget]) {
        self.format = Self.formatIdentifier
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.recordCount = records.count
        self.records = records
        self.pricing = pricing
        self.budgets = budgets
    }

    /// One `usage_records` row. `source` stays a raw string so a row from a tool this version
    /// doesn't know still round-trips instead of being dropped.
    public struct Record: Codable, Sendable, Equatable {
        public var dedupeKey: String
        public var id: String
        public var source: String
        public var accountId: String
        public var apiKeyHash: String
        public var model: String
        public var timestamp: Double
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheTokens: Int
        public var cacheCreationTokens: Int
        public var estimatedCost: Double
        public var requestId: String?
        public var rawSource: String

        public init(dedupeKey: String, id: String, source: String, accountId: String, apiKeyHash: String, model: String, timestamp: Double, inputTokens: Int, outputTokens: Int, cacheTokens: Int, cacheCreationTokens: Int, estimatedCost: Double, requestId: String?, rawSource: String) {
            self.dedupeKey = dedupeKey
            self.id = id
            self.source = source
            self.accountId = accountId
            self.apiKeyHash = apiKeyHash
            self.model = model
            self.timestamp = timestamp
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheTokens = cacheTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.estimatedCost = estimatedCost
            self.requestId = requestId
            self.rawSource = rawSource
        }
    }

    public struct Pricing: Codable, Sendable, Equatable {
        public var tool: String
        public var model: String
        public var inputPerMillion: Double
        public var outputPerMillion: Double
        public var cachePerMillion: Double

        public init(tool: String, model: String, inputPerMillion: Double, outputPerMillion: Double, cachePerMillion: Double) {
            self.tool = tool
            self.model = model
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
            self.cachePerMillion = cachePerMillion
        }
    }

    public struct Budget: Codable, Sendable, Equatable {
        /// A `BudgetPeriod` raw value ("每日" / "每周" / "每月").
        public var period: String
        public var tokenLimit: Int
        public var costLimit: Double

        public init(period: String, tokenLimit: Int, costLimit: Double) {
            self.period = period
            self.tokenLimit = tokenLimit
            self.costLimit = costLimit
        }
    }
}

/// What importing a backup would do, worked out before anything is written so it can be confirmed.
public struct BackupImportPreview: Sendable {
    public var backup: UsageBackup
    /// Records whose dedupe key this database doesn't have yet: the ones an import adds.
    public var newRecordCount: Int
    /// Records already stored here; the import keeps the local copy.
    public var existingRecordCount: Int
    /// Among the new records, those from tools this version doesn't know. They are still stored
    /// (and carried into future backups) and show up once the app is updated.
    public var unsupportedToolRecordCount: Int

    public init(backup: UsageBackup, existingKeys: Set<String>) {
        var normalized = backup
        normalized.records = backup.records.map(Self.normalized)
        self.backup = normalized
        var seen = Set<String>()
        var new = 0, existing = 0, unsupported = 0
        for record in normalized.records where seen.insert(record.dedupeKey).inserted {
            if existingKeys.contains(record.dedupeKey) {
                existing += 1
            } else {
                new += 1
                if ToolKind(rawValue: record.source) == nil { unsupported += 1 }
            }
        }
        self.newRecordCount = new
        self.existingRecordCount = existing
        self.unsupportedToolRecordCount = unsupported
    }

    /// Re-keys a Codex record still in the old full-path form (`CodexDedupeKey`) so it matches the
    /// keys this database uses; anything else is returned unchanged.
    static func normalized(_ record: UsageBackup.Record) -> UsageBackup.Record {
        guard record.source == ToolKind.codeX.rawValue, let requestId = record.requestId,
              let migrated = CodexDedupeKey.migratedRequestId(requestId, rawSource: record.rawSource) else { return record }
        var copy = record
        copy.requestId = migrated
        copy.dedupeKey = CodexDedupeKey.dedupeKey(requestId: migrated)
        return copy
    }
}

public enum BackupError: Error, LocalizedError, Equatable {
    case notABackup
    case newerFormat(Int)
    case incomplete(expected: Int, found: Int)
    case verificationFailed
    case busy

    public func message(_ language: AppLanguage) -> String {
        switch self {
        case .notABackup:
            return language.select("This file is not a TokenScope backup.", "这个文件不是 TokenScope 备份。")
        case .newerFormat(let version):
            return language.select("This backup was made by a newer TokenScope (format \(version)). Update the app to import it.", "这个备份来自更新版本的 TokenScope（格式 \(version)），请先升级应用再导入。")
        case .incomplete(let expected, let found):
            return language.select("The backup file is incomplete: it should hold \(expected) records but has \(found).", "备份文件不完整：应有 \(expected) 条记录，实际只有 \(found) 条。")
        case .verificationFailed:
            return language.select("The written backup did not read back identically, so it was deleted. Your data is untouched; please try again.", "写出的备份回读校验不一致，已删除该文件。现有数据没有受到影响，请重试。")
        case .busy:
            return language.select("A refresh is running; try again when it finishes.", "正在刷新数据，请稍后再试。")
        }
    }

    public var errorDescription: String? { message(.english) }
}

public enum BackupService {
    public static func encode(_ backup: UsageBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    public static func decode(_ data: Data) throws -> UsageBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Check the header first so an unrelated JSON file gets "not a backup" rather than a
        // decoding error, and a newer format is refused before its body is misread.
        struct Header: Decodable {
            var format: String?
            var formatVersion: Int?
        }
        guard let header = try? decoder.decode(Header.self, from: data),
              header.format == UsageBackup.formatIdentifier,
              let version = header.formatVersion else { throw BackupError.notABackup }
        guard version <= UsageBackup.currentFormatVersion else { throw BackupError.newerFormat(version) }
        let backup = try decoder.decode(UsageBackup.self, from: data)
        guard backup.records.count == backup.recordCount else {
            throw BackupError.incomplete(expected: backup.recordCount, found: backup.records.count)
        }
        return backup
    }

    /// Writes `backup` to `url` atomically, then reads the file back and checks it decodes to the
    /// same content, so a backup reported as written is known to be restorable. A file that fails
    /// the check is deleted rather than left looking like a good backup.
    public static func write(_ backup: UsageBackup, to url: URL) throws {
        try encode(backup).write(to: url, options: .atomic)
        let reread: UsageBackup
        do {
            reread = try decode(Data(contentsOf: url))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw BackupError.verificationFailed
        }
        guard reread.records == backup.records, reread.pricing == backup.pricing, reread.budgets == backup.budgets else {
            try? FileManager.default.removeItem(at: url)
            throw BackupError.verificationFailed
        }
    }

    /// Reads a backup: a JSON file written by `write`, or a SQLite database — one of the
    /// `SafetyBackups` snapshots, or a copy of `usage.sqlite`.
    public static func read(from url: URL) throws -> UsageBackup {
        let handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 16) ?? Data()
        try handle.close()
        if header == Data("SQLite format 3\0".utf8) {
            return try readDatabase(at: url)
        }
        return try decode(Data(contentsOf: url))
    }

    /// Reads a usage database through a temporary copy: opening a database migrates it, and the
    /// file the user picked must never be modified.
    private static func readDatabase(at url: URL) throws -> UsageBackup {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("usage.sqlite")
        try FileManager.default.copyItem(at: url, to: copy)
        // A live database may still hold recent writes in its WAL file.
        let wal = url.path + "-wal"
        if FileManager.default.fileExists(atPath: wal) {
            try FileManager.default.copyItem(atPath: wal, toPath: copy.path + "-wal")
        }
        guard containsUsageTable(copy.path) else { throw BackupError.notABackup }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        return try PersistentUsageRepository(dbURL: copy).exportBackup(exportedAt: modified, appVersion: nil)
    }

    private static func containsUsageTable(_ path: String) -> Bool {
        guard let db = ReadOnlySQLite.open(path) else { return false }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_records'", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
