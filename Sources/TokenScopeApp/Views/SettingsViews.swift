import SwiftUI
import TokenScopeCore

struct DataSourcesView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderBar(title: "Data Sources", subtitle: "本地日志、导入文件、账号标识与同步状态")
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
    @Binding var source: UsageSource

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(source.tool.rawValue).font(.title3.bold())
                    Spacer()
                    Toggle("启用", isOn: $source.isEnabled).toggleStyle(.switch)
                }
                TextField("数据源名称", text: $source.name)
                TextField("账号标识", text: $source.accountId)
                TextField("API Key 标识", text: $source.apiKeyIdentity)
                TextField("本地日志路径", text: $source.localLogPath)
                HStack {
                    StatusBadge(status: source.syncStatus)
                    Spacer()
                    Button("刷新此源") { Task { await store.refreshAll() } }
                }
                Text(source.syncStatus.message)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: "Accounts", subtitle: "账号配置与 API Key 脱敏展示；真实密钥写入 macOS Keychain")
            GlassPanel {
                Table(store.sources) {
                    TableColumn("工具") { Text($0.tool.rawValue) }
                    TableColumn("账号") { Text($0.accountId) }
                    TableColumn("API Key 标识") { Text($0.apiKeyIdentity) }
                    TableColumn("Keychain") { _ in Label("本机保存", systemImage: "key.fill").foregroundStyle(Color.neonCyan) }
                }
                .frame(minHeight: 420)
            }
        }
    }
}

struct PricingView: View {
    @EnvironmentObject private var store: UsageStore
    @State private var newTool: ToolKind = .hermes
    @State private var newModel = ""
    @State private var newInputPrice: Decimal = 0
    @State private var newOutputPrice: Decimal = 0
    @State private var newCachePrice: Decimal = 0
    @State private var validationMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: "Pricing", subtitle: "按模型配置输入、输出、缓存 tokens 单价（美元 / 百万 tokens）")
            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    Text("手动添加模型价格")
                        .font(.headline)
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("工具").font(.caption).foregroundStyle(Color.scopeTextMuted)
                            Picker("工具", selection: $newTool) {
                                ForEach(ToolKind.allCases) { tool in
                                    Text(tool.rawValue).tag(tool)
                                }
                            }
                            .frame(width: 150)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("模型名称").font(.caption).foregroundStyle(Color.scopeTextMuted)
                            TextField("例如 gpt-5.5 / claude-opus-4-6", text: $newModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 260)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("输入价").font(.caption).foregroundStyle(Color.scopeTextMuted)
                            DecimalField(value: $newInputPrice).frame(width: 90)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("输出价").font(.caption).foregroundStyle(Color.scopeTextMuted)
                            DecimalField(value: $newOutputPrice).frame(width: 90)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("缓存价").font(.caption).foregroundStyle(Color.scopeTextMuted)
                            DecimalField(value: $newCachePrice).frame(width: 90)
                        }
                        Button {
                            addPricing()
                        } label: {
                            Label("添加 / 更新", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.neonBlue)
                        .disabled(newModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !validationMessage.isEmpty {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(validationMessage.contains("已") ? Color.green : Color.orange)
                    }
                    Text("说明：单价单位为美元 / 百万 tokens。若工具和模型名称与 usage 记录匹配，费用会使用这里的价格重新估算。")
                        .font(.caption)
                        .foregroundStyle(Color.scopeTextMuted)
                }
            }
            GlassPanel {
                Table($store.pricing) {
                    TableColumn("工具") { row in Text(row.wrappedValue.tool.rawValue) }
                    TableColumn("模型") { row in TextField("model", text: row.model) }
                    TableColumn("输入") { row in DecimalField(value: row.inputPerMillion) }
                    TableColumn("输出") { row in DecimalField(value: row.outputPerMillion) }
                    TableColumn("缓存") { row in DecimalField(value: row.cachePerMillion) }
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
            validationMessage = "模型名称不能为空"
            return
        }
        let item = ModelPricing(tool: newTool, model: model, inputPerMillion: newInputPrice, outputPerMillion: newOutputPrice, cachePerMillion: newCachePrice)
        let existed = store.pricing.contains { $0.tool == newTool && $0.model.caseInsensitiveCompare(model) == .orderedSame }
        store.setPricing(item)
        if existed {
            validationMessage = "已更新并保存 \(newTool.rawValue) / \(model) 的价格"
        } else {
            validationMessage = "已添加并保存 \(newTool.rawValue) / \(model) 的价格"
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
    @State private var saveMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderBar(title: "Budgets", subtitle: "每日 / 每周 / 每月 tokens 与费用预算，80% 和 100% 分级提醒")
            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("预算设置")
                            .font(.headline)
                        Spacer()
                        Picker("预算进度计算", selection: $store.budgetProgressMode) {
                            ForEach(BudgetProgressMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    ForEach($store.budgets) { $rule in
                        HStack(spacing: 12) {
                            Text(rule.period.rawValue).font(.headline).frame(width: 70, alignment: .leading)
                            Text("Tokens")
                            TextField("token limit", value: $rule.tokenLimit, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Text("费用")
                            DecimalField(value: $rule.costLimit).frame(width: 120)
                            Button("保存") {
                                store.setBudget(rule)
                                saveMessage = "已保存 \(rule.period.rawValue) 预算"
                            }
                            Spacer()
                        }
                    }
                    HStack {
                        Button {
                            store.saveAllBudgets()
                            saveMessage = "全部预算已保存"
                        } label: {
                            Label("保存全部预算", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.neonBlue)

                        Button {
                            store.budgets = UsageStore.defaultBudgets()
                            store.saveAllBudgets()
                            saveMessage = "已恢复默认预算"
                        } label: {
                            Label("恢复默认", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)

                        if !saveMessage.isEmpty {
                            Text(saveMessage)
                                .font(.caption)
                                .foregroundStyle(Color.green)
                        }
                    }
                    Text("说明：费用预算单位为美元；修改后可单独保存某一周期，也可以保存全部。预算会写入 SQLite，重启后保留。预算进度开关仅控制进度条按 Tokens 或费用计算。")
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
