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

    @Test func codexParserExtractsModelFromTurnContext() {
        // Codex usage (`token_count`) events name no model; it's announced in a preceding
        // `turn_context` line. The adapter tracks it and threads it into the record — previously
        // every Codex record was the hardcoded "codex".
        let turnContext = """
        {"timestamp":"2026-06-13T16:45:32.008Z","type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.5","effort":"high"}}
        """
        let tokenLine = """
        {"timestamp":"2026-06-13T16:45:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3,"total_tokens":20}}}}
        """
        #expect(LocalUsageParser.codexModel(fromLine: turnContext) == "gpt-5.5")
        #expect(LocalUsageParser.codexModel(fromLine: tokenLine) == nil)
        #expect(LocalUsageParser.parseCodexLine(tokenLine, filePath: "/tmp/codex.jsonl", pricing: [], model: "gpt-5.5")?.model == "gpt-5.5")
        #expect(LocalUsageParser.parseCodexLine(tokenLine, filePath: "/tmp/codex.jsonl", pricing: [])?.model == "codex")
    }

    @Test func codexAdapterThreadsModelAndSurvivesIncrementalResume() async throws {
        // End-to-end through the real .codeX adapter: the model announced in a turn_context line must
        // land on the following token_count records (stateful LineContext threading), and an
        // incremental refresh that resumes past the turn_context must still stamp the real model
        // (recovered from the persisted cursor) rather than regressing to "codex".
        let turnContext = #"{"timestamp":"2026-06-13T16:45:32.000Z","type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.5"}}"#
        let tokenA = #"{"timestamp":"2026-06-13T16:45:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3,"total_tokens":20}}}}"#
        let tokenB = #"{"timestamp":"2026-06-13T16:46:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25,"cached_input_tokens":5,"output_tokens":4,"total_tokens":29}}}}"#

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-codex-\(UUID().uuidString).jsonl")
        let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-codex-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        }
        let adapter = AdapterRegistry.defaultAdapters()[.codeX]!
        let source = UsageSource(tool: .codeX, name: "Codex Test", accountId: "acc", apiKeyIdentity: "id", localLogPath: fileURL.path)
        let repo = PersistentUsageRepository(dbURL: dbURL)

        try (turnContext + "\n" + tokenA + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        let first = try await adapter.refresh(source: source, pricing: [], cursorStore: repo, fullScan: false)
        #expect(first.count == 1)
        #expect(first.first?.model == "gpt-5.5")

        try (turnContext + "\n" + tokenA + "\n" + tokenB + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        let second = try await adapter.refresh(source: source, pricing: [], cursorStore: repo, fullScan: false)
        #expect(second.count == 1)
        #expect(second.first?.model == "gpt-5.5")

        let full = try await adapter.refresh(source: source, pricing: [], cursorStore: nil, fullScan: true)
        #expect(full.count == 2)
        #expect(full.allSatisfy { $0.model == "gpt-5.5" })
    }

    @Test func pricingMergeSeedsNewModelsWithoutResurrectingDeleted() {
        // Fix B: a parser-version bump seeds only the genuinely-new models. User-edited rows keep
        // their values, a deleted default (not in the allowlist) is not resurrected, and the merge
        // is idempotent and case-insensitive on the model name.
        let userEdited = ModelPricing(tool: .codeX, model: "GPT-5.1-Codex", inputPerMillion: 99, outputPerMillion: 99, cachePerMillion: 9)
        let existing = [userEdited]
        let merged = UsageStore.pricingByAddingMissingDefaults(UsageStore.modelsAddedInParserV4, to: existing, from: UsageStore.defaultPricing())
        #expect(merged.contains { $0.tool == .codeX && $0.model == "gpt-5.5" })
        #expect(merged.contains { $0.tool == .codeX && $0.model == "gpt-5.4" })
        #expect(merged.contains { $0.tool == .codeX && $0.model == "gpt-5.4-mini" })
        #expect(merged.first { $0.model == "GPT-5.1-Codex" }?.inputPerMillion == 99)
        #expect(!merged.contains { $0.model.lowercased() == "gpt-5.1-codex" && $0.inputPerMillion != 99 })
        #expect(!merged.contains { $0.model == "gpt-5-mini" })
        let again = UsageStore.pricingByAddingMissingDefaults(UsageStore.modelsAddedInParserV4, to: merged, from: UsageStore.defaultPricing())
        #expect(again.count == merged.count)
    }

    @Test func toolKindReportsCacheCreationOnlyForWritingTools() {
        // Codex follows OpenAI accounting (cache reads only, no cache-write tokens), so its cache
        // creation is structurally 0; the dashboard uses this flag to explain that 0.
        #expect(ToolKind.codeX.reportsCacheCreation == false)
        #expect(ToolKind.claudeCode.reportsCacheCreation)
        #expect(ToolKind.hermes.reportsCacheCreation)
        #expect(ToolKind.openClaw.reportsCacheCreation)
        #expect(ToolKind.openCode.reportsCacheCreation)
    }

    @Test func exportRedactsRawSourceWhenIdentifiersExcluded() throws {
        // A redacted export must not leak the local path/username in rawSource or the account id.
        let record = UsageRecord(source: .claudeCode, accountId: "acct-secret", apiKeyHash: "key-secret", model: "m", timestamp: Date(timeIntervalSince1970: 1_700_000_000), inputTokens: 1, outputTokens: 1, cacheTokens: 0, estimatedCost: 0, rawSource: "/Users/somebody/.claude/projects/secret/x.jsonl")
        // JSONEncoder escapes "/" as "\/", so match on slash-free substrings.
        let redacted = try ExportService.export(records: [record], format: .json, includeIdentifiers: false)
        #expect(!redacted.contains("somebody"))
        #expect(!redacted.contains("acct-secret"))
        #expect(redacted.contains("redacted"))
        let full = try ExportService.export(records: [record], format: .json, includeIdentifiers: true)
        #expect(full.contains("somebody"))
    }

    @Test func codexParserSkipsCumulativeOnlyTokenCount() {
        // Only the per-event delta is counted; a cumulative-only event is skipped (avoids over-count).
        let totalOnly = #"{"timestamp":"2026-06-13T16:45:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9999,"output_tokens":8888,"total_tokens":18887}}}}"#
        #expect(LocalUsageParser.parseCodexLine(totalOnly, filePath: "/tmp/c.jsonl", pricing: []) == nil)
        let withLast = #"{"timestamp":"2026-06-13T16:45:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3,"total_tokens":20}}}}"#
        #expect(LocalUsageParser.parseCodexLine(withLast, filePath: "/tmp/c.jsonl", pricing: []) != nil)
    }

    @Test func updateServiceComparesVersionsNumerically() {
        // "1.1.10" must beat "1.1.9" (plain string compare would not); v-prefix tolerated.
        #expect(UpdateService.compare("1.1.10", "1.1.9") == .orderedDescending)
        #expect(UpdateService.compare("1.1.5", "1.1.5") == .orderedSame)
        #expect(UpdateService.compare("v1.2.0", "1.2") == .orderedSame)
        #expect(UpdateService.isUpdateAvailable(latest: "1.1.6", current: "1.1.5"))
        #expect(!UpdateService.isUpdateAvailable(latest: "1.1.5", current: "1.1.5"))
        #expect(!UpdateService.isUpdateAvailable(latest: "1.1.5", current: "1.2.0"))
    }

    @Test func updateServiceParsesGitHubRelease() {
        let json = """
        {"tag_name":"v1.1.6","html_url":"https://github.com/o/r/releases/tag/v1.1.6","body":"notes here",
         "assets":[
           {"name":"TokenScope-1.1.6.dmg","browser_download_url":"https://example.com/TokenScope-1.1.6.dmg"},
           {"name":"TokenScope-1.1.6-macOS.zip","browser_download_url":"https://example.com/TokenScope-1.1.6-macOS.zip"}
         ]}
        """
        let release = UpdateService.parseRelease(Data(json.utf8))
        #expect(release?.tagName == "v1.1.6")
        #expect(release?.version == "1.1.6")
        #expect(release?.zipURL?.absoluteString == "https://example.com/TokenScope-1.1.6-macOS.zip")
        #expect(release?.htmlURL != nil)
        #expect(release?.notes == "notes here")
        #expect(UpdateService.parseRelease(Data("not json".utf8)) == nil)
    }

    @Test func refreshCursorsMigratesModelColumnOnOldDatabase() throws {
        // Fix A migration: a refresh_cursors table predating the `model` column gains it on open,
        // pre-migration rows read back a nil model, and new model read/writes work.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-curmig-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        var writer: OpaquePointer?
        #expect(sqlite3_open(url.path, &writer) == SQLITE_OK)
        #expect(sqlite3_exec(writer, """
        CREATE TABLE refresh_cursors (
            source TEXT NOT NULL, raw_source TEXT NOT NULL, position REAL NOT NULL,
            updated_at REAL NOT NULL, PRIMARY KEY (source, raw_source)
        );
        INSERT INTO refresh_cursors (source, raw_source, position, updated_at)
        VALUES ('CodeX', '/tmp/x.jsonl', 10, 0);
        """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(writer)

        let repo = PersistentUsageRepository(dbURL: url)
        #expect(repo.refreshCursorModel(source: .codeX, rawSource: "/tmp/x.jsonl") == nil)
        repo.setRefreshCursor(source: .codeX, rawSource: "/tmp/x.jsonl", position: 20, model: "gpt-5.5")
        #expect(repo.refreshCursorModel(source: .codeX, rawSource: "/tmp/x.jsonl") == "gpt-5.5")
        #expect(repo.refreshCursor(source: .codeX, rawSource: "/tmp/x.jsonl") == 20)
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
