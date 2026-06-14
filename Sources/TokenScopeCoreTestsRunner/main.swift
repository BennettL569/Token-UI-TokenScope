import Foundation
import SQLite3
import TokenScopeCore

@main
struct TokenScopeCoreTestsRunner {
    static func main() async throws {
        try pricingEngineCalculatesInputOutputAndCacheCost()
        try dedupeUsesRequestIdWhenAvailable()
        try dedupeFallbackIsStableForSamePayload()
        try maskingDoesNotExposeFullAPIKey()
        try aggregationFiltersToday()
        try aggregationFiltersCustomDateRange()
        try aggregationCustomRangeIncludesEndDayButNotNextDay()
        try aggregationTracksRequestCountAndCacheCreation()
        try budgetAlertLevels()
        try exportRedactsIdentifiersByDefault()
        try await repositoryDeduplicatesRecords()
        try claudeParserReadsUsageLine()
        try claudeParserDoesNotDoubleCountCacheCreation()
        try codexParserReadsTokenCountLine()
        try codexParserExtractsModelFromTurnContext()
        try await codexAdapterThreadsModelAndSurvivesIncrementalResume()
        try pricingMergeSeedsNewModelsWithoutResurrectingDeleted()
        try toolKindReportsCacheCreationOnlyForWritingTools()
        try updateServiceComparesVersionsNumerically()
        try updateServiceParsesGitHubRelease()
        try await refreshCursorsMigratesModelColumnOnOldDatabase()
        try openClawParserReadsUsageLine()
        try hermesParserIncludesReasoningTokens()
        try await hermesSQLiteAdapterUsesLatestMessageTimestamp()
        try await sqliteAdapterReadsWalModeDatabaseAfterWriterClosed()
        try openCodeParserReadsMessageRow()
        try openCodeParserReadsNestedTokensCacheShape()
        try await persistentRepositoryKeepsHistoricalRecords()
        try pricingPersistsInSQLite()
        try pricingCanBeDeleted()
        try budgetsPersistInSQLite()
        try budgetProgressCanUseTokenOrCostMode()
        try dashboardSnapshotFiltersBySearchAndToolWithStableBaseAggregates()
        print("TokenScopeCoreTestsRunner: 33 checks passed")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message) }
    }

    static func pricingEngineCalculatesInputOutputAndCacheCost() throws {
        let pricing = ModelPricing(tool: .hermes, model: "gpt-5.5", inputPerMillion: 2, outputPerMillion: 10, cachePerMillion: 1)
        let cost = PricingEngine.estimate(inputTokens: 1_000_000, outputTokens: 500_000, cacheTokens: 250_000, pricing: pricing)
        try expect(abs(NSDecimalNumber(decimal: cost).doubleValue - 7.25) < 0.0001, "pricing cost mismatch")
    }

    static func dedupeUsesRequestIdWhenAvailable() throws {
        let key = Dedupe.makeKey(source: .hermes, requestId: "req_123", timestamp: Date(timeIntervalSince1970: 1), model: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 3, rawSource: "raw")
        try expect(key == "Hermes::request::req_123", "request id dedupe mismatch")
    }

    static func dedupeFallbackIsStableForSamePayload() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Dedupe.makeKey(source: .codeX, requestId: nil, timestamp: date, model: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 3, rawSource: "raw")
        let second = Dedupe.makeKey(source: .codeX, requestId: nil, timestamp: date, model: "m", inputTokens: 1, outputTokens: 2, cacheTokens: 3, rawSource: "raw")
        try expect(first == second, "fallback dedupe is not stable")
        try expect(first.hasPrefix("CodeX::fallback::"), "fallback dedupe prefix mismatch")
    }

    static func maskingDoesNotExposeFullAPIKey() throws {
        let masked = Masking.maskAPIKey("sk-test-secret-abcd")
        try expect(masked == "sk--...abcd", "mask format mismatch")
        try expect(!masked.contains("secret"), "mask leaked secret segment")
    }

    static func aggregationFiltersToday() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = calendar.date(byAdding: .day, value: -2, to: now)!
        let records = [
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 10, outputTokens: 20, cacheTokens: 5, estimatedCost: 1, rawSource: "1"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: old, inputTokens: 100, outputTokens: 200, cacheTokens: 50, estimatedCost: 10, rawSource: "2")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .today, now: now, calendar: calendar)
        try expect(usage.totalTokens == 35, "today aggregation total mismatch")
        try expect(NSDecimalNumber(decimal: usage.estimatedCost).doubleValue == 1, "today aggregation cost mismatch")
    }

    static func aggregationFiltersCustomDateRange() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let inRange = calendar.date(byAdding: .day, value: 2, to: start)!
        let end = calendar.date(byAdding: .day, value: 3, to: start)!
        let outOfRange = calendar.date(byAdding: .day, value: 5, to: start)!
        let records = [
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: inRange, inputTokens: 10, outputTokens: 20, cacheTokens: 5, estimatedCost: 1, rawSource: "custom-1"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: outOfRange, inputTokens: 100, outputTokens: 200, cacheTokens: 50, estimatedCost: 10, rawSource: "custom-2")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .all, customRange: CustomDateRange(start: start, end: end), calendar: calendar)
        try expect(usage.totalTokens == 35, "custom range aggregation total mismatch")
        try expect(NSDecimalNumber(decimal: usage.estimatedCost).doubleValue == 1, "custom range aggregation cost mismatch")
    }

    static func aggregationCustomRangeIncludesEndDayButNotNextDay() throws {
        // Locks the custom-range boundary after the per-record→precomputed-bounds optimization:
        // the end day is inclusive through 23:59:59 and the next day is excluded.
        let calendar = Calendar(identifier: .gregorian)
        let startOfDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let earlyOnDay = startOfDay.addingTimeInterval(60 * 60)        // 01:00 same day → in
        let lateOnDay = startOfDay.addingTimeInterval(23 * 60 * 60)    // 23:00 same day → in
        let nextDay = startOfDay.addingTimeInterval(25 * 60 * 60)      // 01:00 next day → out
        let records = [
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: earlyOnDay, inputTokens: 10, outputTokens: 0, cacheTokens: 0, estimatedCost: 0, rawSource: "1"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: lateOnDay, inputTokens: 20, outputTokens: 0, cacheTokens: 0, estimatedCost: 0, rawSource: "2"),
            UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: nextDay, inputTokens: 100, outputTokens: 0, cacheTokens: 0, estimatedCost: 0, rawSource: "3")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .all, customRange: CustomDateRange(start: startOfDay, end: startOfDay), calendar: calendar)
        try expect(usage.totalTokens == 30, "custom range boundary mismatch (expected same-day 10+20, next day excluded)")
    }

    static func aggregationTracksRequestCountAndCacheCreation() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            UsageRecord(source: .claudeCode, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 10, outputTokens: 5, cacheTokens: 100, cacheCreationTokens: 30, estimatedCost: 0, rawSource: "1"),
            UsageRecord(source: .claudeCode, accountId: "a", apiKeyHash: "k", model: "m", timestamp: now, inputTokens: 20, outputTokens: 8, cacheTokens: 50, cacheCreationTokens: 20, estimatedCost: 0, rawSource: "2")
        ]
        let usage = AggregationEngine.aggregate(records: records, range: .today, now: now)
        try expect(usage.requestCount == 2, "request count should equal number of records")
        try expect(usage.cacheCreationTokens == 50, "cache creation sum mismatch")
        try expect(usage.cacheReadTokens == 100, "cache read (derived) sum mismatch")
    }

    static func budgetAlertLevels() throws {
        try expect(BudgetEngine.alertLevel(progress: 0.5) == .normal, "normal budget mismatch")
        try expect(BudgetEngine.alertLevel(progress: 0.8) == .warning, "warning budget mismatch")
        try expect(BudgetEngine.alertLevel(progress: 1.0) == .exceeded, "exceeded budget mismatch")
    }

    static func exportRedactsIdentifiersByDefault() throws {
        let record = UsageRecord(source: .claudeCode, accountId: "account", apiKeyHash: "sk-...abcd", model: "claude", timestamp: Date(timeIntervalSince1970: 0), inputTokens: 1, outputTokens: 2, cacheTokens: 3, estimatedCost: 0.1, rawSource: "raw")
        let csv = try ExportService.export(records: [record], format: .csv, includeIdentifiers: false)
        try expect(csv.contains("redacted"), "export did not redact identifiers")
        try expect(!csv.contains(",account,"), "export leaked account")
    }

    static func repositoryDeduplicatesRecords() async throws {
        let repository = UsageRepository()
        let first = UsageRecord(source: .openClaw, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 1, outputTokens: 1, cacheTokens: 0, requestId: "same", rawSource: "raw")
        let second = UsageRecord(source: .openClaw, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 2, outputTokens: 2, cacheTokens: 0, requestId: "same", rawSource: "raw")
        await repository.upsert([first, second])
        let all = await repository.all()
        try expect(all.count == 1, "repository did not dedupe")
        try expect(all[0].totalTokens == 4, "repository did not keep latest record")
    }
    static func claudeParserReadsUsageLine() throws {
        let line = """
        {"type":"assistant","uuid":"u1","timestamp":"2026-05-11T19:59:41.206Z","message":{"id":"m1","model":"claude-sonnet-4.5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}
        """
        let record = LocalUsageParser.parseClaudeLine(line, filePath: "/tmp/claude.jsonl", pricing: [])
        try expect(record?.source == .claudeCode, "claude source mismatch")
        try expect(record?.inputTokens == 10, "claude input mismatch")
        try expect(record?.outputTokens == 20, "claude output mismatch")
        try expect(record?.cacheTokens == 7, "claude cache mismatch")
    }

    static func claudeParserDoesNotDoubleCountCacheCreation() throws {
        // `cache_creation_input_tokens` (2170) equals the sum of the `cache_creation.ephemeral_*`
        // breakdown, so cache must be 2170 + cache_read (16218) = 18388 — not 2170 + 16218 + 2170.
        let line = """
        {"type":"assistant","uuid":"u2","timestamp":"2026-05-11T19:59:41.206Z","message":{"id":"m2","model":"claude-sonnet-4.5","usage":{"input_tokens":2,"output_tokens":10,"cache_creation_input_tokens":2170,"cache_read_input_tokens":16218,"cache_creation":{"ephemeral_5m_input_tokens":2170,"ephemeral_1h_input_tokens":0}}}}
        """
        let record = LocalUsageParser.parseClaudeLine(line, filePath: "/tmp/claude.jsonl", pricing: [])
        try expect(record?.cacheTokens == 18388, "claude cache double-counted cache_creation breakdown")
        try expect(record?.totalTokens == 2 + 10 + 18388, "claude total mismatch after cache fix")
        try expect(record?.cacheCreationTokens == 2170, "claude cache creation portion mismatch")
        try expect(record?.cacheReadTokens == 16218, "claude cache read portion mismatch")
    }

    static func codexParserReadsTokenCountLine() throws {
        // Codex: total_tokens == input_tokens + output_tokens, with cached_input_tokens a subset
        // of input and reasoning_output_tokens a subset of output. The disjoint buckets are
        // input = 17 - 7 = 10, output = 3 (already includes reasoning), cache = 7, total = 20.
        let line = """
        {"timestamp":"2026-04-18T15:41:12.238Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3,"reasoning_output_tokens":2,"total_tokens":20}}}}
        """
        let record = LocalUsageParser.parseCodexLine(line, filePath: "/tmp/codex.jsonl", pricing: [])
        try expect(record?.source == .codeX, "codex source mismatch")
        try expect(record?.inputTokens == 10, "codex input mismatch (cached must be split out of input)")
        try expect(record?.outputTokens == 3, "codex output mismatch (reasoning must not be added on top)")
        try expect(record?.cacheTokens == 7, "codex cache mismatch")
        try expect(record?.totalTokens == 20, "codex total must equal input_tokens + output_tokens")
        try expect(record?.cacheCreationTokens == 0, "codex cached tokens are reads, not creation")
        try expect(record?.cacheReadTokens == 7, "codex cache read mismatch")
    }

    static func codexParserExtractsModelFromTurnContext() throws {
        // Codex usage (`token_count`) events name no model; the active model is announced in a
        // preceding `turn_context` line. The adapter tracks it and threads it into the record —
        // previously every Codex record was the hardcoded "codex".
        let turnContext = """
        {"timestamp":"2026-06-13T16:45:32.008Z","type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.5","effort":"high"}}
        """
        let tokenLine = """
        {"timestamp":"2026-06-13T16:45:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3,"total_tokens":20}}}}
        """
        try expect(LocalUsageParser.codexModel(fromLine: turnContext) == "gpt-5.5", "model not extracted from turn_context")
        try expect(LocalUsageParser.codexModel(fromLine: tokenLine) == nil, "token_count line must not be treated as turn_context")
        try expect(LocalUsageParser.parseCodexLine(tokenLine, filePath: "/tmp/codex.jsonl", pricing: [], model: "gpt-5.5")?.model == "gpt-5.5", "threaded model did not land on record")
        try expect(LocalUsageParser.parseCodexLine(tokenLine, filePath: "/tmp/codex.jsonl", pricing: [])?.model == "codex", "missing model must fall back to codex")
    }

    static func codexAdapterThreadsModelAndSurvivesIncrementalResume() async throws {
        // End-to-end through the real .codeX adapter: the model is announced once in a turn_context
        // line and must land on the token_count records that follow it (the stateful LineContext
        // threading). Critically, an incremental refresh that resumes AFTER the turn_context — but
        // before later token_counts of the same turn are appended — must still stamp the real model
        // (recovered from the persisted cursor), not regress to "codex".
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

        // First incremental pass: turn_context + one token_count.
        try (turnContext + "\n" + tokenA + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        let first = try await adapter.refresh(source: source, pricing: [], cursorStore: repo, fullScan: false)
        try expect(first.count == 1, "codex adapter should read the first token_count")
        try expect(first[0].model == "gpt-5.5", "codex adapter did not thread turn_context model onto the record")

        // Append a later token_count of the same turn (no new turn_context) and resume incrementally.
        try (turnContext + "\n" + tokenA + "\n" + tokenB + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        let second = try await adapter.refresh(source: source, pricing: [], cursorStore: repo, fullScan: false)
        try expect(second.count == 1, "incremental resume should read only the appended token_count")
        try expect(second[0].model == "gpt-5.5", "incremental resume lost the model and fell back to codex")

        // A full scan with no cursor store recovers the model purely from the inline turn_context.
        let full = try await adapter.refresh(source: source, pricing: [], cursorStore: nil, fullScan: true)
        try expect(full.count == 2, "full scan should read both token_counts")
        try expect(full.allSatisfy { $0.model == "gpt-5.5" }, "full scan records should all carry the real model")
    }

    static func pricingMergeSeedsNewModelsWithoutResurrectingDeleted() throws {
        // Fix B: on a parser-version bump only the genuinely-new models are seeded. User-edited rows
        // keep their values, and a default the user deleted (not in the new-models allowlist) is NOT
        // resurrected. Lookups are case-insensitive on the model name.
        let userEdited = ModelPricing(tool: .codeX, model: "GPT-5.1-Codex", inputPerMillion: 99, outputPerMillion: 99, cachePerMillion: 9)
        // Existing table has the user-edited row but is missing the new gpt-5.4 models AND a
        // previously-deleted default (gpt-5-mini).
        let existing = [userEdited]
        let merged = UsageStore.pricingByAddingMissingDefaults(UsageStore.modelsAddedInParserV4, to: existing, from: UsageStore.defaultPricing())
        try expect(merged.contains { $0.tool == .codeX && $0.model == "gpt-5.5" }, "merge did not add new gpt-5.5")
        try expect(merged.contains { $0.tool == .codeX && $0.model == "gpt-5.4" }, "merge did not add new gpt-5.4")
        try expect(merged.contains { $0.tool == .codeX && $0.model == "gpt-5.4-mini" }, "merge did not add new gpt-5.4-mini")
        try expect(merged.first { $0.model == "GPT-5.1-Codex" }?.inputPerMillion == 99, "merge overwrote a user-edited row")
        try expect(!merged.contains { $0.model.lowercased() == "gpt-5.1-codex" && $0.inputPerMillion != 99 }, "merge resurrected the case-variant default over the user edit")
        try expect(!merged.contains { $0.model == "gpt-5-mini" }, "merge resurrected a deleted default not in the allowlist")
        // Idempotent: re-running adds nothing.
        let again = UsageStore.pricingByAddingMissingDefaults(UsageStore.modelsAddedInParserV4, to: merged, from: UsageStore.defaultPricing())
        try expect(again.count == merged.count, "merge is not idempotent")
    }

    static func toolKindReportsCacheCreationOnlyForWritingTools() throws {
        // Codex follows OpenAI accounting (cache reads only, no cache-write tokens), so its cache
        // creation is structurally 0; the dashboard uses this flag to explain that 0. Every other
        // tool can report cache writes.
        try expect(ToolKind.codeX.reportsCacheCreation == false, "Codex must not be marked as reporting cache creation")
        for tool in [ToolKind.claudeCode, .hermes, .openClaw, .openCode] {
            try expect(tool.reportsCacheCreation, "\(tool.rawValue) should report cache creation")
        }
    }

    static func updateServiceComparesVersionsNumerically() throws {
        // Dotted numeric compare: "1.1.10" must beat "1.1.9" (plain string compare would not),
        // a "v" prefix is tolerated, and missing components count as 0.
        try expect(UpdateService.compare("1.1.10", "1.1.9") == .orderedDescending, "1.1.10 should be newer than 1.1.9")
        try expect(UpdateService.compare("1.1.5", "1.1.5") == .orderedSame, "equal versions mismatch")
        try expect(UpdateService.compare("v1.2.0", "1.2") == .orderedSame, "missing trailing component should be 0 and v-prefix tolerated")
        try expect(UpdateService.isUpdateAvailable(latest: "1.1.6", current: "1.1.5"), "1.1.6 should be offered over 1.1.5")
        try expect(!UpdateService.isUpdateAvailable(latest: "1.1.5", current: "1.1.5"), "same version must not offer an update")
        try expect(!UpdateService.isUpdateAvailable(latest: "1.1.5", current: "1.2.0"), "older release must not offer an update")
    }

    static func updateServiceParsesGitHubRelease() throws {
        let json = """
        {"tag_name":"v1.1.6","html_url":"https://github.com/o/r/releases/tag/v1.1.6","body":"notes here",
         "assets":[
           {"name":"TokenScope-1.1.6.dmg","browser_download_url":"https://example.com/TokenScope-1.1.6.dmg"},
           {"name":"TokenScope-1.1.6-macOS.zip","browser_download_url":"https://example.com/TokenScope-1.1.6-macOS.zip"}
         ]}
        """
        let release = UpdateService.parseRelease(Data(json.utf8))
        try expect(release?.tagName == "v1.1.6", "tag mismatch")
        try expect(release?.version == "1.1.6", "version should strip the v prefix")
        try expect(release?.zipURL?.absoluteString == "https://example.com/TokenScope-1.1.6-macOS.zip", "should pick the macOS zip asset, not the dmg")
        try expect(release?.htmlURL != nil, "html url missing")
        try expect(release?.notes == "notes here", "notes missing")
        try expect(UpdateService.parseRelease(Data("not json".utf8)) == nil, "invalid payload should parse to nil")
    }

    static func refreshCursorsMigratesModelColumnOnOldDatabase() async throws {
        // Fix A migration: a pre-existing refresh_cursors table without the `model` column must gain
        // it on open (ALTER TABLE) without error, with pre-migration rows reading back a nil model
        // and new reads/writes of the model working.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-curmig-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        do {
            let db = try SQLiteTestDB(path: url.path)
            try db.exec("""
            CREATE TABLE refresh_cursors (
                source TEXT NOT NULL, raw_source TEXT NOT NULL, position REAL NOT NULL,
                updated_at REAL NOT NULL, PRIMARY KEY (source, raw_source)
            );
            INSERT INTO refresh_cursors (source, raw_source, position, updated_at)
            VALUES ('CodeX', '/tmp/x.jsonl', 10, 0);
            """)
        } // writer closed
        let repo = PersistentUsageRepository(dbURL: url)
        try expect(repo.refreshCursorModel(source: .codeX, rawSource: "/tmp/x.jsonl") == nil, "pre-migration row should have a nil model")
        repo.setRefreshCursor(source: .codeX, rawSource: "/tmp/x.jsonl", position: 20, model: "gpt-5.5")
        try expect(repo.refreshCursorModel(source: .codeX, rawSource: "/tmp/x.jsonl") == "gpt-5.5", "model not persisted after migration")
        try expect(repo.refreshCursor(source: .codeX, rawSource: "/tmp/x.jsonl") == 20, "position not preserved across model write")
    }

    static func openClawParserReadsUsageLine() throws {
        let line = """
        {"type":"message","id":"o1","timestamp":"2026-04-28T12:19:08.945Z","message":{"role":"assistant","provider":"micu","model":"gpt-5.4","usage":{"input":11,"output":22,"cacheRead":3,"cacheWrite":4,"totalTokens":40,"cost":{"total":0.123}}}}
        """
        let record = LocalUsageParser.parseOpenClawLine(line, filePath: "/tmp/openclaw.jsonl", pricing: [])
        try expect(record?.source == .openClaw, "openclaw source mismatch")
        try expect(record?.inputTokens == 11, "openclaw input mismatch")
        try expect(record?.outputTokens == 22, "openclaw output mismatch")
        try expect(record?.cacheTokens == 7, "openclaw cache mismatch")
        try expect(abs(NSDecimalNumber(decimal: record?.estimatedCost ?? 0).doubleValue - 0.123) < 0.0001, "openclaw cost mismatch")
    }

    static func hermesParserIncludesReasoningTokens() throws {
        let record = LocalUsageParser.parseHermesSessionRow(id: "h1", source: "webui", userId: "u1", model: "gpt-5.5", activityAt: 1_777_777_777, input: 10, output: 20, cacheRead: 3, cacheWrite: 4, reasoning: 5, cost: nil, provider: "provider", pricing: [])
        try expect(record?.source == .hermes, "hermes source mismatch")
        try expect(record?.inputTokens == 10, "hermes input mismatch")
        try expect(record?.outputTokens == 25, "hermes reasoning tokens not included in output")
        try expect(record?.cacheTokens == 7, "hermes cache mismatch")
        try expect(record?.totalTokens == 42, "hermes total mismatch")
    }

    static func hermesSQLiteAdapterUsesLatestMessageTimestamp() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-hermes-adapter-test-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let db = try SQLiteTestDB(path: url.path)
        try db.exec("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            user_id TEXT,
            model TEXT,
            started_at REAL NOT NULL,
            ended_at REAL,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            estimated_cost_usd REAL,
            billing_provider TEXT
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL REFERENCES sessions(id),
            role TEXT NOT NULL,
            timestamp REAL NOT NULL,
            token_count INTEGER
        );
        INSERT INTO sessions (id, source, user_id, model, started_at, ended_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, estimated_cost_usd, billing_provider)
        VALUES ('s1', 'webui', 'u1', 'gpt-5.5', 1779374334, NULL, 100, 20, 3, 4, 5, NULL, 'provider');
        INSERT INTO messages (session_id, role, timestamp, token_count)
        VALUES ('s1', 'assistant', 1779493000, NULL);
        """)
        let adapter = HermesSQLiteUsageAdapter()
        let source = UsageSource(tool: .hermes, name: "Hermes Test", accountId: "u1", apiKeyIdentity: "provider", localLogPath: url.path)
        let records = try await adapter.refresh(source: source, pricing: [], cursorStore: nil, fullScan: true)
        try expect(records.count == 1, "hermes sqlite adapter did not read session")
        try expect(records[0].timestamp.timeIntervalSince1970 == 1779493000, "hermes sqlite adapter did not use latest message timestamp")
        try expect(records[0].outputTokens == 25, "hermes sqlite adapter did not include reasoning tokens")
        try expect(records[0].totalTokens == 132, "hermes sqlite adapter total mismatch")
    }

    static func sqliteAdapterReadsWalModeDatabaseAfterWriterClosed() async throws {
        // Reproduces the OpenCode/Hermes under-counting bug: a WAL-mode database whose -wal/-shm
        // sidecars were removed on clean close could not be opened with a plain read-only handle,
        // so the adapter silently returned zero rows. Exercised end-to-end through the adapter.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-hermes-wal-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        do {
            let db = try SQLiteTestDB(path: url.path)
            try db.exec("PRAGMA journal_mode=WAL;")
            try db.exec("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, source TEXT NOT NULL, user_id TEXT, model TEXT,
                started_at REAL NOT NULL, ended_at REAL,
                input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
                cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
                reasoning_tokens INTEGER DEFAULT 0, estimated_cost_usd REAL, billing_provider TEXT
            );
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                role TEXT NOT NULL, timestamp REAL NOT NULL, token_count INTEGER
            );
            INSERT INTO sessions (id, source, user_id, model, started_at, ended_at, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, estimated_cost_usd, billing_provider)
            VALUES ('s1', 'webui', 'u1', 'gpt-5.5', 1779374334, NULL, 100, 20, 3, 4, 0, NULL, 'provider');
            """)
        } // writer closed here → -wal/-shm removed
        let adapter = HermesSQLiteUsageAdapter()
        let source = UsageSource(tool: .hermes, name: "Hermes WAL", accountId: "u1", apiKeyIdentity: "provider", localLogPath: url.path)
        let records = try await adapter.refresh(source: source, pricing: [], cursorStore: nil, fullScan: true)
        try expect(records.count == 1, "hermes adapter dropped a WAL-mode database opened read-only")
        try expect(records[0].totalTokens == 127, "hermes WAL record token mismatch")
    }

    static func openCodeParserReadsMessageRow() throws {
        let data = """
        {"id":"msg_1","providerID":"anthropic","modelID":"claude-sonnet-4","role":"assistant","usage":{"inputTokens":31,"outputTokens":41,"cacheReadTokens":5,"cacheWriteTokens":7,"cost":0.234}}
        """
        let record = LocalUsageParser.parseOpenCodeMessageRow(id: "row_1", sessionId: "ses_1", timeCreated: 1_777_777_777_000, data: data, rawSource: "/tmp/opencode.db:message", pricing: [])
        try expect(record?.source == .openCode, "opencode source mismatch")
        try expect(record?.accountId == "ses_1", "opencode session mismatch")
        try expect(record?.apiKeyHash == "anthropic", "opencode provider mismatch")
        try expect(record?.model == "claude-sonnet-4", "opencode model mismatch")
        try expect(record?.inputTokens == 31, "opencode input mismatch")
        try expect(record?.outputTokens == 41, "opencode output mismatch")
        try expect(record?.cacheTokens == 12, "opencode cache mismatch")
        try expect(record?.cacheCreationTokens == 7, "opencode cache creation (write) mismatch")
        try expect(record?.cacheReadTokens == 5, "opencode cache read mismatch")
        try expect(abs(NSDecimalNumber(decimal: record?.estimatedCost ?? 0).doubleValue - 0.234) < 0.0001, "opencode cost mismatch")
    }

    static func openCodeParserReadsNestedTokensCacheShape() throws {
        let data = """
        {"role":"assistant","modelID":"gpt-5.5","providerID":"xomodel-opencode-gpt","tokens":{"total":9807,"input":299,"output":292,"reasoning":11,"cache":{"write":13,"read":9216}},"time":{"created":1778759081253,"completed":1778759095240},"finish":"stop"}
        """
        let record = LocalUsageParser.parseOpenCodeMessageRow(id: "row_nested", sessionId: "ses_nested", timeCreated: 1_778_759_081_253, data: data, rawSource: "/tmp/opencode.db:message", pricing: [])
        try expect(record?.source == .openCode, "opencode nested source mismatch")
        try expect(record?.apiKeyHash == "xomodel-opencode-gpt", "opencode nested provider mismatch")
        try expect(record?.model == "gpt-5.5", "opencode nested model mismatch")
        try expect(record?.inputTokens == 299, "opencode nested input mismatch")
        try expect(record?.outputTokens == 303, "opencode nested output+reasoning mismatch")
        try expect(record?.cacheTokens == 9229, "opencode nested cache mismatch")
        try expect(record?.totalTokens == 9831, "opencode nested total mismatch")
    }

    static func persistentRepositoryKeepsHistoricalRecords() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-test-\(UUID().uuidString).sqlite")
        let repository = PersistentUsageRepository(dbURL: url)
        let record = UsageRecord(source: .hermes, accountId: "deleted-account", apiKeyHash: "deleted-key", model: "m", timestamp: Date(), inputTokens: 1, outputTokens: 2, cacheTokens: 3, requestId: "persist", rawSource: "test")
        repository.upsert([record])
        let reloaded = PersistentUsageRepository(dbURL: url)
        let all = reloaded.all()
        try expect(all.count == 1, "persistent repository did not reload")
        try expect(all[0].accountId == "deleted-account", "historical account not retained")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    static func pricingPersistsInSQLite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-pricing-test-\(UUID().uuidString).sqlite")
        let repository = PersistentUsageRepository(dbURL: url)
        let item = ModelPricing(tool: .codeX, model: "custom-codex-model", inputPerMillion: 1.25, outputPerMillion: 6.5, cachePerMillion: 0.25)
        repository.upsertPricing(item)
        let reloaded = PersistentUsageRepository(dbURL: url)
        let pricing = reloaded.loadPricing()
        try expect(pricing.count == 1, "pricing was not persisted")
        try expect(pricing[0].tool == .codeX, "pricing tool mismatch")
        try expect(pricing[0].model == "custom-codex-model", "pricing model mismatch")
        try expect(abs(NSDecimalNumber(decimal: pricing[0].outputPerMillion).doubleValue - 6.5) < 0.0001, "pricing value mismatch")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    static func pricingCanBeDeleted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-pricing-delete-test-\(UUID().uuidString).sqlite")
        let keep = ModelPricing(tool: .hermes, model: "keep-model", inputPerMillion: 1, outputPerMillion: 2, cachePerMillion: 0.1)
        let drop = ModelPricing(tool: .codeX, model: "drop-model", inputPerMillion: 3, outputPerMillion: 4, cachePerMillion: 0.2)
        let repository = PersistentUsageRepository(dbURL: url)
        repository.savePricing([keep, drop])

        // Repository-level delete removes only the targeted (tool, model) row and persists.
        repository.deletePricing(drop)
        let reloaded = PersistentUsageRepository(dbURL: url).loadPricing()
        try expect(reloaded.count == 1, "delete should leave exactly one row")
        try expect(reloaded[0].id == keep.id, "delete removed the wrong row")

        // Store-level delete removes the item from the in-memory published list.
        let store = UsageStore(repository: PersistentUsageRepository(dbURL: url))
        store.setPricing(drop)
        try expect(store.pricing.contains { $0.id == drop.id }, "setup: drop should be present before deletion")
        store.deletePricing(drop)
        try expect(!store.pricing.contains { $0.id == drop.id }, "store.deletePricing did not remove the item")
        try expect(store.pricing.contains { $0.id == keep.id }, "store.deletePricing removed an unrelated item")

        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    static func budgetsPersistInSQLite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-budget-test-\(UUID().uuidString).sqlite")
        let repository = PersistentUsageRepository(dbURL: url)
        let budgets = [
            BudgetRule(period: .daily, tokenLimit: 123, costLimit: 4.5),
            BudgetRule(period: .weekly, tokenLimit: 456, costLimit: 78.9),
            BudgetRule(period: .monthly, tokenLimit: 789, costLimit: 123.45)
        ]
        repository.saveBudgets(budgets)
        let reloaded = PersistentUsageRepository(dbURL: url)
        let loaded = UsageStore.orderedBudgets(reloaded.loadBudgets())
        try expect(loaded.count == 3, "budgets were not persisted")
        try expect(loaded[0].period == .daily && loaded[0].tokenLimit == 123, "daily budget mismatch")
        try expect(abs(NSDecimalNumber(decimal: loaded[1].costLimit).doubleValue - 78.9) < 0.0001, "weekly budget cost mismatch")
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    static func dashboardSnapshotFiltersBySearchAndToolWithStableBaseAggregates() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-snapshot-filter-test-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }
        let repository = PersistentUsageRepository(dbURL: url)
        let now = Date()
        repository.upsert([
            UsageRecord(source: .hermes, accountId: "alpha", apiKeyHash: "k1", model: "gpt-5.5", timestamp: now, inputTokens: 10, outputTokens: 20, cacheTokens: 5, estimatedCost: 1, rawSource: "r1"),
            UsageRecord(source: .codeX, accountId: "beta", apiKeyHash: "k2", model: "gpt-5-mini", timestamp: now.addingTimeInterval(-1), inputTokens: 100, outputTokens: 200, cacheTokens: 50, estimatedCost: 2, rawSource: "r2"),
            UsageRecord(source: .hermes, accountId: "alpha", apiKeyHash: "k3", model: "claude", timestamp: now.addingTimeInterval(-2), inputTokens: 1, outputTokens: 2, cacheTokens: 3, estimatedCost: 0.5, rawSource: "r3")
        ])
        let store = UsageStore(repository: repository)

        // Base, filter-independent aggregates cover every record (35 + 350 + 6 = 391).
        try expect(store.dashboardSnapshot.today.totalTokens == 391, "snapshot today base mismatch")
        try expect(store.dashboardSnapshot.all.totalTokens == 391, "snapshot all base mismatch")
        // Default range is today, no filters → selected equals the base.
        try expect(store.dashboardSnapshot.selected.totalTokens == 391, "snapshot selected (no filter) mismatch")
        try expect(store.dashboardSnapshot.recentRecords.count == 3, "snapshot recent count mismatch")

        // Search by account substring → only the two "alpha" hermes rows (35 + 6 = 41).
        // Filter changes rebuild the snapshot off the main thread; tests force it synchronously.
        store.searchText = "alpha"
        store.rebuildDashboardSnapshot()
        try expect(store.dashboardSnapshot.selected.totalTokens == 41, "search-by-account selected mismatch")
        try expect(store.dashboardSnapshot.toolGroups.count == 1, "search-by-account toolGroups should only contain hermes")
        try expect(store.dashboardSnapshot.toolGroups[.hermes]?.totalTokens == 41, "search-by-account hermes group mismatch")
        // Base aggregates must remain correct while filters change.
        try expect(store.dashboardSnapshot.today.totalTokens == 391, "base today changed under search filter")

        // Search by model substring → only the codeX row (350).
        store.searchText = "gpt-5-mini"
        store.rebuildDashboardSnapshot()
        try expect(store.dashboardSnapshot.selected.totalTokens == 350, "search-by-model selected mismatch")
        try expect(store.dashboardSnapshot.toolGroups[.codeX]?.totalTokens == 350, "search-by-model codeX group mismatch")

        // Tool filter (no search) → only codeX (350).
        store.searchText = ""
        store.selectedTool = .codeX
        store.rebuildDashboardSnapshot()
        try expect(store.dashboardSnapshot.selected.totalTokens == 350, "tool-filter selected mismatch")
        try expect(store.dashboardSnapshot.recentRecords.count == 1, "tool-filter recent count mismatch")

        // Clearing filters and widening the range restores the full set.
        store.selectedTool = nil
        store.selectedRange = .all
        store.rebuildDashboardSnapshot()
        try expect(store.dashboardSnapshot.selected.totalTokens == 391, "cleared-filter selected mismatch")
        try expect(store.dashboardSnapshot.recentRecords.count == 3, "cleared-filter recent count mismatch")
        try expect(store.dashboardSnapshot.all.totalTokens == 391, "base all changed across filter changes")
    }

    static func budgetProgressCanUseTokenOrCostMode() throws {
        let usage = AggregatedUsage(inputTokens: 30, outputTokens: 20, cacheTokens: 0, totalTokens: 50, estimatedCost: 80)
        let rule = BudgetRule(period: .daily, tokenLimit: 100, costLimit: 200)
        try expect(abs(BudgetEngine.progress(usage: usage, rule: rule, mode: .tokens) - 0.5) < 0.0001, "token budget progress mismatch")
        try expect(abs(BudgetEngine.progress(usage: usage, rule: rule, mode: .cost) - 0.4) < 0.0001, "cost budget progress mismatch")
    }

}

final class SQLiteTestDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = db.flatMap { sqlite3_errmsg($0).map { String(cString: $0) } } ?? "unknown sqlite open error"
            throw TestFailure(message)
        }
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite exec error"
            if let error { sqlite3_free(error) }
            throw TestFailure(message)
        }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
