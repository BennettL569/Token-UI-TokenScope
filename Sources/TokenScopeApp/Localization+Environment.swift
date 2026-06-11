import SwiftUI
import TokenScopeCore

/// Makes the active `AppLanguage` available to every view (including purely presentational
/// subviews that don't hold the store) via `@Environment(\.appLanguage)`. The root injects the
/// store's current language, so flipping the language in Settings re-renders the whole tree.
private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .english
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}
