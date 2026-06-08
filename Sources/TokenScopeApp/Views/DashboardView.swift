import SwiftUI
import TokenScopeCore

struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    private static let tokenFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter
    }()
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBar(title: "TokenScope", subtitle: "AI Tokens & Cost Command Center")
                RangeFilterBar()
                metrics
                HStack(alignment: .top, spacing: 16) {
                    TrendChartView(buckets: store.dashboardSnapshot.trend)
                        .frame(minHeight: 260)
                    BudgetOverviewView(rows: store.dashboardSnapshot.budgetRows, budgetProgressMode: $store.budgetProgressMode)
                        .frame(width: 310)
                }
                HStack(alignment: .top, spacing: 16) {
                    ToolDistributionView(groups: store.dashboardSnapshot.toolGroups)
                    RecentUsageView(records: store.dashboardSnapshot.recentRecords)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 2)
            .padding(.horizontal, 12)
            .padding(.bottom, 28)
        }
        .contentMargins(.trailing, 14, for: .scrollContent)
        .contentMargins(.leading, 2, for: .scrollContent)
        .scrollIndicators(.automatic)
    }

    private var metrics: some View {
        let snapshot = store.dashboardSnapshot
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
            MetricCard(title: "今日 Tokens", value: formatTokens(snapshot.today.totalTokens), subtitle: DecimalFormatting.currency(snapshot.today.estimatedCost), accent: .neonCyan)
            MetricCard(title: "本周 Tokens", value: formatTokens(snapshot.week.totalTokens), subtitle: "缓存命中 \(formatPercent(snapshot.week.cacheHitRate))", accent: .neonPurple)
            MetricCard(title: "本月 Tokens", value: formatTokens(snapshot.month.totalTokens), subtitle: "缓存命中 \(formatPercent(snapshot.month.cacheHitRate))", accent: .neonBlue)
            MetricCard(title: "所选范围 Tokens", value: formatTokens(snapshot.selected.totalTokens), subtitle: selectedRangeSubtitle(usage: snapshot.selected), accent: .primary)
            MetricCard(title: "缓存命中", value: formatPercent(snapshot.selected.cacheHitRate), subtitle: "所选范围缓存 \(formatTokens(snapshot.selected.cacheTokens)) tokens", accent: .neonBlue)
            MetricCard(title: "全部 Tokens", value: formatTokens(snapshot.all.totalTokens), subtitle: "缓存 \(formatTokens(snapshot.all.cacheTokens)) · 命中 \(formatPercent(snapshot.all.cacheHitRate))", accent: .primary)
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        Self.tokenFormatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    private func formatPercent(_ value: Double) -> String {
        Self.percentFormatter.string(from: NSNumber(value: value)) ?? "0%"
    }

    private func selectedRangeSubtitle(usage: AggregatedUsage) -> String {
        if store.usesCustomDateRange {
            return "\(Self.dateFormatter.string(from: store.customDateRange.start)) 至 \(Self.dateFormatter.string(from: store.customDateRange.end)) · \(DecimalFormatting.currency(usage.estimatedCost))"
        }
        return "\(store.selectedRange.rawValue) · \(DecimalFormatting.currency(usage.estimatedCost))"
    }
}

struct HeaderBar: View {
    @EnvironmentObject private var store: UsageStore
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.neonCyan, .neonPurple], startPoint: .leading, endPoint: .trailing))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Color.scopeTextMuted)
            }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small) }
            if !store.refreshProgress.isEmpty {
                Text(store.refreshProgress)
                    .font(.caption)
                    .foregroundStyle(Color.scopeTextMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Button {
                Task { await store.refreshAll() }
            } label: {
                Label("刷新全部", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(.neonBlue)
        }
    }
}

struct RangeFilterBar: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Picker("时间范围", selection: $store.selectedRange) {
                        ForEach(TimeRange.allCases) { range in Text(range.rawValue).tag(range) }
                    }
                    .pickerStyle(.segmented)
                    .frame(minWidth: 260, idealWidth: 360, maxWidth: 420)
                    .layoutPriority(1)

                    Toggle("自定义", isOn: $store.usesCustomDateRange)
                        .toggleStyle(.switch)
                        .fixedSize()

                    Picker("工具", selection: Binding(get: { store.selectedTool ?? ToolKind?.none }, set: { store.selectedTool = $0 })) {
                        Text("全部工具").tag(ToolKind?.none)
                        ForEach(ToolKind.allCases) { tool in Text(tool.rawValue).tag(Optional(tool)) }
                    }
                    .frame(width: 180)

                    Spacer(minLength: 0)
                }

                if store.usesCustomDateRange {
                    HStack(alignment: .center, spacing: 8) {
                        Text("自定义范围")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.scopeTextMuted)
                        DatePicker("开始", selection: Binding(get: { store.customDateRange.start }, set: { store.customDateRange = CustomDateRange(start: $0, end: store.customDateRange.end) }), displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .frame(width: 142)
                        Text("至")
                            .font(.caption)
                            .foregroundStyle(Color.scopeTextMuted)
                        DatePicker("结束", selection: Binding(get: { store.customDateRange.end }, set: { store.customDateRange = CustomDateRange(start: store.customDateRange.start, end: $0) }), displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .frame(width: 142)
                        Spacer(minLength: 0)
                    }
                }

                TextField("搜索账号 / 模型 / API Key 标识", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
