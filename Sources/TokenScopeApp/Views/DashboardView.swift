import SwiftUI
import TokenScopeCore

struct DashboardView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang
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
                HeaderBar(title: "TokenScope", subtitle: lang.select("AI Tokens & Cost Command Center", "AI Tokens 与成本指挥中心"))
                RangeFilterBar()
                if let error = store.errorMessage, !error.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang.select("Some sources failed to sync — totals may be incomplete.", "部分数据源同步失败，统计可能不完整。"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Color.scopeTextMuted)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
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
        // When filtered to a tool that doesn't report cache-creation (write) tokens — Codex follows
        // OpenAI accounting, which only reports cache reads — the Cache Creation card is structurally
        // 0. Explain that so it doesn't read as a bug.
        let cacheCreationHint: String? = {
            guard let tool = store.selectedTool, !tool.reportsCacheCreation else { return nil }
            return lang.select(
                "\(tool.rawValue) reports cache reads only — it has no cache-creation (write) tokens, so this is always 0.",
                "\(tool.rawValue) 只上报缓存读取，没有缓存创建（写入）token，因此这里始终为 0。")
        }()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
            MetricCard(title: lang.select("Today Tokens", "今日 Tokens"), value: formatTokens(snapshot.today.totalTokens), subtitle: DecimalFormatting.currency(snapshot.today.estimatedCost), accent: .neonCyan)
            MetricCard(title: lang.select("This Week Tokens", "本周 Tokens"), value: formatTokens(snapshot.week.totalTokens), subtitle: lang.select("Cache hit \(formatPercent(snapshot.week.cacheHitRate))", "缓存命中 \(formatPercent(snapshot.week.cacheHitRate))"), accent: .neonPurple)
            MetricCard(title: lang.select("This Month Tokens", "本月 Tokens"), value: formatTokens(snapshot.month.totalTokens), subtitle: lang.select("Cache hit \(formatPercent(snapshot.month.cacheHitRate))", "缓存命中 \(formatPercent(snapshot.month.cacheHitRate))"), accent: .neonBlue)
            MetricCard(title: lang.select("Selected Range Tokens", "所选范围 Tokens"), value: formatTokens(snapshot.selected.totalTokens), subtitle: selectedRangeSubtitle(usage: snapshot.selected), accent: .primary)
            MetricCard(title: lang.select("Requests", "请求数"), value: formatTokens(snapshot.selected.requestCount), subtitle: lang.select("All \(formatTokens(snapshot.all.requestCount)) requests", "全部 \(formatTokens(snapshot.all.requestCount)) 次"), accent: .neonPurple)
            MetricCard(title: lang.select("Cache Creation", "缓存创建"), value: formatTokens(snapshot.selected.cacheCreationTokens), subtitle: lang.select("Cache read \(formatTokens(snapshot.selected.cacheReadTokens))", "缓存读取 \(formatTokens(snapshot.selected.cacheReadTokens))"), accent: .neonBlue, hint: cacheCreationHint)
            MetricCard(title: lang.select("Cache Hit", "缓存命中"), value: formatPercent(snapshot.selected.cacheHitRate), subtitle: lang.select("Selected-range cache \(formatTokens(snapshot.selected.cacheTokens)) tokens", "所选范围缓存 \(formatTokens(snapshot.selected.cacheTokens)) tokens"), accent: .neonBlue)
            MetricCard(title: lang.select("All Tokens", "全部 Tokens"), value: formatTokens(snapshot.all.totalTokens), subtitle: lang.select("Cache \(formatTokens(snapshot.all.cacheTokens)) · hit \(formatPercent(snapshot.all.cacheHitRate))", "缓存 \(formatTokens(snapshot.all.cacheTokens)) · 命中 \(formatPercent(snapshot.all.cacheHitRate))"), accent: .primary)
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
            let separator = lang.select(" to ", " 至 ")
            return "\(Self.dateFormatter.string(from: store.customDateRange.start))\(separator)\(Self.dateFormatter.string(from: store.customDateRange.end)) · \(DecimalFormatting.currency(usage.estimatedCost))"
        }
        return "\(store.selectedRange.displayName(lang)) · \(DecimalFormatting.currency(usage.estimatedCost))"
    }
}

struct HeaderBar: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang
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
                Label(lang.select("Refresh All", "刷新全部"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(.neonBlue)
        }
    }
}

struct RangeFilterBar: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang
    /// Local mirror of the search field. Keystrokes update this immediately, but the store's
    /// `searchText` (which drives the full-record-set dashboard rebuild) is only updated after
    /// a short pause, so fast typing no longer triggers an O(records) rebuild per keystroke.
    @State private var searchDraft = ""
    /// Local mirror of the custom date pickers. Picking/scrubbing a date updates these instantly
    /// (the pickers stay responsive), but the store's `customDateRange` — which invalidates the
    /// trend cache and rebuilds the dashboard over the whole record set — is only updated after a
    /// short pause, so adjusting the range no longer rebuilds on every intermediate value.
    @State private var customStartDraft = Date()
    @State private var customEndDraft = Date()

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Picker(lang.select("Time Range", "时间范围"), selection: $store.selectedRange) {
                        ForEach(TimeRange.allCases) { range in Text(range.displayName(lang)).tag(range) }
                    }
                    .pickerStyle(.segmented)
                    .frame(minWidth: 260, idealWidth: 360, maxWidth: 420)
                    .layoutPriority(1)

                    Toggle(lang.select("Custom", "自定义"), isOn: $store.usesCustomDateRange)
                        .toggleStyle(.switch)
                        .fixedSize()

                    Picker(lang.select("Tool", "工具"), selection: Binding(get: { store.selectedTool ?? ToolKind?.none }, set: { store.selectedTool = $0 })) {
                        Text(lang.select("All Tools", "全部工具")).tag(ToolKind?.none)
                        ForEach(ToolKind.allCases) { tool in Text(tool.rawValue).tag(Optional(tool)) }
                    }
                    .frame(width: 180)

                    Spacer(minLength: 0)
                }

                if store.usesCustomDateRange {
                    HStack(alignment: .center, spacing: 8) {
                        Text(lang.select("Custom Range", "自定义范围"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.scopeTextMuted)
                        DatePicker(lang.select("Start", "开始"), selection: $customStartDraft, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .frame(width: 142)
                        Text(lang.select("to", "至"))
                            .font(.caption)
                            .foregroundStyle(Color.scopeTextMuted)
                        DatePicker(lang.select("End", "结束"), selection: $customEndDraft, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .frame(width: 142)
                        Spacer(minLength: 0)
                    }
                    .onAppear {
                        customStartDraft = store.customDateRange.start
                        customEndDraft = store.customDateRange.end
                    }
                    .task(id: "\(customStartDraft.timeIntervalSince1970)|\(customEndDraft.timeIntervalSince1970)") {
                        // Debounce: a new date value cancels this task before the sleep elapses,
                        // so only the value the user settles on triggers a dashboard rebuild.
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled else { return }
                        let next = CustomDateRange(start: customStartDraft, end: customEndDraft)
                        if store.customDateRange != next { store.customDateRange = next }
                    }
                }

                TextField(lang.select("Search account / model / API Key identity", "搜索账号 / 模型 / API Key 标识"), text: $searchDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onAppear { if searchDraft != store.searchText { searchDraft = store.searchText } }
                    .task(id: searchDraft) {
                        // Debounce: a new keystroke cancels this task before the sleep elapses.
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard !Task.isCancelled, store.searchText != searchDraft else { return }
                        store.searchText = searchDraft
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
