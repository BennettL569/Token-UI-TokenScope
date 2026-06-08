import Foundation

public enum WidgetSummaryStore {
    public static let fileName = "WidgetSummary.json"

    public static func defaultURL(appGroupIdentifier: String? = TokenScopeConfiguration.appGroupIdentifier) -> URL {
        if let appGroupIdentifier,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return url.appendingPathComponent(fileName)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenScope", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func save(_ summary: WidgetSummary, to url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: url, options: [.atomic])
    }

    public static func load(from url: URL = defaultURL()) throws -> WidgetSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WidgetSummary.self, from: Data(contentsOf: url))
    }
}
