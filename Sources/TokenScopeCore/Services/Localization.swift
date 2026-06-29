import Foundation

/// UI language for the app. The `rawValue`s are stable preference keys (persisted to
/// `UserDefaults`), not display strings — English is the default.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case chinese = "zh"

    public var id: String { rawValue }

    /// Name of the language in its own language, for the settings picker.
    public var nativeName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }

    /// Picks the English or Chinese variant of a piece of text. English is listed first to
    /// match the default and to keep the source-of-truth string adjacent to its translation.
    public func select(_ english: String, _ chinese: String) -> String {
        switch self {
        case .english: return english
        case .chinese: return chinese
        }
    }
}

// MARK: - Localized display names for the Chinese-keyed enums
//
// These enums persist their Chinese `rawValue`s as SQLite keys, so the raw values must never
// change. `displayName(_:)` provides a localized label without touching the stored key.

public extension TimeRange {
    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .today: return language.select("Today", "今日")
        case .week: return language.select("This Week", "本周")
        case .month: return language.select("This Month", "本月")
        case .all: return language.select("All", "全部")
        }
    }
}

public extension BudgetPeriod {
    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .daily: return language.select("Daily", "每日")
        case .weekly: return language.select("Weekly", "每周")
        case .monthly: return language.select("Monthly", "每月")
        }
    }
}

public extension BudgetProgressMode {
    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .tokens: return language.select("Tokens", "Tokens")
        case .cost: return language.select("Cost", "费用")
        }
    }
}

public extension RefreshInterval {
    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .oneHour: return language.select("1 hour", "1 小时")
        case .thirtyMinutes: return language.select("30 minutes", "30 分钟")
        case .tenMinutes: return language.select("10 minutes", "10 分钟")
        case .fiveMinutes: return language.select("5 minutes", "5 分钟")
        case .oneMinute: return language.select("1 minute", "1 分钟")
        case .thirtySeconds: return language.select("30 seconds", "30 秒")
        case .tenSeconds: return language.select("10 seconds", "10 秒")
        case .fiveSeconds: return language.select("5 seconds", "5 秒")
        case .realtime: return language.select("Real-time", "实时刷新")
        }
    }
}
