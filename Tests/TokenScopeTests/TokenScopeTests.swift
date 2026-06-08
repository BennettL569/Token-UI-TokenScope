import Testing
import Foundation
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

        store.selectedRange = .all
        #expect(store.dashboardSnapshot.selected.totalTokens == 385)
        #expect(store.dashboardSnapshot.recentRecords.count == 2)
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
