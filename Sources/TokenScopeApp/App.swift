import SwiftUI
import TokenScopeCore

@main
struct TokenScopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()
    @StateObject private var updater = UpdateManager()

    var body: some Scene {
        WindowGroup {
            ScopeThemeReader {
                RootView()
                    .environmentObject(store)
                    .environmentObject(updater)
                    .environment(\.appLanguage, store.language)
                    .frame(minWidth: 1120, minHeight: 720)
                    .task {
                        await store.refreshOnLaunch()
                    }
                    .task {
                        // Opt-in only (off by default): a single check on launch, never auto-install.
                        if UserDefaults.standard.bool(forKey: UpdateManager.autoCheckDefaultsKey) {
                            await updater.check()
                        }
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            ScopeThemeReader {
                MenuBarMiniPanel()
                    .environmentObject(store)
                    .environment(\.appLanguage, store.language)
            }
        } label: {
            let today = store.dashboardSnapshot.today
            Text(store.menuBarShowsCost ? DecimalFormatting.currency(today.estimatedCost) : "\(today.totalTokens) tok")
        }
    }
}
