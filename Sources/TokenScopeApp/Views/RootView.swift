import SwiftUI
import TokenScopeCore

struct RootView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.scopeTheme) private var theme
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
    }

    var body: some View {
        NavigationSplitView {
            ZStack {
                theme.sidebarBackground.ignoresSafeArea()
                List(Section.allCases, selection: $selection) { item in
                    Label(item.rawValue, systemImage: icon(for: item))
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
