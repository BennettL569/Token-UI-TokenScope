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

    @Test func toolKindReportsCacheCreationOnlyForClaudeCode() {
        // Only Claude Code (Anthropic) reports cache creation as a distinct billed category; every
        // other tool's cache-write is absent or left 0 by its provider, so the UI shows N/A there.
        #expect(ToolKind.claudeCode.reportsCacheCreation)
        #expect(ToolKind.codeX.reportsCacheCreation == false)
        #expect(ToolKind.hermes.reportsCacheCreation == false)
        #expect(ToolKind.openClaw.reportsCacheCreation == false)
        #expect(ToolKind.openCode.reportsCacheCreation == false)
        #expect(ToolKind.qoder.reportsCacheCreation == false)
        #expect(ToolKind.qoderCN.reportsCacheCreation == false)
        #expect(ToolKind.zCode.reportsCacheCreation == false)
    }

    @Test func recordShowsCacheCreationOnlyForClaudeOrPositive() {
        // The Usage table renders cache creation as "N/A" instead of a misleading 0 for every tool
        // except Claude Code: those tools emit cache reads with no matching writes, so a 0 means
        // "not reported". Claude's value is always shown, and a genuine non-zero from any tool is too.
        func record(_ tool: ToolKind, cacheCreation: Int) -> UsageRecord {
            UsageRecord(source: tool, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 1, outputTokens: 1, cacheTokens: max(cacheCreation, 10), cacheCreationTokens: cacheCreation, rawSource: "r")
        }
        #expect(record(.claudeCode, cacheCreation: 0).showsCacheCreation)
        #expect(record(.claudeCode, cacheCreation: 5).showsCacheCreation)
        for tool in [ToolKind.codeX, .hermes, .openClaw, .openCode, .qoder, .qoderCN, .zCode] {
            #expect(record(tool, cacheCreation: 0).showsCacheCreation == false)
            #expect(record(tool, cacheCreation: 7).showsCacheCreation)
        }
    }

    @Test func zcodeParserReadsModelIoLine() {
        // response.usage.inputTokens already includes cache, so it is split out (8606-8064=542);
        // the model name is the real GLM-5.2.
        let line = """
        {"type":"model_io","requestId":"req-1","attempt":1,"sessionId":"sess-1","completedAt":"2026-06-21T18:38:46.993Z","model":{"modelId":"GLM-5.2","providerId":"builtin:bigmodel"},"response":{"modelId":"GLM-5.2","usage":{"inputTokens":8606,"outputTokens":95,"totalTokens":8701,"cacheReadTokens":8064,"cacheWriteTokens":0}}}
        """
        let record = LocalUsageParser.parseZCodeLine(line, filePath: "/tmp/zcode/model-io-x.jsonl", pricing: [])
        #expect(record?.source == .zCode)
        #expect(record?.model == "GLM-5.2")
        #expect(record?.apiKeyHash == "builtin:bigmodel")
        #expect(record?.inputTokens == 542)
        #expect(record?.outputTokens == 95)
        #expect(record?.cacheTokens == 8064)
        #expect(record?.totalTokens == 8701)
        #expect(LocalUsageParser.parseZCodeLine("{\"type\":\"other\"}", filePath: "x", pricing: []) == nil)
    }

    @Test func qoderParserUsesFallbackModelAndRealTokenShape() {
        // Real Qoder shape: model_info is empty, so the model comes from the adapter's fallback
        // (chat_record.modelConfig.key). cached_tokens is a subset of prompt_tokens (40502-36323).
        let tokenInfo = """
        {"prompt_tokens":40502,"completion_tokens":328,"cached_tokens":36323,"max_input_tokens":0}
        """
        let record = LocalUsageParser.parseQoderMessageRow(id: "a1", sessionId: "s1", tokenInfo: tokenInfo, modelInfo: "", gmtCreate: 1_777_000_000_000, fallbackModel: "qmodel_latest", rawSource: "/tmp/qoder.db:chat_message", pricing: [])
        #expect(record?.model == "qmodel_latest")
        #expect(record?.inputTokens == 4179)
        #expect(record?.outputTokens == 328)
        #expect(record?.cacheTokens == 36323)
        #expect(record?.cacheReadTokens == 36323)
        #expect(record?.cacheCreationTokens == 0)
        #expect(record?.totalTokens == 40830)
        // model_info, when present, still wins over the fallback.
        let withInfo = LocalUsageParser.parseQoderMessageRow(id: "a2", sessionId: "s1", tokenInfo: tokenInfo, modelInfo: "{\"model\":\"claude-x\"}", gmtCreate: 1_777_000_000_000, fallbackModel: "qmodel_latest", rawSource: "/tmp/qoder.db:chat_message", pricing: [])
        #expect(withInfo?.model == "claude-x")
        // Qoder's own model_info shape {"model_key":...} is recognized directly (seen in real data).
        let mk = LocalUsageParser.parseQoderMessageRow(id: "a3", sessionId: "s1", tokenInfo: tokenInfo, modelInfo: "{\"model_key\":\"qmodel_x\"}", gmtCreate: 1_777_000_000_000, rawSource: "/tmp/qoder.db:chat_message", pricing: [])
        #expect(mk?.model == "qmodel_x")
        // A supplied alias→friendly-name map turns the alias into the human-readable model name.
        let mapped = LocalUsageParser.parseQoderMessageRow(id: "a4", sessionId: "s1", tokenInfo: tokenInfo, modelInfo: "", gmtCreate: 1_777_000_000_000, fallbackModel: "qmodel_latest", modelAliases: ["qmodel_latest": "Qwen3.7-Max"], rawSource: "/tmp/qoder.db:chat_message", pricing: [])
        #expect(mapped?.model == "Qwen3.7-Max")
    }

    @Test func qoderModelCatalogExtractsAliases() {
        let sample = #"x,"modelSelector.item.qmodel_latest":"Qwen3.7-Max","modelSelector.item.qmodel_latest.description":"desc","modelSelector.item.gm51model":"GLM-5.2",y"#
        let map = QoderModelCatalog.aliases(in: sample)
        #expect(map["qmodel_latest"] == "Qwen3.7-Max")
        #expect(map["gm51model"] == "GLM-5.2")
        #expect(map["qmodel_latest.description"] == nil)
    }

    @Test func qoderCNParserTagsRecordsAsQoderCN() {
        // The CN build reuses the same parser/schema; passing tool: .qoderCN must tag the record as
        // .qoderCN (distinct dedupe namespace) and use the CN fallback hash.
        let tokenInfo = """
        {"input_tokens":120,"output_tokens":48,"cached_input_tokens":30}
        """
        let record = LocalUsageParser.parseQoderMessageRow(tool: .qoderCN, id: "cn1", sessionId: "s1", tokenInfo: tokenInfo, modelInfo: nil, gmtCreate: 1_777_000_000_000, rawSource: "/tmp/qodercn.db:chat_message", pricing: [])
        #expect(record?.source == .qoderCN)
        #expect(record?.apiKeyHash == "local-qodercn")
        #expect(record?.model == "qoder")
        #expect(record?.inputTokens == 90)
        #expect(record?.cacheTokens == 30)
        #expect(record?.totalTokens == 168)
    }

    @Test func qoderCNAdapterIsRegistered() {
        let adapter = AdapterRegistry.defaultAdapters()[.qoderCN]
        #expect(adapter != nil)
        #expect(adapter?.tool == .qoderCN)
    }

    @Test func openCodeParserSubtractsOpenAICachedInputFromInput() {
        // OpenAI-style payload routed through OpenCode: cached_input_tokens is a SUBSET of input, so
        // it must be subtracted (120-30=90) and not double-counted in both input and cache.
        let data = """
        {"role":"assistant","modelID":"gpt-5.1-codex","providerID":"openai","usage":{"input_tokens":120,"output_tokens":48,"cached_input_tokens":30,"reasoning_output_tokens":8}}
        """
        let record = LocalUsageParser.parseOpenCodeMessageRow(id: "row_oa", sessionId: "ses_oa", timeCreated: 1_777_000_000_000, data: data, rawSource: "/tmp/opencode.db:message", pricing: [])
        #expect(record?.source == .openCode)
        #expect(record?.model == "gpt-5.1-codex")
        #expect(record?.apiKeyHash == "openai")
        #expect(record?.inputTokens == 90)
        #expect(record?.outputTokens == 56)
        #expect(record?.cacheTokens == 30)
        #expect(record?.cacheReadTokens == 30)
        #expect(record?.totalTokens == 176)
    }

    @Test func qoderParserReadsMessageRow() {
        // Flat OpenAI-style token_info + JSON model_info: cached_input_tokens is a SUBSET of input
        // (subtracted: 120-30=90), reasoning folds into output. Total must not double-count cache.
        let tokenInfo = """
        {"input_tokens":120,"output_tokens":48,"cached_input_tokens":30,"reasoning_output_tokens":8}
        """
        let modelInfo = """
        {"model":"claude-sonnet-4","provider":"anthropic"}
        """
        let record = LocalUsageParser.parseQoderMessageRow(id: "m1", sessionId: "s1", tokenInfo: tokenInfo, modelInfo: modelInfo, gmtCreate: 1_777_000_000_000, rawSource: "/tmp/qoder.db:chat_message", pricing: [])
        #expect(record?.source == .qoder)
        #expect(record?.accountId == "s1")
        #expect(record?.apiKeyHash == "anthropic")
        #expect(record?.model == "claude-sonnet-4")
        #expect(record?.inputTokens == 90)
        #expect(record?.outputTokens == 56)
        #expect(record?.cacheTokens == 30)
        #expect(record?.cacheCreationTokens == 0)
        #expect(record?.cacheReadTokens == 30)
        #expect(record?.totalTokens == 176)
    }

    @Test func qoderParserReadsFlatUsageWithCostObjectAndQuotedModel() {
        // A flat token_info that also carries a nested cost breakdown must NOT be dropped (the cost
        // object must not shadow the flat token counts); cache.read/write are disjoint from input;
        // model_info is a JSON-encoded (quoted) scalar string that must be unquoted.
        let tokenInfo = """
        {"input_tokens":100,"output_tokens":50,"cache":{"read":30,"write":10},"cost":{"total":0.5}}
        """
        let record = LocalUsageParser.parseQoderMessageRow(id: "m3", sessionId: "s3", tokenInfo: tokenInfo, modelInfo: "\"qwen-max\"", gmtCreate: 1_777_000_002_000, rawSource: "/tmp/qoder.db:chat_message", pricing: [])
        #expect(record?.source == .qoder)
        #expect(record?.model == "qwen-max")
        #expect(record?.apiKeyHash == "local-qoder")
        #expect(record?.inputTokens == 100)
        #expect(record?.outputTokens == 50)
        #expect(record?.cacheTokens == 40)
        #expect(record?.cacheCreationTokens == 10)
        #expect(record?.cacheReadTokens == 30)
        #expect(record?.totalTokens == 190)
        #expect(abs(NSDecimalNumber(decimal: record?.estimatedCost ?? 0).doubleValue - 0.5) < 0.0001)
    }

    @Test func qoderParserReadsNestedUsageAndBareModel() {
        // Usage nested under "usage", prompt/completion naming, nested cache read/write, and a bare
        // (non-JSON) model string in model_info.
        let tokenInfo = """
        {"usage":{"prompt_tokens":200,"completion_tokens":90,"cache":{"read":50,"write":12}}}
        """
        let record = LocalUsageParser.parseQoderMessageRow(id: "m2", sessionId: "s2", tokenInfo: tokenInfo, modelInfo: "qwen3-coder", gmtCreate: 1_777_000_001, rawSource: "/tmp/qoder.db:chat_message", pricing: [])
        #expect(record?.source == .qoder)
        #expect(record?.apiKeyHash == "local-qoder")
        #expect(record?.model == "qwen3-coder")
        #expect(record?.inputTokens == 200)
        #expect(record?.outputTokens == 90)
        #expect(record?.cacheTokens == 62)
        #expect(record?.cacheCreationTokens == 12)
        #expect(record?.cacheReadTokens == 50)
        #expect(record?.totalTokens == 352)
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
        // Create a WAL-mode database, write rows, then close it. A plain SQLITE_OPEN_READONLY open
        // of a WAL database without its -wal/-shm sidecars fails with SQLITE_CANTOPEN; the robust
        // helper must still return a usable handle.
        var writer: OpaquePointer?
        #expect(sqlite3_open(url.path, &writer) == SQLITE_OK)
        sqlite3_exec(writer, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(writer, "CREATE TABLE t (id INTEGER)", nil, nil, nil)
        sqlite3_exec(writer, "INSERT INTO t (id) VALUES (1),(2),(3)", nil, nil, nil)
        sqlite3_close(writer)
        // macOS's SQLite keeps the sidecars after a clean close, but the tools that write these
        // databases (Qoder, OpenCode) ship their own SQLite, which removes them. Remove them so
        // the read really meets a WAL database without sidecars.
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")

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

    @Test func refreshIntervalProvidesOrderedCadences() {
        // Nine auto-refresh cadences, declared 1h → real-time so the settings picker lists them in
        // that order. rawValues are stable preference keys (persisted to UserDefaults) and must
        // round-trip; real-time is the smallest (most frequent) positive cadence.
        #expect(RefreshInterval.allCases.count == 9)
        #expect(RefreshInterval.allCases.first == .oneHour)
        #expect(RefreshInterval.allCases.last == .realtime)
        #expect(RefreshInterval.oneHour.seconds == 3600)
        #expect(RefreshInterval.oneMinute.seconds == 60)
        #expect(RefreshInterval.fiveSeconds.seconds == 5)
        #expect(RefreshInterval.realtime.seconds > 0)
        #expect(RefreshInterval.allCases.map(\.seconds).min() == RefreshInterval.realtime.seconds)
        #expect(RefreshInterval(rawValue: "30m") == .thirtyMinutes)
        #expect(RefreshInterval.realtime.displayName(.english) == "Real-time")
        #expect(RefreshInterval.realtime.displayName(.chinese) == "实时刷新")
    }

    @Test func clearLocalDataNoOpsWhileRefreshing() async throws {
        // The reentrancy gate (added when auto-refresh started calling refreshAll on a timer) must
        // stop clearLocalData from running while a refresh is in flight — otherwise a concurrent
        // refresh could re-upsert rows into the just-cleared store. With the gate held it is a
        // no-op; once released it clears.
        let dir = try makeTempDirectory("clearguard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = PersistentUsageRepository(dbURL: dir.appendingPathComponent("usage.sqlite"))
        repo.upsert([UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 1, outputTokens: 1, cacheTokens: 0, requestId: "guard-1", rawSource: "r")])
        let store = UsageStore(repository: repo, widgetSummaryURL: nil)
        #expect(store.records.count == 1)
        store.isRefreshing = true
        await store.clearLocalData()
        #expect(store.records.count == 1)
        store.isRefreshing = false
        await store.clearLocalData()
        #expect(store.records.isEmpty)
    }

    // MARK: - Rebuild keeps history; safety snapshots

    /// A fresh directory for one test; the test removes it.
    private func makeTempDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tokenscope-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func claudeUsageLine(messageId: String, input: Int) -> String {
        #"{"type":"assistant","uuid":"u-\#(messageId)","timestamp":"2026-05-11T19:59:41.206Z","message":{"id":"\#(messageId)","model":"claude-sonnet-4.5","usage":{"input_tokens":\#(input),"output_tokens":20}}}"#
    }

    /// A store that reads Claude logs from `<directory>/logs/*.jsonl`, with its database in `directory`.
    private func makeClaudeStore(in directory: URL) throws -> (store: UsageStore, repo: PersistentUsageRepository, logs: URL) {
        let logs = directory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let repo = PersistentUsageRepository(dbURL: directory.appendingPathComponent("usage.sqlite"))
        let adapter = LocalJSONLUsageAdapter(tool: .claudeCode, displayName: "Claude Test", defaultGlobPatterns: [logs.path + "/*.jsonl"], parser: LocalUsageParser.parseClaudeLine)
        let store = UsageStore(repository: repo, registry: AdapterRegistry(adapters: [.claudeCode: adapter]), widgetSummaryURL: nil)
        return (store, repo, logs)
    }

    private func staleClaudeRecord(requestId: String, rawSource: String) -> UsageRecord {
        UsageRecord(source: .claudeCode, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(timeIntervalSince1970: 1_780_000_000), inputTokens: 1, outputTokens: 1, cacheTokens: 0, requestId: requestId, rawSource: rawSource)
    }

    @Test func rebuildKeepsRecordsWhoseLogsAreGone() async throws {
        // Claude Code deletes transcripts after 30 days, so for older usage the database is the
        // only copy. A full rebuild must re-read what still exists without dropping the rest, and
        // must snapshot the database before it starts.
        let dir = try makeTempDirectory("rebuild-keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, repo, logs) = try makeClaudeStore(in: dir)
        let gone = logs.appendingPathComponent("gone.jsonl")
        try (claudeUsageLine(messageId: "msg-gone", input: 10) + "\n").write(to: gone, atomically: true, encoding: .utf8)
        try (claudeUsageLine(messageId: "msg-kept", input: 20) + "\n").write(to: logs.appendingPathComponent("kept.jsonl"), atomically: true, encoding: .utf8)
        await store.refreshAll()
        #expect(store.records.count == 2)

        try FileManager.default.removeItem(at: gone)
        await store.rebuildAllData()
        #expect(Set(store.records.compactMap(\.requestId)) == ["msg-gone", "msg-kept"])
        #expect(SafetyBackups.list(for: repo).count == 1)
    }

    @Test func rebuildPrunesOnlyStaleRecordsFromRereadLogs() async throws {
        // A record the current parser no longer produces from a log that still exists is a
        // leftover of an older parse and is pruned; a record whose log is gone is kept.
        let dir = try makeTempDirectory("rebuild-prune")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, repo, logs) = try makeClaudeStore(in: dir)
        let log = logs.appendingPathComponent("session.jsonl")
        try (claudeUsageLine(messageId: "msg-live", input: 10) + "\n").write(to: log, atomically: true, encoding: .utf8)
        await store.refreshAll()
        repo.upsert([
            staleClaudeRecord(requestId: "old-parse-key", rawSource: log.path),
            staleClaudeRecord(requestId: "orphan", rawSource: logs.appendingPathComponent("deleted.jsonl").path)
        ])
        await store.rebuildAllData()
        #expect(Set(store.records.compactMap(\.requestId)) == ["msg-live", "orphan"])
    }

    @Test func rebuildKeepsRecordsFromRewrittenLogs() async throws {
        // A log shorter than when it was last synced was rewritten rather than appended to; it no
        // longer holds its whole history, so nothing derived from it may be pruned.
        let dir = try makeTempDirectory("rebuild-shrunk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, repo, logs) = try makeClaudeStore(in: dir)
        let log = logs.appendingPathComponent("session.jsonl")
        try (claudeUsageLine(messageId: "msg-live", input: 10) + "\n").write(to: log, atomically: true, encoding: .utf8)
        await store.refreshAll()
        repo.upsert([staleClaudeRecord(requestId: "old-parse-key", rawSource: log.path)])
        repo.setRefreshCursor(source: .claudeCode, rawSource: log.path, position: 1_000_000)
        await store.rebuildAllData()
        #expect(Set(store.records.compactMap(\.requestId)) == ["msg-live", "old-parse-key"])
    }

    @Test func rebuildPruningRequiresAFullReadAndALandedUpsert() {
        let file = "/logs/a.jsonl"
        let live = staleClaudeRecord(requestId: "live", rawSource: file)
        let stale = staleClaudeRecord(requestId: "stale", rawSource: file)
        let produced: [ToolKind: Set<String>] = [.claudeCode: [live.dedupeKey]]
        let fullRead: [ToolKind: [String: Int64]] = [.claudeCode: [file: 100]]
        // A fully read, unshrunk log prunes its stale record…
        #expect(RebuildPruning.staleKeys(stored: [live, stale], producedKeys: produced, fullyReadFiles: fullRead, previousCursorPositions: [:]) == [stale.dedupeKey])
        // …but not for a source that reports no fully read files (SQLite),
        #expect(RebuildPruning.staleKeys(stored: [live, stale], producedKeys: produced, fullyReadFiles: [:], previousCursorPositions: [:]).isEmpty)
        // nor when the pass's records did not land in the store,
        #expect(RebuildPruning.staleKeys(stored: [stale], producedKeys: produced, fullyReadFiles: fullRead, previousCursorPositions: [:]).isEmpty)
        // nor for a log that shrank since the last sync,
        #expect(RebuildPruning.staleKeys(stored: [live, stale], producedKeys: produced, fullyReadFiles: fullRead, previousCursorPositions: [RefreshCursorKey(tool: .claudeCode, rawSource: file): 200]).isEmpty)
        // nor another tool's records.
        let otherTool = UsageRecord(source: .openClaw, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 1, outputTokens: 1, cacheTokens: 0, requestId: "other", rawSource: file)
        #expect(RebuildPruning.staleKeys(stored: [live, otherTool], producedKeys: produced, fullyReadFiles: fullRead, previousCursorPositions: [:]).isEmpty)
    }

    @Test func jsonlAdapterReportsOnlyFullyReadFiles() async throws {
        let dir = try makeTempDirectory("fullread")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jsonl")
        try (claudeUsageLine(messageId: "m1", input: 10) + "\n").write(to: file, atomically: true, encoding: .utf8)
        let adapter = LocalJSONLUsageAdapter(tool: .claudeCode, displayName: "Claude Test", defaultGlobPatterns: [dir.path + "/*.jsonl"], parser: LocalUsageParser.parseClaudeLine)
        let source = UsageSource(tool: .claudeCode, name: "t", accountId: "a", apiKeyIdentity: "i")
        let repo = PersistentUsageRepository(dbURL: dir.appendingPathComponent("usage.sqlite"))
        let full = try await adapter.scan(source: source, pricing: [], cursorStore: repo, fullScan: true)
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? -1
        #expect(full.fullyReadFiles == [file.path: size])

        // An incremental pass resumes mid-file, so it has not seen the whole file.
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((claudeUsageLine(messageId: "m2", input: 5) + "\n").utf8))
        try handle.close()
        let incremental = try await adapter.scan(source: source, pricing: [], cursorStore: repo, fullScan: false)
        #expect(incremental.records.map(\.requestId) == ["m2"])
        #expect(incremental.fullyReadFiles.isEmpty)
    }

    @Test func jsonlAdapterReadsPastInvalidUTF8() async throws {
        // A line that isn't valid UTF-8 used to end the whole file read, silently dropping every
        // record after it — and a full rebuild could then prune those records as stale.
        let dir = try makeTempDirectory("bad-utf8")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jsonl")
        var data = Data((claudeUsageLine(messageId: "before", input: 1) + "\n").utf8)
        data.append(contentsOf: [0x7B, 0xFF, 0xFE, 0x7D, 0x0A])
        data.append(Data((claudeUsageLine(messageId: "after", input: 2) + "\n").utf8))
        try data.write(to: file)
        let adapter = LocalJSONLUsageAdapter(tool: .claudeCode, displayName: "Claude Test", defaultGlobPatterns: [dir.path + "/*.jsonl"], parser: LocalUsageParser.parseClaudeLine)
        let result = try await adapter.scan(source: UsageSource(tool: .claudeCode, name: "t", accountId: "a", apiKeyIdentity: "i"), pricing: [], cursorStore: nil, fullScan: true)
        #expect(result.records.compactMap(\.requestId) == ["before", "after"])
        #expect(result.fullyReadFiles[file.path] == Int64(data.count))
    }

    @Test func clearLocalDataKeepsASafetySnapshot() async throws {
        let dir = try makeTempDirectory("clear-snapshot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = PersistentUsageRepository(dbURL: dir.appendingPathComponent("usage.sqlite"))
        repo.upsert([UsageRecord(source: .hermes, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(), inputTokens: 1, outputTokens: 1, cacheTokens: 0, requestId: "keep-me", rawSource: "r")])
        let store = UsageStore(repository: repo, widgetSummaryURL: nil)
        await store.clearLocalData()
        #expect(store.records.isEmpty)
        let snapshots = SafetyBackups.list(for: repo)
        #expect(snapshots.count == 1)
        #expect(snapshots.first.map { PersistentUsageRepository(dbURL: $0).all().map(\.requestId) } == ["keep-me"])
    }

    @Test func safetyBackupsKeepOnlyTheNewest() throws {
        let dir = try makeTempDirectory("snapshot-rotation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = PersistentUsageRepository(dbURL: dir.appendingPathComponent("usage.sqlite"))
        let other = PersistentUsageRepository(dbURL: dir.appendingPathComponent("usage-2.sqlite"))
        try SafetyBackups.create(of: other, reason: "other")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var created: [URL] = []
        for day in 0..<(SafetyBackups.keep + 2) {
            created.append(try SafetyBackups.create(of: repo, reason: "test", now: start.addingTimeInterval(Double(day) * 86_400)))
        }
        #expect(SafetyBackups.list(for: repo) == Array(created.reversed().prefix(SafetyBackups.keep)))
        #expect(!FileManager.default.fileExists(atPath: created[0].path))
        #expect(SafetyBackups.list(for: other).count == 1)
    }

    // MARK: - Full backup & restore

    /// Records that exercise every field: fractional timestamps, a Decimal cost, cache creation,
    /// and a nil request id (fallback dedupe key).
    private func backupSampleRecords() -> [UsageRecord] {
        [
            UsageRecord(source: .claudeCode, accountId: "acct", apiKeyHash: "key", model: "claude-opus-4-7", timestamp: Date(timeIntervalSince1970: 1_779_949_788.924), inputTokens: 70_082, outputTokens: 743, cacheTokens: 512, cacheCreationTokens: 200, estimatedCost: Decimal(string: "0.221391")!, requestId: "msg_01", rawSource: "/Users/me/.claude/projects/p/s.jsonl"),
            UsageRecord(source: .codeX, accountId: "Codex Local", apiKeyHash: "local-codex", model: "gpt-5.5", timestamp: Date(timeIntervalSince1970: 1_780_000_123.456789), inputTokens: 1, outputTokens: 2, cacheTokens: 3, estimatedCost: Decimal(string: "0.000000123")!, requestId: nil, rawSource: "/Users/me/.codex/sessions/r.jsonl"),
            UsageRecord(source: .hermes, accountId: "u", apiKeyHash: "p", model: "m", timestamp: Date(timeIntervalSince1970: 1_700_000_000), inputTokens: 5, outputTokens: 0, cacheTokens: 0, estimatedCost: 12.5, requestId: "", rawSource: "~/.hermes/state.db:sessions")
        ]
    }

    @Test func backupRoundTripsEveryFieldExactly() throws {
        let dir = try makeTempDirectory("backup-roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = PersistentUsageRepository(dbURL: dir.appendingPathComponent("source.sqlite"))
        source.upsert(backupSampleRecords())
        source.savePricing([ModelPricing(tool: .codeX, model: "gpt-5.5", inputPerMillion: Decimal(string: "1.25")!, outputPerMillion: 10, cachePerMillion: Decimal(string: "0.125")!)])
        source.saveBudgets([BudgetRule(period: .daily, tokenLimit: 123_456, costLimit: Decimal(string: "7.89")!)])
        let exportedAt = Date(timeIntervalSince1970: 1_790_000_000)
        let backup = try source.exportBackup(exportedAt: exportedAt)
        let file = dir.appendingPathComponent("backup.json")
        try BackupService.write(backup, to: file)
        let reread = try BackupService.read(from: file)
        #expect(reread == backup)

        let restored = PersistentUsageRepository(dbURL: dir.appendingPathComponent("restored.sqlite"))
        let inserted = try restored.importBackupRecords(reread.records)
        #expect(inserted == 3)
        try restored.restoreSettings(pricing: reread.pricing, budgets: reread.budgets)
        let roundTripped = try restored.exportBackup(exportedAt: exportedAt)
        #expect(roundTripped == backup)
        #expect(Set(restored.all()) == Set(source.all()))
    }

    @Test func backupImportNeverChangesExistingRecords() throws {
        let dir = try makeTempDirectory("backup-merge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = PersistentUsageRepository(dbURL: dir.appendingPathComponent("usage.sqlite"))
        let local = UsageRecord(source: .claudeCode, accountId: "a", apiKeyHash: "k", model: "m", timestamp: Date(timeIntervalSince1970: 1_780_000_000), inputTokens: 100, outputTokens: 1, cacheTokens: 0, requestId: "shared", rawSource: "/logs/a.jsonl")
        repo.upsert([local])
        var importedCopy = UsageBackup.Record(dedupeKey: local.dedupeKey, id: UUID().uuidString, source: "ClaudeCode", accountId: "a", apiKeyHash: "k", model: "m", timestamp: 1_780_000_000, inputTokens: 999, outputTokens: 1, cacheTokens: 0, cacheCreationTokens: 0, estimatedCost: 9, requestId: "shared", rawSource: "/elsewhere/a.jsonl")
        let added = UsageBackup.Record(dedupeKey: "ClaudeCode::request::new", id: UUID().uuidString, source: "ClaudeCode", accountId: "a", apiKeyHash: "k", model: "m", timestamp: 1_780_000_100, inputTokens: 7, outputTokens: 1, cacheTokens: 0, cacheCreationTokens: 0, estimatedCost: 0, requestId: "new", rawSource: "/elsewhere/b.jsonl")
        let backup = UsageBackup(exportedAt: Date(), appVersion: nil, records: [importedCopy, added, added], pricing: [], budgets: [])
        let preview = BackupImportPreview(backup: backup, existingKeys: try repo.allDedupeKeys())
        #expect(preview.newRecordCount == 1)
        #expect(preview.existingRecordCount == 1)
        let inserted = try repo.importBackupRecords(backup.records)
        #expect(inserted == 1)
        let stored = Dictionary(uniqueKeysWithValues: repo.all().map { ($0.dedupeKey, $0) })
        // The local copy keeps its own values; the new record is stored.
        #expect(stored[local.dedupeKey]?.inputTokens == 100)
        #expect(stored["ClaudeCode::request::new"]?.inputTokens == 7)
        importedCopy.inputTokens = 1
        let reinserted = try repo.importBackupRecords([importedCopy, added])
        #expect(reinserted == 0)
    }

    @Test func backupRejectsForeignNewerAndTruncatedFiles() throws {
        func error(decoding json: String) -> BackupError? {
            do { _ = try BackupService.decode(Data(json.utf8)); return nil } catch { return error as? BackupError }
        }
        #expect(error(decoding: "{}") == .notABackup)
        #expect(error(decoding: "[1,2]") == .notABackup)
        #expect(error(decoding: #"{"format":"tokenscope-backup","formatVersion":99}"#) == .newerFormat(99))
        var truncated = try #require(try JSONSerialization.jsonObject(with: BackupService.encode(UsageBackup(exportedAt: Date(), appVersion: nil, records: [], pricing: [], budgets: []))) as? [String: Any])
        truncated["recordCount"] = 5
        let truncatedJSON = try #require(String(data: try JSONSerialization.data(withJSONObject: truncated), encoding: .utf8))
        #expect(error(decoding: truncatedJSON) == .incomplete(expected: 5, found: 0))

        let dir = try makeTempDirectory("backup-foreign")
        defer { try? FileManager.default.removeItem(at: dir) }
        let foreign = dir.appendingPathComponent("other.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(foreign.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE notes (body TEXT)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        #expect(throws: BackupError.notABackup) { try BackupService.read(from: foreign) }
    }

    @Test func backupKeepsRecordsOfUnknownTools() throws {
        // A backup from a newer app may hold a tool this version doesn't know. Its rows are stored
        // (invisible until an update) and carried into later backups instead of being dropped.
        let dir = try makeTempDirectory("backup-unknown-tool")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = PersistentUsageRepository(dbURL: dir.appendingPathComponent("usage.sqlite"))
        let future = UsageBackup.Record(dedupeKey: "FutureTool::request::1", id: UUID().uuidString, source: "FutureTool", accountId: "a", apiKeyHash: "k", model: "m", timestamp: 1_780_000_000, inputTokens: 1, outputTokens: 1, cacheTokens: 0, cacheCreationTokens: 0, estimatedCost: 0, requestId: "1", rawSource: "r")
        let preview = BackupImportPreview(backup: UsageBackup(exportedAt: Date(), appVersion: nil, records: [future], pricing: [], budgets: []), existingKeys: [])
        #expect(preview.unsupportedToolRecordCount == 1)
        let inserted = try repo.importBackupRecords([future])
        #expect(inserted == 1)
        #expect(repo.all().isEmpty)
        let next = try repo.exportBackup()
        #expect(next.records == [future])
    }

    @Test func storeRestoresFromSafetySnapshot() async throws {
        // End to end: clearing writes a snapshot; importing that snapshot brings every record back,
        // and the snapshot file itself is never modified by being read.
        let dir = try makeTempDirectory("backup-restore-snapshot")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = PersistentUsageRepository(dbURL: dir.appendingPathComponent("usage.sqlite"))
        repo.upsert(backupSampleRecords())
        let store = UsageStore(repository: repo, widgetSummaryURL: nil)
        store.selectedRange = .today
        let exported = try await store.exportBackup(to: dir.appendingPathComponent("full.json"))
        #expect(exported == 3)

        let original = Set(repo.all())
        await store.clearLocalData()
        let snapshot = try #require(SafetyBackups.list(for: repo).first)
        let before = try Data(contentsOf: snapshot)
        let preview = try await store.prepareImport(from: snapshot)
        #expect(preview.newRecordCount == 3)
        let added = try await store.applyImport(preview, restoreSettings: false)
        #expect(added == 3)
        #expect(Set(store.records) == original)
        #expect(try Data(contentsOf: snapshot) == before)
    }

    // MARK: - Codex dedupe key

    private let codexTokenLine = #"{"timestamp":"2026-06-06T09:30:23.500Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3,"total_tokens":20}}}}"#

    private var codexEventDate: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: "2026-06-06T09:30:23.500Z")!
    }

    /// A record as the previous parser stored `codexTokenLine` at `path`: the request id embeds the
    /// full path, then the event's timestamp and token counts (input already net of cached).
    private func legacyCodexRecord(path: String) -> UsageRecord {
        UsageRecord(source: .codeX, accountId: "Codex Local", apiKeyHash: "local-codex", model: "gpt-5.5", timestamp: codexEventDate, inputTokens: 10, outputTokens: 3, cacheTokens: 7, requestId: "\(path)#\(codexEventDate.timeIntervalSince1970)#10#3#7", rawSource: path)
    }

    private func sqliteCount(_ path: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM usage_records", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    @Test func codexKeyIgnoresTheSessionFilesDirectory() {
        // Codex moves a session's file to archived_sessions/ when it is archived; the same events
        // must keep the same key there.
        let live = LocalUsageParser.parseCodexLine(codexTokenLine, filePath: "/Users/me/.codex/sessions/2026/06/06/rollout-A.jsonl", pricing: [])
        let archived = LocalUsageParser.parseCodexLine(codexTokenLine, filePath: "/Users/me/.codex/archived_sessions/rollout-A.jsonl", pricing: [])
        #expect(live != nil)
        #expect(live?.dedupeKey == archived?.dedupeKey)
        #expect(live?.requestId?.hasPrefix("rollout-A.jsonl#") == true)
        #expect(live?.rawSource == "/Users/me/.codex/sessions/2026/06/06/rollout-A.jsonl")
    }

    @Test func codexKeyMigrationCollapsesArchivedDuplicates() throws {
        let dir = try makeTempDirectory("codex-migration")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archivedDir = dir.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archivedDir, withIntermediateDirectories: true)
        let archived = archivedDir.appendingPathComponent("rollout-A.jsonl")
        try (codexTokenLine + "\n").write(to: archived, atomically: true, encoding: .utf8)
        let moved = dir.appendingPathComponent("sessions/2026/06/06/rollout-A.jsonl").path
        let deletedSession = dir.appendingPathComponent("sessions/2026/05/01/rollout-B.jsonl").path
        let dbURL = dir.appendingPathComponent("usage.sqlite")

        // A database written by the previous version: the archived session is stored under both of
        // its paths, plus another Codex session and a Claude record.
        let claude = staleClaudeRecord(requestId: "msg_1", rawSource: "/logs/c.jsonl")
        PersistentUsageRepository(dbURL: dbURL).upsert([legacyCodexRecord(path: moved), legacyCodexRecord(path: archived.path), legacyCodexRecord(path: deletedSession), claude])

        let migrated = PersistentUsageRepository(dbURL: dbURL)
        let codex = migrated.all().filter { $0.source == .codeX }
        #expect(codex.count == 2)
        let fresh = try #require(LocalUsageParser.parseCodexLine(codexTokenLine, filePath: archived.path, pricing: []))
        // The migrated key equals what the parser now produces, and the copy whose log exists wins.
        let kept = try #require(codex.first { $0.dedupeKey == fresh.dedupeKey })
        #expect(kept.rawSource == archived.path)
        #expect(codex.contains { $0.requestId?.hasPrefix("rollout-B.jsonl#") == true })
        #expect(migrated.all().contains { $0.dedupeKey == claude.dedupeKey })

        let snapshots = SafetyBackups.list(for: migrated)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.lastPathComponent.contains("before-codex-key-migration") == true)
        #expect(try sqliteCount(try #require(snapshots.first).path) == 4)
        _ = PersistentUsageRepository(dbURL: dbURL)
        #expect(SafetyBackups.list(for: migrated).count == 1)
    }

    @Test func codexKeyMigrationPlanDefersToCurrentRows() {
        let old = CodexDedupeKey.StoredRow(dedupeKey: "CodeX::request::/a/rollout-A.jsonl#1#2#3#4", requestId: "/a/rollout-A.jsonl#1#2#3#4", rawSource: "/a/rollout-A.jsonl")
        let newKey = "CodeX::request::rollout-A.jsonl#1#2#3#4"
        // A row already under the new key wins; the old copy is deleted.
        let plan = CodexDedupeKey.migrationPlan(oldRows: [old], existingKeys: [newKey]) { _ in false }
        #expect(plan.rekey.isEmpty)
        #expect(plan.delete == [old.dedupeKey])
        // A lone old row is simply re-keyed.
        let fresh = CodexDedupeKey.migrationPlan(oldRows: [old], existingKeys: []) { _ in false }
        #expect(fresh.rekey == [CodexDedupeKey.Rekey(oldKey: old.dedupeKey, newKey: newKey, newRequestId: "rollout-A.jsonl#1#2#3#4")])
        #expect(fresh.delete.isEmpty)
        #expect(CodexDedupeKey.migratedRequestId("rollout-A.jsonl#1#2#3#4", rawSource: "/a/rollout-A.jsonl") == nil)
        #expect(CodexDedupeKey.migratedRequestId("x.jsonl#1", rawSource: "x.jsonl") == nil)
    }

    @Test func backupImportRekeysOldCodexRecords() throws {
        // A backup taken before the key change still holds full-path Codex keys; the import must
        // match them to this database's records instead of adding them a second time.
        let path = "/Users/me/.codex/sessions/2026/06/06/rollout-A.jsonl"
        let legacy = legacyCodexRecord(path: path)
        let record = UsageBackup.Record(dedupeKey: legacy.dedupeKey, id: legacy.id.uuidString, source: "CodeX", accountId: legacy.accountId, apiKeyHash: legacy.apiKeyHash, model: legacy.model, timestamp: legacy.timestamp.timeIntervalSince1970, inputTokens: 10, outputTokens: 3, cacheTokens: 7, cacheCreationTokens: 0, estimatedCost: 0, requestId: legacy.requestId, rawSource: path)
        let current = try #require(LocalUsageParser.parseCodexLine(codexTokenLine, filePath: "/elsewhere/archived_sessions/rollout-A.jsonl", pricing: []))
        let preview = BackupImportPreview(backup: UsageBackup(exportedAt: Date(), appVersion: nil, records: [record], pricing: [], budgets: []), existingKeys: [current.dedupeKey])
        #expect(preview.existingRecordCount == 1)
        #expect(preview.newRecordCount == 0)
        #expect(preview.backup.records.first?.dedupeKey == current.dedupeKey)
    }
}
