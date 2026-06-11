import SwiftUI
import TokenScopeCore

struct RootView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.scopeTheme) private var theme
    @Environment(\.appLanguage) private var lang
    @State private var selection: Section = .dashboard

    enum Section: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case details = "Usage 明细"
        case sources = "Data Sources"
        case accounts = "Accounts"
        case pricing = "Pricing"
        case budgets = "Budgets"
        case export = "Export"
        case settings = "Settings"
        case widgets = "Widgets"
        var id: String { rawValue }

        func displayName(_ language: AppLanguage) -> String {
            switch self {
            case .dashboard: return language.select("Dashboard", "仪表盘")
            case .details: return language.select("Usage", "用量明细")
            case .sources: return language.select("Data Sources", "数据源")
            case .accounts: return language.select("Accounts", "账号")
            case .pricing: return language.select("Pricing", "定价")
            case .budgets: return language.select("Budgets", "预算")
            case .export: return language.select("Export", "导出")
            case .settings: return language.select("Settings", "设置")
            case .widgets: return language.select("Widgets", "小组件")
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            ZStack {
                theme.sidebarBackground.ignoresSafeArea()
                List(Section.allCases, selection: $selection) { item in
                    Label(item.displayName(lang), systemImage: icon(for: item))
                        .tag(item)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            ZStack {
                theme.backgroundGradient
                    .ignoresSafeArea()
                theme.radialGlow
                    .ignoresSafeArea()
                selectedView
                    .padding(22)
            }
        }

    }

    @ViewBuilder private var selectedView: some View {
        switch selection {
        case .dashboard: DashboardView()
        case .details: UsageDetailView()
        case .sources: DataSourcesView()
        case .accounts: AccountsView()
        case .pricing: PricingView()
        case .budgets: BudgetsView()
        case .export: ExportView()
        case .settings: SettingsView()
        case .widgets: WidgetGuideView()
        }
    }

    private func icon(for section: Section) -> String {
        switch section {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .details: "tablecells"
        case .sources: "externaldrive.connected.to.line.below"
        case .accounts: "person.crop.circle.fill.badge.checkmark"
        case .pricing: "dollarsign.circle"
        case .budgets: "speedometer"
        case .export: "square.and.arrow.up"
        case .settings: "gearshape"
        case .widgets: "rectangle.grid.2x2"
        }
    }
}
