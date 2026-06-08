import SwiftUI
import TokenScopeCore

@main
struct TokenScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        WindowGroup {
            ScopeThemeReader {
                RootView()
                    .environmentObject(store)
                    .frame(minWidth: 1120, minHeight: 720)
                    .task {
                        if store.records.isEmpty { await store.refreshAll() }
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            ScopeThemeReader {
                MenuBarMiniPanel()
                    .environmentObject(store)
            }
        } label: {
            let today = store.dashboardSnapshot.today
            Text(store.menuBarShowsCost ? DecimalFormatting.currency(today.estimatedCost) : "\(today.totalTokens) tok")
        }
    }
}
