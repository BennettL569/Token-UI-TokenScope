import SwiftUI
import TokenScopeCore

struct ExportView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang
    @State private var format: ExportFormat = .csv
    @State private var includeIdentifiers = false
    @State private var preview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: lang.select("Export / Import", "导出 / 导入"), subtitle: lang.select("Export CSV/JSON; explicitly choose whether to include account / API identifiers before exporting", "导出 CSV/JSON；导出前明确选择是否包含账号/API 标识"))
            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(lang.select("Format", "格式"), selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Toggle(lang.select("Include account / API Key identifiers in export (off by default)", "导出中包含账号/API Key 标识（默认关闭）"), isOn: $includeIdentifiers)
                    HStack {
                        Button(lang.select("Generate export preview", "生成导出预览")) {
                            preview = (try? ExportService.export(records: store.filteredRecords(), format: format, includeIdentifiers: includeIdentifiers)) ?? lang.select("Export failed", "导出失败")
                        }
                        Button(lang.select("Import JSON/CSV history", "导入 JSON/CSV 历史数据")) {}
                            .disabled(true)
                        Text(lang.select("CSV import UI is reserved; the standard JSON import service is implemented.", "CSV 导入 UI 已预留；JSON 标准导入服务已实现。"))
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
    @EnvironmentObject private var updater: UpdateManager
    @Environment(\.appLanguage) private var lang
    @AppStorage(UpdateManager.autoCheckDefaultsKey) private var autoCheckUpdates = false
    @State private var confirmClear = false
    @State private var confirmFullRebuild = false
    @State private var confirmInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: lang.select("Settings", "设置"), subtitle: lang.select("Language, privacy, security, menu bar and local data controls", "语言、隐私、安全、菜单栏和本地数据控制"))
            GlassPanel {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lang.select("Language", "语言"))
                            .font(.headline)
                        Picker(lang.select("Language", "语言"), selection: $store.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.nativeName).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        Text(lang.select("Switch the interface language. English is the default; your choice is saved.", "切换界面语言。默认英文；选择会被保存。"))
                            .font(.caption)
                            .foregroundStyle(Color.scopeTextMuted)
                    }
                    Divider()
                    Toggle(lang.select("Show today's cost in the menu bar (off shows today's tokens)", "菜单栏显示今日费用（关闭则显示今日 tokens）"), isOn: $store.menuBarShowsCost)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lang.select("Sync Strategy", "同步策略"))
                            .font(.headline)
                        Text(lang.select("A normal refresh only reads token data added since the last refresh, instead of rescanning every log from scratch. If history looks wrong or you switch data sources, you can trigger a full rebuild manually.", "默认刷新只读取上次刷新后的新增 Token 数据，避免每次从头扫描全部日志。若历史数据异常或更换数据源，可手动触发全量重建。"))
                            .font(.caption)
                            .foregroundStyle(Color.scopeTextMuted)
                        Button {
                            confirmFullRebuild = true
                        } label: {
                            Label(lang.select("Re-read all token data from scratch", "从头重读全部 Token 数据"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(store.isRefreshing)
                    }
                    Divider()
                    autoRefreshSection
                    Divider()
                    updatesSection
                    Divider()
                    Label(lang.select("No statistics are uploaded by default; all aggregation, import and export happen on this machine.", "默认不上传任何统计数据；所有聚合、导入、导出都在本机完成。"), systemImage: "lock.shield")
                    Label(lang.select("API keys are stored in the macOS Keychain; the UI shows only a masked identity.", "API Key 使用 macOS Keychain 保存，界面仅显示脱敏标识。"), systemImage: "key")
                    Button(role: .destructive) { confirmClear = true } label: {
                        Label(lang.select("Clear local statistics", "一键清除本地统计数据"), systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(lang.select("Clear all local usage statistics? This cannot be undone.", "确认清除所有本地 usage 统计？此操作不可撤销。"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(lang.select("Clear", "清除"), role: .destructive) { Task { await store.clearLocalData() } }
            Button(lang.select("Cancel", "取消"), role: .cancel) {}
        }
        .confirmationDialog(lang.select("Re-read all token data from scratch? This clears the current stats and rescans every configured data source, which takes longer than a normal incremental refresh.", "确认从头重读全部 Token 数据？这会清空当前统计并重新扫描全部已配置数据源，耗时会比普通增量刷新更长。"), isPresented: $confirmFullRebuild, titleVisibility: .visible) {
            Button(lang.select("Full rebuild", "全量重读"), role: .destructive) { Task { await store.rebuildAllData() } }
            Button(lang.select("Cancel", "取消"), role: .cancel) {}
        }
    }

    private var autoRefreshSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lang.select("Auto Refresh", "自动刷新")).font(.headline)
            Toggle(lang.select("Refresh usage data automatically", "自动刷新用量数据"), isOn: $store.autoRefreshEnabled)
            HStack(spacing: 10) {
                Text(lang.select("Interval", "刷新间隔"))
                Picker(lang.select("Interval", "刷新间隔"), selection: $store.autoRefreshInterval) {
                    ForEach(RefreshInterval.allCases) { interval in
                        Text(interval.displayName(lang)).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 160)
            }
            .disabled(!store.autoRefreshEnabled)
            Text(lang.select("When on, TokenScope runs an incremental sync on the chosen interval. \"Real-time\" polls about once a second; if the previous refresh is still running, the next tick is skipped.", "开启后，TokenScope 会按所选间隔自动增量同步。「实时刷新」约每秒轮询一次；若上一次刷新尚未结束，则会跳过本次。"))
                .font(.caption)
                .foregroundStyle(Color.scopeTextMuted)
        }
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lang.select("Updates", "更新")).font(.headline)
            HStack(spacing: 6) {
                Text(lang.select("Current version", "当前版本") + " v\(updater.currentVersion)")
                if let checked = updater.lastChecked {
                    Text("· " + lang.select("last checked \(Self.relativeTime(checked))", "上次检查 \(Self.relativeTime(checked))"))
                }
            }
            .font(.caption)
            .foregroundStyle(Color.scopeTextMuted)
            HStack(spacing: 12) {
                Button {
                    Task { await updater.check() }
                } label: {
                    Label(lang.select("Check for Updates", "检查更新"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(updater.isBusy)

                Button {
                    confirmInstall = true
                } label: {
                    Label(lang.select("Update Now", "立即更新"), systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderedProminent)
                .tint(.neonBlue)
                .disabled(!updater.canInstall)

                if case .manualDownload = updater.phase {
                    Button {
                        updater.openReleasePage()
                    } label: {
                        Label(lang.select("Open Releases Page", "前往下载页"), systemImage: "safari")
                    }
                }

                if updater.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            Text(updateStatusText)
                .font(.caption)
                .foregroundStyle(updateStatusColor)
                .lineLimit(3)
            if let notes = updateReleaseNotes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lang.select("What's new", "更新内容")).font(.caption.weight(.semibold))
                    ScrollView {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(Color.scopeTextMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 140)
                }
                .padding(8)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
            Toggle(lang.select("Check for updates automatically on launch", "启动时自动检查更新"), isOn: $autoCheckUpdates)
                .font(.caption)
            Text(lang.select("Only checks once on launch — never auto-installs, and makes no background network calls.", "仅在启动时检查一次，绝不自动安装，也不会后台联网。"))
                .font(.caption2)
                .foregroundStyle(Color.scopeTextMuted)
        }
        .confirmationDialog(updateConfirmTitle, isPresented: $confirmInstall, titleVisibility: .visible) {
            Button(lang.select("Download & Update", "下载并更新")) { Task { await updater.install() } }
            Button(lang.select("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(lang.select("The app will download the new version, replace itself and relaunch automatically.", "应用会下载新版本、替换自身并自动重启。"))
        }
    }

    private var updateConfirmTitle: String {
        if let release = updater.availableRelease {
            return lang.select("Update to \(release.tagName)?", "更新到 \(release.tagName)？")
        }
        return lang.select("Update?", "更新？")
    }

    private var updateStatusText: String {
        switch updater.phase {
        case .idle:
            return lang.select("Not checked yet — click Check for Updates.", "尚未检查 — 点击检查更新。")
        case .checking:
            return lang.select("Checking…", "检查中…")
        case .upToDate:
            return lang.select("You're on the latest version.", "已是最新版本。")
        case .available(let release):
            return lang.select("New version \(release.tagName) is available.", "发现新版本 \(release.tagName)。")
        case .manualDownload(let release):
            return lang.select(
                "Version \(release.tagName) is available, but this copy can't update itself here — open the releases page to update manually (move the app into Applications first).",
                "发现新版本 \(release.tagName)，但当前位置无法自动更新 — 请前往下载页手动更新（建议先把 App 移到「应用程序」）。")
        case .installing:
            return lang.select("Downloading and installing… the app will relaunch.", "正在下载并安装…应用将自动重启。")
        case .failed(let message):
            return lang.select("Update failed: \(message)", "更新失败：\(message)")
        }
    }

    private var updateStatusColor: Color {
        switch updater.phase {
        case .available, .manualDownload: return .green
        case .failed: return .orange
        default: return Color.scopeTextMuted
        }
    }

    private var updateReleaseNotes: String? {
        switch updater.phase {
        case .available(let release), .manualDownload(let release): return release.notes
        default: return nil
        }
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct WidgetGuideView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: lang.select("Widgets", "小组件"), subtitle: lang.select("WidgetKit widgets read a shared summary via the App Group and never show the full API Key", "WidgetKit 小组件通过 App Group 读取共享摘要，不显示完整 API Key"))
            GlassPanel {
                VStack(alignment: .leading, spacing: 16) {
                    Label(lang.select("Small: today's total tokens + budget progress", "小号：今日总 tokens + 预算进度"), systemImage: "rectangle")
                    Label(lang.select("Medium: today/this-week tokens, cost and trend", "中号：今日/本周 tokens、费用和趋势"), systemImage: "rectangle.split.2x1")
                    Label(lang.select("Large: tool distribution, model distribution, budget progress, last update time", "大号：工具分布、模型分布、预算进度、最近更新时间"), systemImage: "rectangle.grid.2x2")
                    Button(lang.select("Write Widget summary JSON", "写入 Widget 摘要 JSON")) {
                        try? WidgetSummaryStore.save(store.widgetSummary())
                    }
                    Text(lang.select("For production packaging, the main app and the Widget Extension must share the same App Group entitlements.", "生产打包时需为主 App 与 Widget Extension 配置相同 App Group entitlements。"))
                        .font(.caption)
                        .foregroundStyle(Color.scopeTextMuted)
                }
            }
        }
    }
}

struct MenuBarMiniPanel: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang

    private struct MenuBarUsageRow: Identifiable {
        let id: TimeRange
        let label: String
        let usage: AggregatedUsage
    }

    private var menuBarRows: [MenuBarUsageRow] {
        let snapshot = store.dashboardSnapshot
        return [
            MenuBarUsageRow(id: .today, label: TimeRange.today.displayName(lang), usage: snapshot.today),
            MenuBarUsageRow(id: .week, label: TimeRange.week.displayName(lang), usage: snapshot.week),
            MenuBarUsageRow(id: .month, label: TimeRange.month.displayName(lang), usage: snapshot.month)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TokenScope Mini")
                .font(.headline)
            ForEach(menuBarRows) { row in
                HStack {
                    Text(row.label).frame(width: 64, alignment: .leading)
                    Text("\(row.usage.totalTokens) tok").monospacedDigit()
                    Spacer()
                    Text(DecimalFormatting.currency(row.usage.estimatedCost)).monospacedDigit()
                }
            }
            Button(lang.select("Quick refresh", "快速刷新")) { Task { await store.refreshAll() } }
        }
        .padding()
        .frame(width: 320)
    }
}
