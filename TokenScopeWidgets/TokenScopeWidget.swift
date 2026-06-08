import SwiftUI
import WidgetKit
#if !WIDGET_EXTENSION_DIRECT_CORE
import TokenScopeCore
#endif

struct TokenScopeProvider: TimelineProvider {
    func placeholder(in context: Context) -> TokenScopeEntry {
        TokenScopeEntry(date: Date(), summary: sampleSummary)
    }

    func getSnapshot(in context: Context, completion: @escaping (TokenScopeEntry) -> Void) {
        completion(TokenScopeEntry(date: Date(), summary: (try? WidgetSummaryStore.load()) ?? sampleSummary))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TokenScopeEntry>) -> Void) {
        let summary = (try? WidgetSummaryStore.load()) ?? sampleSummary
        completion(Timeline(entries: [TokenScopeEntry(date: Date(), summary: summary)], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct TokenScopeEntry: TimelineEntry {
    let date: Date
    let summary: WidgetSummary
}

struct TokenScopeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TokenScopeEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallTokenWidget(summary: entry.summary)
        case .systemMedium:
            MediumTokenWidget(summary: entry.summary)
        default:
            LargeTokenWidget(summary: entry.summary)
        }
    }
}

struct SmallTokenWidget: View {
    let summary: WidgetSummary
    var body: some View {
        VStack(alignment: .leading) {
            Text("TokenScope").font(.headline)
            Text("\(summary.todayTokens)").font(.system(size: 30, weight: .black, design: .rounded))
            Text("今日 tokens")
            ProgressView(value: min(summary.budgetProgress, 1))
        }
        .containerBackground(.black.gradient, for: .widget)
    }
}

struct MediumTokenWidget: View {
    let summary: WidgetSummary
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("今日 \(summary.todayTokens)")
                Text("本周 \(summary.weekTokens)")
                Text(DecimalFormatting.currency(summary.todayCost))
            }
            Spacer()
            VStack(alignment: .trailing) {
                ForEach(summary.trend.suffix(6)) { bucket in
                    Text("\(bucket.label) \(bucket.totalTokens)").font(.caption2)
                }
            }
        }
        .containerBackground(.black.gradient, for: .widget)
    }
}

struct LargeTokenWidget: View {
    let summary: WidgetSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TokenScope Command Center").font(.headline)
            Text("今日 \(summary.todayTokens) · 本月 \(summary.monthTokens)")
            ProgressView(value: min(summary.budgetProgress, 1))
            Text("工具分布").font(.caption.bold())
            ForEach(summary.toolTotals.sorted(by: { $0.value > $1.value }).prefix(4), id: \.key) { key, value in
                HStack { Text(key); Spacer(); Text("\(value)") }.font(.caption)
            }
            Text("更新：\(summary.generatedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
        }
        .containerBackground(.black.gradient, for: .widget)
    }
}

@main
struct TokenScopeWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TokenScopeWidgets", provider: TokenScopeProvider()) { entry in
            TokenScopeWidgetView(entry: entry)
        }
        .configurationDisplayName("TokenScope")
        .description("显示 tokens、费用、趋势和预算进度。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private let sampleSummary = WidgetSummary(generatedAt: Date(), todayTokens: 24800, weekTokens: 135000, monthTokens: 420000, todayCost: 2.48, weekCost: 13.5, monthCost: 42, budgetProgress: 0.62, toolTotals: ["Hermes": 12000, "ClaudeCode": 9000], modelTotals: ["gpt-5.5": 12000], trend: [])
