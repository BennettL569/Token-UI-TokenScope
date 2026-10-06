import Foundation

/// Automatic snapshots of the usage database, taken before any operation that deletes or rewrites
/// stored usage: a full rebuild, clearing local data, importing a backup, a data migration.
///
/// Usage whose source logs are gone exists only in this database (Claude Code deletes transcripts
/// after 30 days), so a mistake in any of those operations could not be undone by re-reading logs.
/// Each snapshot is a plain SQLite copy in the database's `Backups` folder, which the import screen
/// accepts to restore from. The newest `keep` snapshots of each database are retained.
public enum SafetyBackups {
    public static let keep = 5

    /// Snapshots `repository` and prunes older snapshots of the same database. Returns the new file.
    @discardableResult
    public static func create(of repository: PersistentUsageRepository, reason: String, now: Date = Date()) throws -> URL {
        let directory = repository.safetyBackupDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(prefix(for: repository))-\(formatter.string(from: now))-\(reason)"
        var url = directory.appendingPathComponent("\(base).sqlite")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(suffix).sqlite")
            suffix += 1
        }
        try repository.writeSnapshot(to: url)
        for stale in list(for: repository).dropFirst(keep) {
            try? FileManager.default.removeItem(at: stale)
        }
        return url
    }

    /// Snapshots of `repository`'s database, newest first.
    public static func list(for repository: PersistentUsageRepository) -> [URL] {
        let directory = repository.safetyBackupDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        // "<database>-yyyyMMdd-HHmmss-<reason>.sqlite". Requiring the timestamp keeps another
        // database's snapshots (say "usage-2-…") from being counted as this one's, and names sort
        // chronologically because the timestamp follows the fixed prefix.
        let pattern = "^" + NSRegularExpression.escapedPattern(for: prefix(for: repository)) + #"-\d{8}-\d{6}-.+\.sqlite$"#
        return names
            .filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }

    private static func prefix(for repository: PersistentUsageRepository) -> String {
        repository.databaseURL.deletingPathExtension().lastPathComponent
    }
}
