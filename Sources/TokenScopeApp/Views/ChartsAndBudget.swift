import SwiftUI
import TokenScopeCore

struct TrendChartView: View {
    @Environment(\.appLanguage) private var lang
    let buckets: [TrendBucket]

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(lang.select("Tokens Trend", "Tokens 趋势"))
                    .font(.headline)
                if buckets.isEmpty {
                    ContentUnavailableView(lang.select("No trend data", "暂无趋势数据"), systemImage: "waveform.path.ecg", description: Text(lang.select("Hourly / daily / monthly trend appears after refresh or import", "刷新或导入数据后显示逐小时/每日/每月趋势")))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    GeometryReader { proxy in
                        let maxValue = max(buckets.map(\.totalTokens).max() ?? 1, 1)
                        HStack(alignment: .bottom, spacing: 8) {
                            ForEach(Array(buckets.suffix(18))) { bucket in
                                VStack(spacing: 5) {
                                    stackedBar(bucket: bucket, maxValue: maxValue, height: max(100, proxy.size.height - 40))
                                    Text(bucket.label)
                                        .font(.caption2)
                                        .foregroundStyle(Color.scopeTextMuted)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(minHeight: 190)
                    HStack(spacing: 14) {
                        legend(lang.select("Input", "输入"), .neonCyan)
                        legend(lang.select("Output", "输出"), .neonPurple)
                        legend(lang.select("Cache", "缓存"), .neonBlue)
                        Spacer()
                    }
                }
            }
        }
    }

    private func stackedBar(bucket: TrendBucket, maxValue: Int, height: CGFloat) -> some View {
        let inputHeight = CGFloat(bucket.inputTokens) / CGFloat(maxValue) * height
        let outputHeight = CGFloat(bucket.outputTokens) / CGFloat(maxValue) * height
        let cacheHeight = CGFloat(bucket.cacheTokens) / CGFloat(maxValue) * height
        return VStack(spacing: 1) {
            RoundedRectangle(cornerRadius: 2).fill(Color.neonPurple).frame(height: max(2, outputHeight))
            RoundedRectangle(cornerRadius: 2).fill(Color.neonCyan).frame(height: max(2, inputHeight))
            RoundedRectangle(cornerRadius: 2).fill(Color.neonBlue.opacity(0.75)).frame(height: max(bucket.cacheTokens == 0 ? 0 : 2, cacheHeight))
        }
        .frame(width: 18, height: height, alignment: .bottom)
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(Color.scopeTextMuted)
        }
    }
}

struct BudgetOverviewView: View {
    @Environment(\.appLanguage) private var lang
    let rows: [BudgetProgressSnapshot]
    @Binding var budgetProgressMode: BudgetProgressMode

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(lang.select("Budget Radar", "预算雷达"))
                        .font(.headline)
                    Spacer()
                    Picker(lang.select("Budget Progress", "预算进度"), selection: $budgetProgressMode) {
                        ForEach(BudgetProgressMode.allCases) { mode in
                            Text(mode.displayName(lang)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                ForEach(rows) { row in
                    let rule = row.rule
                    let usage = row.usage
                    let tokenProgress = row.tokenProgress
                    let costProgress = row.costProgress
                    let progress = row.activeProgress
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(rule.period.displayName(lang)).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .foregroundStyle(color(for: progress))
                        }
                        ProgressView(value: min(progress, 1))
                            .tint(color(for: progress))
                        Text(lang.select("Tokens \(Int(tokenProgress * 100))% · Cost \(Int(costProgress * 100))%  ｜  \(usage.totalTokens)/\(rule.tokenLimit) tokens · \(DecimalFormatting.currency(usage.estimatedCost))/\(DecimalFormatting.currency(rule.costLimit))", "Tokens \(Int(tokenProgress * 100))% · 费用 \(Int(costProgress * 100))%  ｜  \(usage.totalTokens)/\(rule.tokenLimit) tokens · \(DecimalFormatting.currency(usage.estimatedCost))/\(DecimalFormatting.currency(rule.costLimit))"))
                            .font(.caption)
                            .foregroundStyle(Color.scopeTextMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                }
            }
        }
    }

    private func color(for progress: Double) -> Color {
        if progress >= 1 { return .red }
        if progress >= 0.8 { return .orange }
        return .neonCyan
    }
}
