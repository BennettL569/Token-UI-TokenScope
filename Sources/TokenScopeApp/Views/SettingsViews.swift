import SwiftUI
import TokenScopeCore

struct DataSourcesView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBar(title: lang.select("Data Sources", "数据源"), subtitle: lang.select("Local logs, imported files, account identity and sync status", "本地日志、导入文件、账号标识与同步状态"))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 16)], spacing: 16) {
                    ForEach(store.sources.indices, id: \.self) { index in
                        BindingSourceCard(source: $store.sources[index])
                    }
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

}

struct BindingSourceCard: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang
    @Binding var source: UsageSource

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(source.tool.rawValue).font(.title3.bold())
                    Spacer()
                    Toggle(lang.select("Enabled", "启用"), isOn: $source.isEnabled).toggleStyle(.switch)
                }
                TextField(lang.select("Source name", "数据源名称"), text: $source.name)
                TextField(lang.select("Account identity", "账号标识"), text: $source.accountId)
                TextField(lang.select("API Key identity", "API Key 标识"), text: $source.apiKeyIdentity)
                TextField(lang.select("Local log path", "本地日志路径"), text: $source.localLogPath)
                HStack {
                    StatusBadge(status: source.syncStatus)
                    Spacer()
                    Button(lang.select("Refresh this source", "刷新此源")) { Task { await store.refreshAll() } }
                }
                Text(source.syncStatus.kind == .idle ? lang.select("Not synced yet", "尚未同步") : source.syncStatus.message)
                    .font(.caption)
                    .foregroundStyle(Color.scopeTextMuted)
                    .lineLimit(2)
            }
        }
    }
}

struct StatusBadge: View {
    let status: SyncStatus
    var body: some View {
        Text(status.kind.rawValue.uppercased())
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((status.kind == .success ? Color.green : status.kind == .failed ? Color.red : Color.neonBlue).opacity(0.18), in: Capsule())
            .foregroundStyle(status.kind == .success ? Color.green : status.kind == .failed ? Color.red : Color.neonCyan)
    }
}

struct AccountsView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: lang.select("Accounts", "账号"), subtitle: lang.select("Account configuration and masked API Key display; real keys are stored in the macOS Keychain", "账号配置与 API Key 脱敏展示；真实密钥写入 macOS Keychain"))
            GlassPanel {
                Table(store.sources) {
                    TableColumn(lang.select("Tool", "工具")) { Text($0.tool.rawValue) }
                    TableColumn(lang.select("Account", "账号")) { Text($0.accountId) }
                    TableColumn(lang.select("API Key identity", "API Key 标识")) { Text($0.apiKeyIdentity) }
                    TableColumn("Keychain") { _ in Label(lang.select("Stored locally", "本机保存"), systemImage: "key.fill").foregroundStyle(Color.neonCyan) }
                }
                .frame(minHeight: 420)
            }
        }
    }
}

struct PricingView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang
    @State private var newTool: ToolKind = .hermes
    @State private var newModel = ""
    @State private var newInputPrice: Decimal = 0
    @State private var newOutputPrice: Decimal = 0
    @State private var newCachePrice: Decimal = 0
    @State private var validationMessage = ""
    @State private var validationIsSuccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: lang.select("Pricing", "定价"), subtitle: lang.select("Configure per-model input/output/cache token unit prices (USD per million tokens)", "按模型配置输入、输出、缓存 tokens 单价（美元 / 百万 tokens）"))
            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Text(lang.select("Add a model price manually", "手动添加模型价格"))
                        .font(.headline)
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lang.select("Tool", "工具")).font(.caption).foregroundStyle(Color.scopeTextMuted)
                            Picker(lang.select("Tool", "工具"), selection: $newTool) {
                                ForEach(ToolKind.allCases) { tool in
                                    Text(tool.rawValue).tag(tool)
                                }
                            }
                            .frame(width: 150)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lang.select("Model name", "模型名称")).font(.caption).foregroundStyle(Color.scopeTextMuted)
                            TextField(lang.select("e.g. gpt-5.5 / claude-opus-4-6", "例如 gpt-5.5 / claude-opus-4-6"), text: $newModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 260)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lang.select("Input price", "输入价")).font(.caption).foregroundStyle(Color.scopeTextMuted)
                            DecimalField(value: $newInputPrice).frame(width: 90)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lang.select("Output price", "输出价")).font(.caption).foregroundStyle(Color.scopeTextMuted)
                            DecimalField(value: $newOutputPrice).frame(width: 90)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(lang.select("Cache price", "缓存价")).font(.caption).foregroundStyle(Color.scopeTextMuted)
                            DecimalField(value: $newCachePrice).frame(width: 90)
                        }
                        Button {
                            addPricing()
                        } label: {
                            Label(lang.select("Add / Update", "添加 / 更新"), systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.neonBlue)
                        .disabled(newModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !validationMessage.isEmpty {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(validationIsSuccess ? Color.green : Color.orange)
                    }
                    Text(lang.select("Note: prices are in USD per million tokens. When a tool and model name match a usage record, its cost is re-estimated using these prices.", "说明：单价单位为美元 / 百万 tokens。若工具和模型名称与 usage 记录匹配，费用会使用这里的价格重新估算。"))
                        .font(.caption)
                        .foregroundStyle(Color.scopeTextMuted)
                }
            }
            GlassPanel {
                Table($store.pricing) {
                    TableColumn(lang.select("Tool", "工具")) { row in Text(row.wrappedValue.tool.rawValue) }
                    TableColumn(lang.select("Model", "模型")) { row in TextField("model", text: row.model) }
                    TableColumn(lang.select("Input", "输入")) { row in DecimalField(value: row.inputPerMillion) }
                    TableColumn(lang.select("Output", "输出")) { row in DecimalField(value: row.outputPerMillion) }
                    TableColumn(lang.select("Cache", "缓存")) { row in DecimalField(value: row.cachePerMillion) }
                }
                .onChange(of: store.pricing) { _, _ in
                    store.saveAllPricing()
                }
                .frame(minHeight: 430)
            }
        }
    }

    private func addPricing() {
        let model = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            validationIsSuccess = false
            validationMessage = lang.select("Model name cannot be empty", "模型名称不能为空")
            return
        }
        let item = ModelPricing(tool: newTool, model: model, inputPerMillion: newInputPrice, outputPerMillion: newOutputPrice, cachePerMillion: newCachePrice)
        let existed = store.pricing.contains { $0.tool == newTool && $0.model.caseInsensitiveCompare(model) == .orderedSame }
        store.setPricing(item)
        validationIsSuccess = true
        if existed {
            validationMessage = lang.select("Updated and saved price for \(newTool.rawValue) / \(model)", "已更新并保存 \(newTool.rawValue) / \(model) 的价格")
        } else {
            validationMessage = lang.select("Added and saved price for \(newTool.rawValue) / \(model)", "已添加并保存 \(newTool.rawValue) / \(model) 的价格")
        }
        newModel = ""
        newInputPrice = 0
        newOutputPrice = 0
        newCachePrice = 0
    }
}

struct DecimalField: View {
    @Binding var value: Decimal
    var body: some View {
        TextField("0", value: $value, format: .number.precision(.fractionLength(0...4)))
            .monospacedDigit()
            .frame(minWidth: 70)
    }
}

struct BudgetsView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.appLanguage) private var lang
    @State private var saveMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: lang.select("Budgets", "预算"), subtitle: lang.select("Daily / weekly / monthly token and cost budgets, with 80% and 100% tiered alerts", "每日 / 每周 / 每月 tokens 与费用预算，80% 和 100% 分级提醒"))
            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(lang.select("Budget Settings", "预算设置"))
                            .font(.headline)
                        Spacer()
                        Picker(lang.select("Budget Progress Basis", "预算进度计算"), selection: $store.budgetProgressMode) {
                            ForEach(BudgetProgressMode.allCases) { mode in
                                Text(mode.displayName(lang)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    ForEach($store.budgets) { $rule in
                        HStack(spacing: 12) {
                            Text(rule.period.displayName(lang)).font(.headline).frame(width: 70, alignment: .leading)
                            Text("Tokens")
                            TextField("token limit", value: $rule.tokenLimit, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Text(lang.select("Cost", "费用"))
                            DecimalField(value: $rule.costLimit).frame(width: 120)
                            Button(lang.select("Save", "保存")) {
                                store.setBudget(rule)
                                saveMessage = lang.select("Saved \(rule.period.displayName(lang)) budget", "已保存 \(rule.period.displayName(lang)) 预算")
                            }
                            Spacer()
                        }
                    }
                    HStack {
                        Button {
                            store.saveAllBudgets()
                            saveMessage = lang.select("All budgets saved", "全部预算已保存")
                        } label: {
                            Label(lang.select("Save All Budgets", "保存全部预算"), systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.neonBlue)

                        Button {
                            store.budgets = UsageStore.defaultBudgets()
                            store.saveAllBudgets()
                            saveMessage = lang.select("Restored default budgets", "已恢复默认预算")
                        } label: {
                            Label(lang.select("Restore Defaults", "恢复默认"), systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)

                        if !saveMessage.isEmpty {
                            Text(saveMessage)
                                .font(.caption)
                                .foregroundStyle(Color.green)
                        }
                    }
                    Text(lang.select("Note: cost budgets are in USD. After editing you can save a single period or all of them. Budgets are written to SQLite and kept across restarts. The progress switch only controls whether the bar is computed by tokens or cost.", "说明：费用预算单位为美元；修改后可单独保存某一周期，也可以保存全部。预算会写入 SQLite，重启后保留。预算进度开关仅控制进度条按 Tokens 或费用计算。"))
                        .font(.caption)
                        .foregroundStyle(Color.scopeTextMuted)
                }
                .onChange(of: store.budgets) { _, _ in
                    store.saveAllBudgets()
                }
            }
            BudgetOverviewView(rows: store.dashboardSnapshot.budgetRows, budgetProgressMode: $store.budgetProgressMode)
                .frame(width: 420)
        }
    }
}
