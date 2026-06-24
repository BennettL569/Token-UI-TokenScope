import SwiftUI
import TokenScopeCore

struct ToolDistributionView: View {
    @Environment(\.appLanguage) private var lang
    let groups: [ToolKind: AggregatedUsage]
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(lang.select("Tool Distribution", "工具分布"))
                    .font(.headline)
                if groups.isEmpty {
                    ContentUnavailableView(lang.select("No tool stats yet", "暂无工具统计"), systemImage: "square.stack.3d.up.slash")
                } else {
                    ForEach(ToolKind.allCases) { tool in
                        let value = groups[tool]?.totalTokens ?? 0
                        let cacheHitRate = groups[tool]?.cacheHitRate ?? 0
                        let requests = groups[tool]?.requestCount ?? 0
                        let cachePercent = Self.percentFormatter.string(from: NSNumber(value: cacheHitRate)) ?? "0%"
                        HStack {
                            Text(tool.rawValue).frame(width: 110, alignment: .leading)
                            ProgressView(value: Double(value), total: Double(max(groups.values.map(\.totalTokens).max() ?? 1, 1)))
                                .tint(tool == .claudeCode ? .neonCyan : tool == .codeX ? .neonBlue : tool == .hermes ? .neonPurple : .white)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(value)").font(.caption.monospacedDigit())
                                Text(lang.select("Cache \(cachePercent) · \(requests) req", "缓存 \(cachePercent) · \(requests) 次"))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.scopeTextMuted)
                            }
                            .frame(width: 110, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

struct RecentUsageView: View {
    @Environment(\.appLanguage) private var lang
    let records: [UsageRecord]

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(lang.select("Recent Detail", "最近明细"))
                    .font(.headline)
                Table(records) {
                    TableColumn(lang.select("Tool", "工具")) { Text($0.source.rawValue).lineLimit(1) }
                    TableColumn(lang.select("Model", "模型")) { Text($0.model).lineLimit(1).minimumScaleFactor(0.7) }
                    TableColumn("Tokens") { Text("\($0.totalTokens)").monospacedDigit() }
                    TableColumn(lang.select("Cost", "费用")) { Text(DecimalFormatting.currency($0.estimatedCost)).monospacedDigit() }
                }
                .frame(minHeight: 170)
            }
        }
    }
}

struct UsageDetailView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang
    @State private var selected: UsageRecord.ID?

    private var filteredRecordsSnapshot: [UsageRecord] {
        Array(store.filteredRecords().prefix(2_000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: lang.select("Usage Detail", "用量明细"), subtitle: lang.select("Filter and search by tool, account, API Key identity, model", "按工具、账号、API Key 标识、模型筛选和搜索"))
            RangeFilterBar()
            GlassPanel {
                Table(filteredRecordsSnapshot, selection: $selected) {
                    TableColumn(lang.select("Tool", "工具")) { Text($0.source.rawValue) }
                    TableColumn(lang.select("Account", "账号")) { Text($0.accountId).lineLimit(1).minimumScaleFactor(0.75) }
                    TableColumn("API Key") { Text($0.apiKeyHash).lineLimit(1).minimumScaleFactor(0.75) }
                    TableColumn(lang.select("Model", "模型")) { Text($0.model).lineLimit(1).minimumScaleFactor(0.75) }
                    TableColumn(lang.select("Input", "输入")) { Text("\($0.inputTokens)").monospacedDigit() }
                    TableColumn(lang.select("Output", "输出")) { Text("\($0.outputTokens)").monospacedDigit() }
                    TableColumn(lang.select("Cache Read", "缓存读取")) { Text("\($0.cacheReadTokens)").monospacedDigit().foregroundStyle($0.cacheReadTokens > 0 ? Color.neonBlue : Color.scopeTextMuted) }
                    TableColumn(lang.select("Cache Create", "缓存创建")) { record in
                        if record.showsCacheCreation {
                            Text("\(record.cacheCreationTokens)").monospacedDigit().foregroundStyle(record.cacheCreationTokens > 0 ? Color.neonPurple : Color.scopeTextMuted)
                        } else {
                            Text(verbatim: "N/A").monospacedDigit().foregroundStyle(Color.scopeTextMuted)
                        }
                    }
                    TableColumn(lang.select("Total", "总量")) { Text("\($0.totalTokens)").monospacedDigit() }
                    TableColumn(lang.select("Cost", "费用")) { Text(DecimalFormatting.currency($0.estimatedCost)).monospacedDigit() }
                }
                .frame(minHeight: 480)
            }
        }
    }
}
