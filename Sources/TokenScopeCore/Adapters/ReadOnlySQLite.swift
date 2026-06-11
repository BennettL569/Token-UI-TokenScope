import Foundation
import SQLite3

/// Opens SQLite databases for read-only scanning, robust to WAL-mode databases whose `-wal`/`-shm`
/// sidecar files are absent.
///
/// A plain `SQLITE_OPEN_READONLY` open of a WAL-mode database fails with `SQLITE_CANTOPEN` when the
/// shared-memory file does not exist and cannot be created (because the connection is read-only).
/// That happens whenever the writing app (e.g. OpenCode) is not currently running, and it made the
/// adapter silently return zero records — that tool's usage was dropped. Falling back to an
/// `immutable=1` URI reads the main database file directly, which is correct here because the
/// fallback only triggers when no other process holds the database open (so nothing is writing it).
enum ReadOnlySQLite {
    static func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            return db
        }
        if db != nil { sqlite3_close(db); db = nil }

        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let uri = "file:\(encoded)?immutable=1"
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            return db
        }
        if db != nil { sqlite3_close(db) }
        return nil
    }
}
