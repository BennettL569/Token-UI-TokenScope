import Testing
import Foundation
import SQLite3
@testable import TokenScopeCore

@Suite("TokenScope Core")
struct TokenScopeTests {
    @Test func pricingEngineCalculatesInputOutputAndCacheCost() {
        let pricing = ModelPricing(tool: .hermes, model: "gpt-5.5", inputPerMillion: 2, outputPerMillion: 10, cachePerMillion: 1)
        let cost = PricingEngine.estimate(inputTokens: 1_000_000, outputTokens: 500_000, cacheTokens: 250_000, pricing: pricing)
        #expect(abs(NSDecimalNumber(decimal: cost).doubleValue - 7.25) < 0.0001)
    }

    @Test func dedupeUsesRequestIdWhenAvailable() {
        let key = Dedupe.makeKey(source: .hermes, requestId: "req_123", timestamp: Date(timeIntervalSince1970: 1), model: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 3, rawSource: "raw")
        #expect(key == "Hermes::request::req_123")
    }

    @Test func dedupeFallbackIsStableForSamePayload() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Dedupe.makeKey(source: .codeX, requestId: nil, timestamp: date, model: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 3, rawSource: "raw")
        let second = Dedupe.makeKey(source: .codeX, requestId: nil, timestamp: date, model: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 3, rawSource: "raw")
        #expect(first == second)
        #expect(first.hasPrefix("CodeX::fallback::"))
    }

    @Test func maskingDoesNotExposeFullAPIKey() {
        let masked = Masking.maskAPIKey("sk-test-secret-abcd")
        #expect(masked == "sk--...abcd")
        #expect(!masked.contains("secret"))
    }

    @Test func aggregationFiltersToday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = calendar.date(byAdding: .day, value: -2, to: now)!
        let records = [
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 10, outputTokens: 20, cacheTokens: 5, estimatedCost: 1, rawSource: "1"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: old, inputTokens: 100, outputTokens: 200, cacheTokens: 50, estimatedCost: 10, rawSource: "2")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .today, now: now, calendar: calendar)
        #expect(usage.totalTokens == 35)
        #expect(NSDecimalNumber(decimal: usage.estimatedCost).doubleValue == 1)
    }

    @Test func aggregationCustomRangeIncludesEndDayButNotNextDay() {
        // Locks the custom-range boundary after the per-record→precomputed-bounds optimization:
        // the end day is inclusive through 23:59:59 and the next day is excluded.
        let calendar = Calendar(identifier: .gregorian)
        let startOfDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let records = [
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: startOfDay.addingTimeInterval(60 * 60), inputTokens: 10, outputTokens: 0, cacheTokens: 0, estimatedCost: 0, rawSource: "1"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: startOfDay.addingTimeInterval(23 * 60 * 60), inputTokens: 20, outputTokens: 0, cacheTokens: 0, estimatedCost: 0, rawSource: "2"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: startOfDay.addingTimeInterval(25 * 60 * 60), inputTokens: 100, outputTokens: 0, cacheTokens: 0, estimatedCost: 0, rawSource: "3")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .all, customRange: CustomDateRange(start: startOfDay, end: startOfDay), calendar: calendar)
        #expect(usage.totalTokens == 30)
    }

    @Test func aggregatedUsageReportsCacheHitRate() {
        let usage = AggregatedUsage(inputTokens: 75, outputTokens: 25, cacheTokens: 25, totalTokens: 125, estimatedCost: 0)
        #expect(usage.billableTokens == 100)
        #expect(abs(usage.cacheHitRate - 0.25) < 0.0001)
    }

    @Test func aggregatedUsageCacheHitRateIsZeroWhenNoPromptTokens() {
        let usage = AggregatedUsage(inputTokens: 0, outputTokens: 20, cacheTokens: 0, totalTokens: 20, estimatedCost: 0)
        #expect(usage.cacheHitRate == 0)
    }

    @Test func aggregationCarriesCacheHitRateFromRecords() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 80, outputTokens: 20, cacheTokens: 20, estimatedCost: 1, rawSource: "1"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 20, outputTokens: 10, cacheTokens: 30, estimatedCost: 1, rawSource: "2")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .today, now: now)
        #expect(usage.cacheTokens == 50)
        #expect(abs(usage.cacheHitRate - (50.0 / 150.0)) < 0.0001)
    }

    @Test func usageStoreBuildsDashboardSnapshotAndUpdatesSelectedRange() {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-dashboard-snapshot-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let repository = PersistentUsageRepository(dbURL: dbURL)
        let now = Date()
        repository.upsert([
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 10, outputTokens: 20, cacheTokens: 5, estimatedCost: 1, rawSource: "1"),
            UsageRecord(source: .codeX, accountId: "b", apiKeyHash: "k", model: "m", timestamp: now.addingTimeInterval(-40 * 24 * 60 * 60), inputTokens: 100, outputTokens: 200, cacheTokens: 50, estimatedCost: 2, rawSource: "2")
        ])
        let store = UsageStore(repository: repository)

        #expect(store.dashboardSnapshot.today.totalTokens == 35)
        #expect(store.dashboardSnapshot.all.totalTokens == 385)
        #expect(store.dashboardSnapshot.selected.totalTokens == 35)

        // Filter changes rebuild the snapshot off the main thread; force it synchronously here.
        store.selectedRange = .all
        store.rebuildDashboardSnapshot()
        #expect(store.dashboardSnapshot.selected.totalTokens == 385)
        #expect(store.dashboardSnapshot.recentRecords.count == 2)
    }

    @Test func pricingCanBeDeleted() {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-pricing-delete-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let keep = ModelPricing(tool: .hermes, model: "keep-model", inputPerMillion: 1, outputPerMillion: 2, cachePerMillion: 0.1)
        let drop = ModelPricing(tool: .codeX, model: "drop-model", inputPerMillion: 3, outputPerMillion: 4, cachePerMillion: 0.2)
        let repository = PersistentUsageRepository(dbURL: dbURL)
        repository.savePricing([keep, drop])

        // Repository-level delete removes only the targeted (tool, model) row and persists.
        repository.deletePricing(drop)
        let reloaded = PersistentUsageRepository(dbURL: dbURL).loadPricing()
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.id == keep.id)

        // Store-level delete removes the item from the in-memory published list.
        let store = UsageStore(repository: PersistentUsageRepository(dbURL: dbURL))
        store.setPricing(drop)
        #expect(store.pricing.contains { $0.id == drop.id })
        store.deletePricing(drop)
        #expect(!store.pricing.contains { $0.id == drop.id })
        #expect(store.pricing.contains { $0.id == keep.id })
    }

    @Test func dashboardSnapshotFiltersBySearchAndToolWithStableBaseAggregates() {
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-snapshot-filter-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let repository = PersistentUsageRepository(dbURL: dbURL)
        let now = Date()
        repository.upsert([
            UsageRecord(source: .hermes, accountId: "alpha", apiKeyHash: "k1", model: "gpt-5.5", timestamp: now, inputTokens: 10, outputTokens: 20, cacheTokens: 5, estimatedCost: 1, rawSource: "r1"),
            UsageRecord(source: .codeX, accountId: "beta", apiKeyHash: "k2", model: "gpt-5-mini", timestamp: now.addingTimeInterval(-1), inputTokens: 100, outputTokens: 200, cacheTokens: 50, estimatedCost: 2, rawSource: "r2"),
            UsageRecord(source: .hermes, accountId: "alpha", apiKeyHash: "k3", model: "claude", timestamp: now.addingTimeInterval(-2), inputTokens: 1, outputTokens: 2, cacheTokens: 3, estimatedCost: 0.5, rawSource: "r3")
        ])
        let store = UsageStore(repository: repository)

        // Base, filter-independent aggregates cover every record (35 + 350 + 6 = 391).
        #expect(store.dashboardSnapshot.today.totalTokens == 391)
        #expect(store.dashboardSnapshot.all.totalTokens == 391)
        #expect(store.dashboardSnapshot.selected.totalTokens == 391)
        #expect(store.dashboardSnapshot.recentRecords.count == 3)

        // Search by account substring → only the two "alpha" hermes rows (35 + 6 = 41).
        // Filter changes rebuild the snapshot off the main thread; force it synchronously here.
        store.searchText = "alpha"
        store.rebuildDashboardSnapshot()
        #expect(store.dashboardSnapshot.selected.totalTokens == 41)
        #expect(store.dashboardSnapshot.toolGroups.count == 1)
        #expect(store.dashboardSnapshot.toolGroups[.hermes]?.totalTokens == 41)
        // Base aggregates remain correct while filters change.
        #expect(store.dashboardSnapshot.today.totalTokens == 391)

        // Search by model substring → only the codeX row (350).
        store.searchText = "gpt-5-mini"
        store.rebuildDashboardSnapshot()
        #expect(store.dashboardSnapshot.selected.totalTokens == 350)
        #expect(store.dashboardSnapshot.toolGroups[.codeX]?.totalTokens == 350)

        // Tool filter (no search) → only codeX (350).
        store.searchText = ""
        store.selectedTool = .codeX
        store.rebuildDashboardSnapshot()
        #expect(store.dashboardSnapshot.selected.totalTokens == 350)
        #expect(store.dashboardSnapshot.recentRecords.count == 1)

        // Clearing filters and widening the range restores the full set.
        store.selectedTool = nil
        store.selectedRange = .all
        store.rebuildDashboardSnapshot()
        #expect(store.dashboardSnapshot.selected.totalTokens == 391)
        #expect(store.dashboardSnapshot.recentRecords.count == 3)
        #expect(store.dashboardSnapshot.all.totalTokens == 391)
    }

    @Test func claudeParserDoesNotDoubleCountCacheCreation() {
        // cache_creation_input_tokens (2170) == sum of the cache_creation.ephemeral_* breakdown,
        // so cache must be 2170 + cache_read (16218) = 18388, not 2170 + 16218 + 2170.
        let line = """
        {"type":"assistant","uuid":"u2","timestamp":"2026-05-11T19:59:41.206Z","message":{"id":"m2","model":"claude-sonnet-4.5","usage":{"input_tokens":2,"output_tokens":10,"cache_creation_input_tokens":2170,"cache_read_input_tokens":16218,"cache_creation":{"ephemeral_5m_input_tokens":2170,"ephemeral_1h_input_tokens":0}}}}
        """
        let record = LocalUsageParser.parseClaudeLine(line, filePath: "/tmp/claude.jsonl", pricing: [])
        #expect(record?.cacheTokens == 18388)
        #expect(record?.totalTokens == 2 + 10 + 18388)
        #expect(record?.cacheCreationTokens == 2170)
        #expect(record?.cacheReadTokens == 16218)
    }

    @Test func codexParserUsesDisjointTokenBuckets() {
        // Codex follows OpenAI accounting: total == input + output, cached ⊆ input, reasoning ⊆ output.
        let line = """
        {"timestamp":"2026-04-18T15:41:12.238Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3,"reasoning_output_tokens":2,"total_tokens":20}}}}
        """
        let record = LocalUsageParser.parseCodexLine(line, filePath: "/tmp/codex.jsonl", pricing: [])
        #expect(record?.inputTokens == 10)
        #expect(record?.outputTokens == 3)
        #expect(record?.cacheTokens == 7)
        #expect(record?.totalTokens == 20)
        #expect(record?.cacheCreationTokens == 0)
        #expect(record?.cacheReadTokens == 7)
    }

    @Test func aggregationTracksRequestCountAndCacheCreation() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            UsageRecord(source: .claudeCode, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 10, outputTokens: 5, cacheTokens: 100, cacheCreationTokens: 30, estimatedCost: 0, rawSource: "1"),
            UsageRecord(source: .claudeCode, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 20, outputTokens: 8, cacheTokens: 50, cacheCreationTokens: 20, estimatedCost: 0, rawSource: "2")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .today, now: now)
        #expect(usage.requestCount == 2)
        #expect(usage.cacheCreationTokens == 50)
        #expect(usage.cacheReadTokens == 100)
    }

    @Test func readOnlySQLiteReadsWalDatabaseAfterWriterClosed() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-walro-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        // Create a WAL-mode database, write rows, then close it (a clean close removes the
        // -wal/-shm sidecars). A plain SQLITE_OPEN_READONLY open of what remains can fail with
        // SQLITE_CANTOPEN; the robust helper must still return a usable handle.
        var writer: OpaquePointer?
        #expect(sqlite3_open(url.path, &writer) == SQLITE_OK)
        sqlite3_exec(writer, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(writer, "CREATE TABLE t (id INTEGER)", nil, nil, nil)
        sqlite3_exec(writer, "INSERT INTO t (id) VALUES (1),(2),(3)", nil, nil, nil)
        sqlite3_close(writer)

        let db = ReadOnlySQLite.open(url.path)
        #expect(db != nil)
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM t", -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int64(stmt, 0) == 3)
        sqlite3_finalize(stmt)
        if let db { sqlite3_close(db) }
    }

    @Test func budgetAlertLevels() {
        #expect(BudgetEngine.alertLevel(progress: 0.5) == .normal)
        #expect(BudgetEngine.alertLevel(progress: 0.8) == .warning)
        #expect(BudgetEngine.alertLevel(progress: 1.0) == .exceeded)
    }

    @Test func exportRedactsIdentifiersByDefault() throws {
        let record = UsageRecord(source: .claudeCode, accountId: "account", apiKeyHash: "sk-...abcd", model: "claude", timestamp: Date(timeIntervalSince1970: 0), inputTokens: 1, outputTokens: 2, cacheTokens: 3, estimatedCost: 0.1, rawSource: "raw")
        let csv = try ExportService.export(records: [record], format: .csv, includeIdentifiers: false)
        #expect(csv.contains("redacted"))
        #expect(!csv.contains(",account,"))
    }

    @Test func repositoryDeduplicatesRecords() async {
        let repository = UsageRepository()
        let first = UsageRecord(source: .openClaw, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 1, outputTokens: 1, cacheTokens: 0, requestId: "same", rawSource: "raw")
        let second = UsageRecord(source: .openClaw, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 2, outputTokens: 2, cacheTokens: 0, requestId: "same", rawSource: "raw")
        await repository.upsert([first, second])
        let all = await repository.all()
        #expect(all.count == 1)
        #expect(all[0].totalTokens == 4)
    }
}
