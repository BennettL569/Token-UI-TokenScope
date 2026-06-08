import SwiftUI
import TokenScopeCore

struct ToolDistributionView: View {
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
                Text("工具分布")
                    .font(.headline)
                if groups.isEmpty {
                    ContentUnavailableView("暂无工具统计", systemImage: "square.stack.3d.up.slash")
                } else {
                    ForEach(ToolKind.allCases) { tool in
                        let value = groups[tool]?.totalTokens ?? 0
                        let cacheHitRate = groups[tool]?.cacheHitRate ?? 0
                        HStack {
                            Text(tool.rawValue).frame(width: 110, alignment: .leading)
                            ProgressView(value: Double(value), total: Double(max(groups.values.map(\.totalTokens).max() ?? 1, 1)))
                                .tint(tool == .claudeCode ? .neonCyan : tool == .codeX ? .neonBlue : tool == .hermes ? .neonPurple : .white)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(value)").font(.caption.monospacedDigit())
                                Text("缓存 \(Self.percentFormatter.string(from: NSNumber(value: cacheHitRate)) ?? "0%")")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Color.scopeTextMuted)
                            }
                            .frame(width: 86, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }
}

struct RecentUsageView: View {
    let records: [UsageRecord]

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text("最近明细")
                    .font(.headline)
                Table(records) {
                    TableColumn("工具") { Text($0.source.rawValue).lineLimit(1) }
                    TableColumn("模型") { Text($0.model).lineLimit(1).minimumScaleFactor(0.7) }
                    TableColumn("Tokens") { Text("\($0.totalTokens)").monospacedDigit() }
                    TableColumn("费用") { Text(DecimalFormatting.currency($0.estimatedCost)).monospacedDigit() }
                }
                .frame(minHeight: 170)
            }
        }
    }
}

struct UsageDetailView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var selected: UsageRecord.ID?

    private var filteredRecordsSnapshot: [UsageRecord] {
        Array(store.filteredRecords().prefix(2_000))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: "Usage 明细", subtitle: "按工具、账号、API Key 标识、模型筛选和搜索")
            RangeFilterBar()
            GlassPanel {
                Table(filteredRecordsSnapshot, selection: $selected) {
                    TableColumn("工具") { Text($0.source.rawValue) }
                    TableColumn("账号") { Text($0.accountId).lineLimit(1).minimumScaleFactor(0.75) }
                    TableColumn("API Key") { Text($0.apiKeyHash).lineLimit(1).minimumScaleFactor(0.75) }
                    TableColumn("模型") { Text($0.model).lineLimit(1).minimumScaleFactor(0.75) }
                    TableColumn("输入") { Text("\($0.inputTokens)").monospacedDigit() }
                    TableColumn("输出") { Text("\($0.outputTokens)").monospacedDigit() }
                    TableColumn("缓存命中") { Text("\($0.cacheTokens)").monospacedDigit().foregroundStyle($0.cacheTokens > 0 ? Color.neonBlue : Color.scopeTextMuted) }
                    TableColumn("总量") { Text("\($0.totalTokens)").monospacedDigit() }
                    TableColumn("费用") { Text(DecimalFormatting.currency($0.estimatedCost)).monospacedDigit() }
                }
                .frame(minHeight: 480)
            }
        }
    }
}
