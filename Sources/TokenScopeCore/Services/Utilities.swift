import CryptoKit
import Foundation

public enum Dedupe {
    public static func makeKey(source: ToolKind, requestId: String?, timestamp: Date, model: String, inputTokens: Int, outputTokens: Int, cacheTokens: Int, rawSource: String) -> String {
        if let requestId, !requestId.isEmpty {
            return "\(source.rawValue)::request::\(requestId)"
        }
        let payload = "\(timestamp.timeIntervalSince1970)|\(model)|\(inputTokens)|\(outputTokens)|\(cacheTokens)|\(source.rawValue)|\(rawSource)"
        return "\(source.rawValue)::fallback::\(sha256(payload))"
    }

    public static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum Masking {
    public static func maskAPIKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: max(4, key.count)) }
        let prefix = key.prefix(3)
        let suffix = key.suffix(4)
        return "\(prefix)-...\(suffix)"
    }
}

public enum DecimalFormatting {
    public static func currency(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value)
        return String(format: "$%.4f", number.doubleValue)
    }
}
