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
                    ToolDistributionView(
                        groups: store.dashboardSnapshot.toolGroups,
                        activeFilterSummary: activeFilterSummary,
                        onClearFilter: activeFilterSummary == nil ? nil : { store.searchText = ""; store.selectedTool = nil }
                    )
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

    /// Describes the active search / tool filter (the dimensions that filter the tool distribution,
    /// `selected`-range and request cards), or `nil` when neither is set. Used to explain an empty
    /// tool distribution as "filtered out" rather than "no data", and to offer a one-click clear.
    private var activeFilterSummary: String? {
        var parts: [String] = []
        if !store.searchText.isEmpty {
            parts.append(lang.select("search “\(store.searchText)”", "搜索 “\(store.searchText)”"))
        }
        if let tool = store.selectedTool {
            parts.append(lang.select("tool \(tool.rawValue)", "工具 \(tool.rawValue)"))
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: lang.select(", ", "，"))
        return lang.select("Current filter: \(joined)", "当前筛选：\(joined)")
    }

    private var metrics: some View {
        let snapshot = store.dashboardSnapshot
        // Cache creation is only meaningful for Claude Code (Anthropic bills cache writes as a
        // distinct category). When filtered to any other single tool with no cache creation, show
        // "N/A" instead of a misleading 0 — matching the Usage table — and explain why.
        let cacheCreationUnavailable = (store.selectedTool.map { !$0.reportsCacheCreation } ?? false)
            && snapshot.selected.cacheCreationTokens == 0
        let cacheCreationHint: String? = {
            guard cacheCreationUnavailable, let tool = store.selectedTool else { return nil }
            return lang.select(
                "Only Claude Code reports cache-creation (write) tokens separately; \(tool.rawValue) doesn't, so this shows N/A.",
                "仅 Claude Code 会单独上报缓存创建（写入）token，\(tool.rawValue) 不区分，因此显示 N/A。")
        }()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
            MetricCard(title: lang.select("Today Tokens", "今日 Tokens"), value: formatTokens(snapshot.today.totalTokens), subtitle: DecimalFormatting.currency(snapshot.today.estimatedCost), accent: .neonCyan)
            MetricCard(title: lang.select("This Week Tokens", "本周 Tokens"), value: formatTokens(snapshot.week.totalTokens), subtitle: lang.select("Cache hit \(formatPercent(snapshot.week.cacheHitRate))", "缓存命中 \(formatPercent(snapshot.week.cacheHitRate))"), accent: .neonPurple)
            MetricCard(title: lang.select("This Month Tokens", "本月 Tokens"), value: formatTokens(snapshot.month.totalTokens), subtitle: lang.select("Cache hit \(formatPercent(snapshot.month.cacheHitRate))", "缓存命中 \(formatPercent(snapshot.month.cacheHitRate))"), accent: .neonBlue)
            MetricCard(title: lang.select("Selected Range Tokens", "所选范围 Tokens"), value: formatTokens(snapshot.selected.totalTokens), subtitle: selectedRangeSubtitle(usage: snapshot.selected), accent: .primary)
            MetricCard(title: lang.select("Requests", "请求数"), value: formatTokens(snapshot.selected.requestCount), subtitle: lang.select("All \(formatTokens(snapshot.all.requestCount)) requests", "全部 \(formatTokens(snapshot.all.requestCount)) 次"), accent: .neonPurple)
            MetricCard(title: lang.select("Cache Creation", "缓存创建"), value: cacheCreationUnavailable ? "N/A" : formatTokens(snapshot.selected.cacheCreationTokens), subtitle: lang.select("Cache read \(formatTokens(snapshot.selected.cacheReadTokens))", "缓存读取 \(formatTokens(snapshot.selected.cacheReadTokens))"), accent: .neonBlue, hint: cacheCreationHint)
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
                    // Reflect external clears (e.g. the tool-distribution "Clear filter" button) back
                    // into the field; otherwise the draft would re-push the stale term after debounce.
                    .onChange(of: store.searchText) { _, newValue in
                        if newValue != searchDraft { searchDraft = newValue }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
