import SwiftUI
import UniformTypeIdentifiers
import TokenScopeCore

struct ExportView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang
    @State private var format: ExportFormat = .csv
    @State private var includeIdentifiers = false
    @State private var preview = ""
    @State private var backupBusy = false
    @State private var backupStatus: String?
    @State private var pendingImport: BackupImportPreview?
    @State private var showImportConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: lang.select("Export / Import", "导出 / 导入"), subtitle: lang.select("Full backup and restore, plus CSV/JSON reports of the current view", "完整备份与恢复，以及当前视图的 CSV/JSON 报表"))
            backupPanel
            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Text(lang.select("Report export", "报表导出")).font(.headline)
                    Picker(lang.select("Format", "格式"), selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    Toggle(lang.select("Include account / API Key identifiers in export (off by default)", "导出中包含账号/API Key 标识（默认关闭）"), isOn: $includeIdentifiers)
                    Button(lang.select("Generate export preview", "生成导出预览")) {
                        preview = (try? ExportService.export(records: store.filteredRecords(), format: format, includeIdentifiers: includeIdentifiers)) ?? lang.select("Export failed", "导出失败")
                    }
                    TextEditor(text: $preview)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 360)
                        .scrollContentBackground(.hidden)
                        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .confirmationDialog(lang.select("Import this backup?", "导入这个备份？"), isPresented: $showImportConfirmation, titleVisibility: .visible, presenting: pendingImport) { preview in
            let hasSettings = !preview.backup.pricing.isEmpty || !preview.backup.budgets.isEmpty
            if preview.newRecordCount > 0 {
                Button(lang.select("Import \(preview.newRecordCount.formatted()) new records", "导入 \(preview.newRecordCount.formatted()) 条新记录")) { applyImport(preview, restoreSettings: false) }
            }
            if hasSettings {
                Button(preview.newRecordCount > 0
                       ? lang.select("Import records and restore pricing & budgets", "导入记录并恢复价格表和预算")
                       : lang.select("Restore pricing & budgets", "恢复价格表和预算")) { applyImport(preview, restoreSettings: true) }
            }
            Button(lang.select("Cancel", "取消"), role: .cancel) {}
        } message: { preview in
            Text(importSummary(preview))
        }
    }

    private var backupPanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(lang.select("Full backup", "完整备份")).font(.headline)
                Text(lang.select("Saves every record (not limited by the current filters) plus pricing and budgets to one file. Importing it into TokenScope on any Mac brings all of that data back. The file contains local file paths and account identifiers, so keep it private.", "把全部记录（不受当前筛选影响）以及价格表和预算保存成一个文件，在任何一台 Mac 的 TokenScope 中导入即可拿回全部数据。文件包含本机路径和账号标识，请妥善保管。"))
                    .font(.caption)
                    .foregroundStyle(Color.scopeTextMuted)
                HStack {
                    Button(action: exportBackup) {
                        Label(lang.select("Export full backup…", "导出完整备份…"), systemImage: "square.and.arrow.up")
                    }
                    Button(action: chooseBackupToImport) {
                        Label(lang.select("Import backup…", "导入备份…"), systemImage: "square.and.arrow.down")
                    }
                    Button(action: openSafetyBackups) {
                        Label(lang.select("Automatic backups", "自动备份"), systemImage: "folder")
                    }
                }
                .disabled(backupBusy || store.isRefreshing)
                Text(lang.select("Importing only adds records this database doesn't have yet. It never changes or deletes existing data, and the database is backed up automatically first. You can also import one of the automatic backups (.sqlite), which are saved before every full re-read, clear and import.", "导入只会新增本机还没有的记录，不会修改或删除任何现有数据，导入前也会先自动备份数据库。也可以导入「自动备份」里的 .sqlite 文件，每次全量重读、清除数据和导入之前都会自动生成。"))
                    .font(.caption)
                    .foregroundStyle(Color.scopeTextMuted)
                if let backupStatus {
                    Text(backupStatus)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TokenScope-backup-\(Date().formatted(.iso8601.year().month().day())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupBusy = true
        backupStatus = lang.select("Exporting…", "正在导出…")
        Task {
            defer { backupBusy = false }
            do {
                let count = try await store.exportBackup(to: url)
                backupStatus = lang.select("Exported \(count.formatted()) records to \(url.lastPathComponent); the file was read back and verified.", "已导出 \(count.formatted()) 条记录到 \(url.lastPathComponent)，并已回读校验无误。")
            } catch {
                backupStatus = describe(error)
            }
        }
    }

    private func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "sqlite") ?? .database]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupBusy = true
        backupStatus = lang.select("Reading backup…", "正在读取备份…")
        Task {
            defer { backupBusy = false }
            do {
                pendingImport = try await store.prepareImport(from: url)
                backupStatus = nil
                showImportConfirmation = true
            } catch {
                backupStatus = describe(error)
            }
        }
    }

    private func applyImport(_ preview: BackupImportPreview, restoreSettings: Bool) {
        backupBusy = true
        backupStatus = lang.select("Importing…", "正在导入…")
        Task {
            defer { backupBusy = false }
            do {
                let added = try await store.applyImport(preview, restoreSettings: restoreSettings)
                let settingsNote = restoreSettings ? lang.select(" Pricing and budgets were restored.", "价格表和预算已恢复。") : ""
                backupStatus = lang.select("Added \(added.formatted()) records.", "已新增 \(added.formatted()) 条记录。") + settingsNote
            } catch {
                backupStatus = describe(error)
            }
        }
    }

    private func openSafetyBackups() {
        let directory = store.safetyBackupDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    private func importSummary(_ preview: BackupImportPreview) -> String {
        let date = preview.backup.exportedAt.formatted(date: .abbreviated, time: .shortened)
        let total = preview.newRecordCount + preview.existingRecordCount
        var text = preview.newRecordCount == 0
            ? lang.select("Backup from \(date): all \(total.formatted()) records are already on this Mac.", "备份时间 \(date)：全部 \(total.formatted()) 条记录本机都已有。")
            : lang.select("Backup from \(date) with \(total.formatted()) records: \(preview.existingRecordCount.formatted()) are already here and stay as they are; \(preview.newRecordCount.formatted()) will be added.", "备份时间 \(date)，共 \(total.formatted()) 条记录：本机已有 \(preview.existingRecordCount.formatted()) 条（保持不变），将新增 \(preview.newRecordCount.formatted()) 条。")
        if preview.unsupportedToolRecordCount > 0 {
            text += lang.select(" \(preview.unsupportedToolRecordCount.formatted()) of them come from tools this version doesn't support yet; they are kept and appear after an update.", "其中 \(preview.unsupportedToolRecordCount.formatted()) 条来自当前版本还不支持的工具，会先保存，升级后显示。")
        }
        return text
    }

    private func describe(_ error: Error) -> String {
        if let backupError = error as? BackupError { return backupError.message(lang) }
        return lang.select("Failed: \(error.localizedDescription)", "失败：\(error.localizedDescription)")
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
        .confirmationDialog(lang.select("Clear all local usage statistics? A safety backup of the database is saved first; you can restore it from Export / Import.", "确认清除所有本地 usage 统计？清除前会自动保存一份数据库安全备份，可在「导出 / 导入」页恢复。"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(lang.select("Clear", "清除"), role: .destructive) { Task { await store.clearLocalData() } }
            Button(lang.select("Cancel", "取消"), role: .cancel) {}
        }
        .confirmationDialog(lang.select("Re-read all token data from scratch? Every configured data source is rescanned, which takes longer than a normal incremental refresh. Records whose original logs no longer exist are kept, and the database is backed up first.", "确认从头重读全部 Token 数据？这会重新扫描全部已配置数据源，耗时会比普通增量刷新更长。原始日志已不存在的历史记录会保留，开始前会自动备份数据库。"), isPresented: $confirmFullRebuild, titleVisibility: .visible) {
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
