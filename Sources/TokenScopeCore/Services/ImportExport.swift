import Foundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv = "CSV"
    case json = "JSON"
    public var id: String { rawValue }
}

public enum ExportService {
    public static func export(records: [UsageRecord], format: ExportFormat, includeIdentifiers: Bool) throws -> String {
        switch format {
        case .json:
            let exportRows = records.map { ExportRow(record: $0, includeIdentifiers: includeIdentifiers) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return String(data: try encoder.encode(exportRows), encoding: .utf8) ?? "[]"
        case .csv:
            let header = "source,accountId,apiKeyHash,model,timestamp,inputTokens,outputTokens,cacheTokens,totalTokens,estimatedCost"
            let formatter = ISO8601DateFormatter()
            let lines = records.map { record in
                [
                    record.source.rawValue,
                    includeIdentifiers ? record.accountId : "redacted",
                    includeIdentifiers ? record.apiKeyHash : "redacted",
                    record.model,
                    formatter.string(from: record.timestamp),
                    String(record.inputTokens),
                    String(record.outputTokens),
                    String(record.cacheTokens),
                    String(record.totalTokens),
                    NSDecimalNumber(decimal: record.estimatedCost).stringValue
                ].map(csvEscape).joined(separator: ",")
            }
            return ([header] + lines).joined(separator: "\n")
        }
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

private struct ExportRow: Codable {
    var source: String
    var accountId: String
    var apiKeyHash: String
    var model: String
    var timestamp: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheTokens: Int
    var totalTokens: Int
    var estimatedCost: Decimal
    var rawSource: String

    init(record: UsageRecord, includeIdentifiers: Bool) {
        self.source = record.source.rawValue
        self.accountId = includeIdentifiers ? record.accountId : "redacted"
        self.apiKeyHash = includeIdentifiers ? record.apiKeyHash : "redacted"
        self.model = record.model
        self.timestamp = record.timestamp
        self.inputTokens = record.inputTokens
        self.outputTokens = record.outputTokens
        self.cacheTokens = record.cacheTokens
        self.totalTokens = record.totalTokens
        self.estimatedCost = record.estimatedCost
        // rawSource holds the full local file path (e.g. /Users/<name>/.claude/projects/…), so it
        // is an identifier: only include it when identifiers are explicitly opted in, otherwise a
        // "redacted" export would still ship the username and filesystem layout.
        self.rawSource = includeIdentifiers ? record.rawSource : "redacted"
    }
}

public enum ImportService {
    public static func importJSON(data: Data) throws -> [UsageRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([UsageRecord].self, from: data)
    }
}
