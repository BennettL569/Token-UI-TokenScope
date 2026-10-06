import Foundation

/// Decides which stored records a full rebuild may delete.
///
/// A rebuild re-reads every log it can still find and upserts the result. It must never drop usage
/// whose logs are gone: Claude Code deletes transcripts after 30 days, so for older usage this
/// database is the only copy. A record is removed only when the current parser, reading the very
/// file the record came from, no longer produces it — a leftover of an older parse whose dedupe key
/// changed, or an event the parser now skips. All of these must hold:
///  • its tool reported the record's `rawSource` as read in full this pass. Only append-only JSONL
///    logs report that; the SQLite sources can lose rows (a deleted session) while their file
///    stays, so they are never pruned;
///  • the file has not shrunk since it was last synced — a rewritten file no longer holds the whole
///    history, so nothing derived from it is pruned;
///  • every key the pass produced for that tool is actually stored (the upsert landed);
///  • and the record's own key is not among them.
public enum RebuildPruning {
    public static func staleKeys(
        stored: [UsageRecord],
        producedKeys: [ToolKind: Set<String>],
        fullyReadFiles: [ToolKind: [String: Int64]],
        previousCursorPositions: [RefreshCursorKey: Double]
    ) -> [String] {
        let storedKeys = Set(stored.map(\.dedupeKey))
        var prunableFiles: [ToolKind: Set<String>] = [:]
        for (tool, files) in fullyReadFiles {
            guard (producedKeys[tool] ?? []).isSubset(of: storedKeys) else { continue }
            let unshrunk = files.filter { path, size in
                Double(size) >= previousCursorPositions[RefreshCursorKey(tool: tool, rawSource: path)] ?? 0
            }
            if !unshrunk.isEmpty { prunableFiles[tool] = Set(unshrunk.keys) }
        }
        guard !prunableFiles.isEmpty else { return [] }
        return stored.compactMap { record in
            guard prunableFiles[record.source]?.contains(record.rawSource) == true,
                  producedKeys[record.source]?.contains(record.dedupeKey) != true else { return nil }
            return record.dedupeKey
        }
    }
}
