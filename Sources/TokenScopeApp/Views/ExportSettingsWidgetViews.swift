import SwiftUI
import TokenScopeCore

struct ExportView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var format: ExportFormat = .csv
    @State private var includeIdentifiers = false
    @State private var preview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: "Export / Import", subtitle: "导出 CSV/JSON；导出前明确选择是否包含账号/API 标识")
            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("格式", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Toggle("导出中包含账号/API Key 标识（默认关闭）", isOn: $includeIdentifiers)
                    HStack {
                        Button("生成导出预览") {
                            preview = (try? ExportService.export(records: store.filteredRecords(), format: format, includeIdentifiers: includeIdentifiers)) ?? "导出失败"
                        }
                        Button("导入 JSON/CSV 历史数据") {}
                            .disabled(true)
                        Text("CSV 导入 UI 已预留；JSON 标准导入服务已实现。")
                            .font(.caption)
                            .foregroundStyle(Color.scopeTextMuted)
                    }
                    TextEditor(text: $preview)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 360)
                        .scrollContentBackground(.hidden)
                        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var confirmClear = false
    @State private var confirmFullRebuild = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: "Settings", subtitle: "隐私、安全、菜单栏和本地数据控制")
            GlassPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("菜单栏显示今日费用（关闭则显示今日 tokens）", isOn: $store.menuBarShowsCost)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("同步策略")
                            .font(.headline)
                        Text("默认刷新只读取上次刷新后的新增 Token 数据，避免每次从头扫描全部日志。若历史数据异常或更换数据源，可手动触发全量重建。")
                            .font(.caption)
                            .foregroundStyle(Color.scopeTextMuted)
                        Button {
                            confirmFullRebuild = true
                        } label: {
                            Label("从头重读全部 Token 数据", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(store.isRefreshing)
                    }
                    Divider()
                    Label("默认不上传任何统计数据；所有聚合、导入、导出都在本机完成。", systemImage: "lock.shield")
                    Label("API Key 使用 macOS Keychain 保存，界面仅显示脱敏标识。", systemImage: "key")
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label("一键清除本地统计数据", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog("确认清除所有本地 usage 统计？此操作不可撤销。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { Task { await store.clearLocalData() } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("确认从头重读全部 Token 数据？这会清空当前统计并重新扫描全部已配置数据源，耗时会比普通增量刷新更长。", isPresented: $confirmFullRebuild, titleVisibility: .visible) {
            Button("全量重读", role: .destructive) { Task { await store.rebuildAllData() } }
            Button("取消", role: .cancel) {}
        }
    }
}

struct WidgetGuideView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: "Widgets", subtitle: "WidgetKit 小组件通过 App Group 读取共享摘要，不显示完整 API Key")
            GlassPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Label("小号：今日总 tokens + 预算进度", systemImage: "rectangle")
                    Label("中号：今日/本周 tokens、费用和趋势", systemImage: "rectangle.split.2x1")
                    Label("大号：工具分布、模型分布、预算进度、最近更新时间", systemImage: "rectangle.grid.2x2")
                    Button("写入 Widget 摘要 JSON") {
                        try? WidgetSummaryStore.save(store.widgetSummary())
                    }
                    Text("生产打包时需为主 App 与 Widget Extension 配置相同 App Group entitlements。")
                        .font(.caption)
                        .foregroundStyle(Color.scopeTextMuted)
                }
            }
        }
    }
}

struct MenuBarMiniPanel: View {
    @EnvironmentObject private var store: UsageStore

    private struct MenuBarUsageRow: Identifiable {
        let id: TimeRange
        let label: String
        let usage: AggregatedUsage
    }

    private var menuBarRows: [MenuBarUsageRow] {
        let snapshot = store.dashboardSnapshot
        return [
            MenuBarUsageRow(id: .today, label: TimeRange.today.rawValue, usage: snapshot.today),
            MenuBarUsageRow(id: .week, label: TimeRange.week.rawValue, usage: snapshot.week),
            MenuBarUsageRow(id: .month, label: TimeRange.month.rawValue, usage: snapshot.month)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TokenScope Mini")
                .font(.headline)
            ForEach(menuBarRows) { row in
                HStack {
                    Text(row.label).frame(width: 48, alignment: .leading)
                    Text("\(row.usage.totalTokens) tok").monospacedDigit()
                    Spacer()
                    Text(DecimalFormatting.currency(row.usage.estimatedCost)).monospacedDigit()
                }
            }
            Button("快速刷新") { Task { await store.refreshAll() } }
        }
        .padding()
        .frame(width: 320)
    }
}
