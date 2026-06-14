import Foundation

public enum LocalUsageParser {
    public static func parseClaudeLine(_ line: String, filePath: String, pricing: [ModelPricing]) -> UsageRecord? {
        // Cheap substring gate before the expensive JSON parse: a usage-bearing line is an
        // assistant message and always contains both markers, so anything missing them cannot
        // produce a record. This skips full JSONSerialization on the bulk of the log.
        guard line.contains("assistant"), line.contains("usage") else { return nil }
        guard let object = parseJSONObject(line),
              string(object["type"]) == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }
        let input = int(usage["input_tokens"])
        let output = int(usage["output_tokens"])
        let cacheCreation = int(usage["cache_creation_input_tokens"])
        let cacheRead = int(usage["cache_read_input_tokens"])
        let cacheCreationDetail = usage["cache_creation"] as? [String: Any]
        let cacheDetailSum = int(cacheCreationDetail?["ephemeral_1h_input_tokens"]) + int(cacheCreationDetail?["ephemeral_5m_input_tokens"])
        // `cache_creation_input_tokens` is the canonical cache-creation total; the
        // `cache_creation.ephemeral_*` fields are a breakdown that sums to that same value.
        // Adding both double-counts cache (and inflates total), so use the breakdown only as a
        // fallback when the canonical field is absent.
        let cacheCreationTotal = cacheCreation > 0 ? cacheCreation : cacheDetailSum
        let cache = cacheCreationTotal + cacheRead
        guard input + output + cache > 0 else { return nil }
        let timestamp = parseDate(string(object["timestamp"])) ?? Date()
        let model = string(message["model"]) ?? "unknown"
        let requestId = string(message["id"]) ?? string(object["uuid"])
        var record = UsageRecord(source: .claudeCode, accountId: "ClaudeCode Local", apiKeyHash: "local-claude-code", model: model, timestamp: timestamp, inputTokens: input, outputTokens: output, cacheTokens: cache, cacheCreationTokens: cacheCreationTotal, requestId: requestId, rawSource: filePath)
        record.estimatedCost = PricingEngine.estimate(record: record, pricing: pricing)
        return record
    }

    /// Codex usage events carry no model name — the active model is announced once per turn in a
    /// preceding `turn_context` event. The Codex adapter tracks the most recent one and threads it
    /// in via `model`; `nil` falls back to `"codex"`. An incremental read that resumes mid-turn
    /// (past this turn's `turn_context`) recovers the model from the persisted cursor instead, so
    /// the fallback is reached only when no model has ever been seen for the file. Returns the model
    /// for a `turn_context` line, else `nil`, so the adapter can use it as both a model-state
    /// updater and a cheap "is this a turn_context" gate.
    public static func codexModel(fromLine line: String) -> String? {
        guard line.contains("turn_context") else { return nil }
        guard let object = parseJSONObject(line),
              string(object["type"]) == "turn_context",
              let payload = object["payload"] as? [String: Any] else { return nil }
        return string(payload["model"])
    }

    public static func parseCodexLine(_ line: String, filePath: String, pricing: [ModelPricing], model: String? = nil) -> UsageRecord? {
        // Cheap substring gate: only `token_count` events carry usage, and they are a small
        // fraction of the (very large) Codex rollout logs. Skipping the JSON parse for every
        // other line is the single biggest win when rescanning gigabytes of sessions.
        guard line.contains("token_count") else { return nil }
        guard let object = parseJSONObject(line),
              string(object["type"]) == "event_msg",
              let payload = object["payload"] as? [String: Any],
              string(payload["type"]) == "token_count",
              let info = payload["info"] as? [String: Any] else { return nil }
        // Use the per-event delta only. `total_token_usage` is the session-running cumulative
        // counter; treating it as one request's usage — and re-adding it on every later event —
        // would inflate Codex totals by orders of magnitude, so skip events that lack a per-event
        // `last_token_usage` rather than falling back to the cumulative total.
        guard let usage = info["last_token_usage"] as? [String: Any] else { return nil }
        // Codex follows OpenAI accounting where `total_tokens == input_tokens + output_tokens`:
        //  • `cached_input_tokens` is a SUBSET of `input_tokens` (cache reads), and
        //  • `reasoning_output_tokens` is a SUBSET of `output_tokens`.
        // The app models input/output/cache as disjoint buckets that sum to the total, so split
        // cached tokens out of the input and keep output as-is (it already includes reasoning).
        // Adding them on top — as before — double-counted cache and reasoning.
        let cache = int(usage["cached_input_tokens"])
        let input = max(0, int(usage["input_tokens"]) - cache)
        let output = int(usage["output_tokens"])
        guard input + output + cache > 0 else { return nil }
        let timestamp = parseDate(string(object["timestamp"])) ?? Date()
        let resolvedModel = model ?? "codex"
        var record = UsageRecord(source: .codeX, accountId: "Codex Local", apiKeyHash: "local-codex", model: resolvedModel, timestamp: timestamp, inputTokens: input, outputTokens: output, cacheTokens: cache, requestId: "\(filePath)#\(timestamp.timeIntervalSince1970)#\(input)#\(output)#\(cache)", rawSource: filePath)
        record.estimatedCost = PricingEngine.estimate(record: record, pricing: pricing)
        return record
    }

    public static func parseOpenClawLine(_ line: String, filePath: String, pricing: [ModelPricing]) -> UsageRecord? {
        // Cheap substring gate before the full JSON parse: a record always comes from a line
        // carrying a `usage` object (directly or inside `messagesSnapshot`).
        guard line.contains("usage") else { return nil }
        guard let object = parseJSONObject(line) else { return nil }
        var message = object["message"] as? [String: Any]
        if message == nil, let data = object["data"] as? [String: Any], let snapshot = data["messagesSnapshot"] as? [[String: Any]] {
            message = snapshot.last { $0["usage"] != nil }
        }
        guard let message, let usage = message["usage"] as? [String: Any] else { return nil }
        let input = int(usage["input"])
        let output = int(usage["output"])
        let cacheWrite = int(usage["cacheWrite"])
        let cache = int(usage["cacheRead"]) + cacheWrite
        guard input + output + cache > 0 else { return nil }
        let timestamp = parseDate(string(object["timestamp"]) ?? string(object["ts"])) ?? Date(timeIntervalSince1970: Double(int(message["timestamp"])) / 1000.0)
        let model = string(message["model"]) ?? string(object["modelId"]) ?? "openclaw"
        var record = UsageRecord(source: .openClaw, accountId: string(object["sessionKey"]) ?? "OpenClaw Local", apiKeyHash: string(message["provider"]) ?? string(object["provider"]) ?? "local-openclaw", model: model, timestamp: timestamp, inputTokens: input, outputTokens: output, cacheTokens: cache, cacheCreationTokens: cacheWrite, requestId: string(object["id"]) ?? string(object["runId"]), rawSource: filePath)
        if let cost = usage["cost"] as? [String: Any], let total = decimal(cost["total"]) { record.estimatedCost = total } else { record.estimatedCost = PricingEngine.estimate(record: record, pricing: pricing) }
        return record
    }

    public static func parseHermesSessionRow(id: String, source: String?, userId: String?, model: String?, activityAt: Double, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, cost: Double?, provider: String?, pricing: [ModelPricing]) -> UsageRecord? {
        let outputWithReasoning = output + reasoning
        let cache = cacheRead + cacheWrite
        guard input + outputWithReasoning + cache > 0 else { return nil }
        var record = UsageRecord(source: .hermes, accountId: userId ?? source ?? "Hermes Local", apiKeyHash: provider ?? "local-hermes", model: model ?? "unknown", timestamp: Date(timeIntervalSince1970: activityAt), inputTokens: input, outputTokens: outputWithReasoning, cacheTokens: cache, cacheCreationTokens: cacheWrite, estimatedCost: cost.map { Decimal($0) } ?? 0, requestId: id, rawSource: "~/.hermes/state.db:sessions")
        if record.estimatedCost == 0 { record.estimatedCost = PricingEngine.estimate(record: record, pricing: pricing) }
        return record
    }

    public static func parseOpenCodeMessageRow(id: String, sessionId: String, timeCreated: Double, data: String, rawSource: String, pricing: [ModelPricing]) -> UsageRecord? {
        guard let object = parseJSONObject(data) else { return nil }
        let usage = firstUsageDictionary(in: object)
        let input = intFromKeys(usage, ["inputTokens", "input_tokens", "promptTokens", "prompt_tokens", "input"])
        let output = intFromKeys(usage, ["outputTokens", "output_tokens", "completionTokens", "completion_tokens", "output"])
            + intFromKeys(usage, ["reasoningTokens", "reasoning_tokens", "reasoningOutputTokens", "reasoning_output_tokens", "reasoning"])
        let cacheDict = usage["cache"] as? [String: Any]
        let cacheRead = intFromKeys(usage, ["cacheReadTokens", "cache_read_tokens", "cachedInputTokens", "cached_input_tokens", "cacheRead"])
            + intFromKeys(cacheDict ?? [:], ["read", "cacheRead", "cache_read_tokens", "cachedInputTokens", "cached_input_tokens"])
        let cacheWrite = intFromKeys(usage, ["cacheWriteTokens", "cache_write_tokens", "cacheCreationInputTokens", "cache_creation_input_tokens", "cacheWrite"])
            + intFromKeys(cacheDict ?? [:], ["write", "cacheWrite", "cache_write_tokens", "cacheCreationInputTokens", "cache_creation_input_tokens"])
        let cache = cacheRead + cacheWrite
        let cacheCreation = cacheWrite
        guard input + output + cache > 0 else { return nil }
        let provider = stringFromKeys(object, ["provider", "providerID", "providerId"])
            ?? stringFromKeys(usage, ["provider", "providerID", "providerId"])
        let model = stringFromKeys(object, ["model", "modelID", "modelId"])
            ?? stringFromKeys(usage, ["model", "modelID", "modelId"])
            ?? "opencode"
        let timestamp = parseDate(stringFromKeys(object, ["timeCreated", "time_created", "timestamp", "createdAt"]))
            ?? Date(timeIntervalSince1970: normalizedEpoch(timeCreated))
        let requestId = stringFromKeys(object, ["id", "requestId", "request_id"]) ?? id
        var record = UsageRecord(source: .openCode, accountId: sessionId, apiKeyHash: provider ?? "local-opencode", model: model, timestamp: timestamp, inputTokens: input, outputTokens: output, cacheTokens: cache, cacheCreationTokens: cacheCreation, requestId: requestId, rawSource: rawSource)
        if let cost = decimalFromKeys(usage, ["cost", "costUSD", "cost_usd", "estimatedCost", "estimated_cost"]) {
            record.estimatedCost = cost
        } else {
            record.estimatedCost = PricingEngine.estimate(record: record, pricing: pricing)
        }
        return record
    }

    private static func parseJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        return nil
    }

    static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    static func decimal(_ value: Any?) -> Decimal? {
        if let value = value as? Double { return Decimal(value) }
        if let value = value as? Int { return Decimal(value) }
        if let value = value as? String { return Decimal(string: value) }
        return nil
    }

    // ISO8601DateFormatter is very expensive to allocate and is thread-safe for parsing, so the
    // two configurations are created once and reused. Allocating a formatter per line (the
    // previous behaviour) dominated CPU time when scanning gigabytes of JSONL.
    // Configured once and only ever read from (`date(from:)`), which is thread-safe; the
    // `nonisolated(unsafe)` annotation vouches for that under Swift 6 strict concurrency.
    nonisolated(unsafe) private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let isoPlainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = isoFractionalFormatter.date(from: value) { return date }
        return isoPlainFormatter.date(from: value)
    }

    private static func normalizedEpoch(_ value: Double) -> Double {
        value > 10_000_000_000 ? value / 1000.0 : value
    }

    private static func firstUsageDictionary(in value: Any?) -> [String: Any] {
        if let dict = value as? [String: Any] {
            for key in ["usage", "tokens", "tokenUsage", "token_usage", "cost"] {
                if let usage = dict[key] as? [String: Any] { return usage }
            }
            for nested in dict.values {
                let found = firstUsageDictionary(in: nested)
                if !found.isEmpty { return found }
            }
        } else if let array = value as? [Any] {
            for item in array {
                let found = firstUsageDictionary(in: item)
                if !found.isEmpty { return found }
            }
        }
        return [:]
    }

    private static func intFromKeys(_ dict: [String: Any], _ keys: [String]) -> Int {
        for key in keys {
            let value = int(dict[key])
            if value != 0 { return value }
        }
        return 0
    }

    private static func decimalFromKeys(_ dict: [String: Any], _ keys: [String]) -> Decimal? {
        for key in keys {
            if let value = decimal(dict[key]) { return value }
        }
        return nil
    }

    private static func stringFromKeys(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = string(dict[key]) { return value }
        }
        return nil
    }

}

public struct LocalJSONLUsageAdapter: UsageAdapter {
    /// Per-file state threaded through the parser so formats whose usage lines don't carry every
    /// field can recover it from an earlier line. Codex is the motivating case: a `token_count`
    /// event names no model — it's announced once per turn in a preceding `turn_context` line —
    /// so the adapter remembers the latest `model` here. Reset to empty at the start of each file.
    public struct LineContext: Sendable {
        public var model: String?
        public init() {}
    }
    public typealias StatefulParser = @Sendable (_ line: String, _ filePath: String, _ pricing: [ModelPricing], _ context: inout LineContext) -> UsageRecord?

    public let id: String
    public let tool: ToolKind
    public let displayName: String
    public let capabilities: AdapterCapabilities = [.supportsLocalLogs, .supportsImport, .supportsCostEstimation]
    private let defaultGlobPatterns: [String]
    private let parser: StatefulParser

    /// Stateless parser (one line → at most one record); for formats that name everything on each
    /// usage line, e.g. Claude and OpenClaw.
    public init(tool: ToolKind, displayName: String, defaultGlobPatterns: [String], parser: @escaping @Sendable (String, String, [ModelPricing]) -> UsageRecord?) {
        self.init(tool: tool, displayName: displayName, defaultGlobPatterns: defaultGlobPatterns) { line, path, pricing, _ in
            parser(line, path, pricing)
        }
    }

    /// Stateful parser that may read and update per-file `LineContext` (e.g. Codex model tracking).
    public init(tool: ToolKind, displayName: String, defaultGlobPatterns: [String], statefulParser: @escaping StatefulParser) {
        self.id = tool.rawValue.lowercased() + "-local-jsonl"
        self.tool = tool
        self.displayName = displayName
        self.defaultGlobPatterns = defaultGlobPatterns
        self.parser = statefulParser
    }

    public func refresh(source: UsageSource, pricing: [ModelPricing], cursorStore: UsageCursorStore? = nil, fullScan: Bool = false) async throws -> [UsageRecord] {
        guard source.isEnabled else { throw AdapterError.sourceDisabled }
        let paths = FileDiscovery.expand(paths: source.localLogPath.isEmpty ? defaultGlobPatterns : [source.localLogPath])
        var records: [UsageRecord] = []
        for path in paths {
            guard let stream = InputStream(fileAtPath: path) else { continue }
            stream.open()
            defer { stream.close() }
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            let rawCursor = fullScan ? 0 : Int64(cursorStore?.refreshCursor(source: tool, rawSource: path) ?? 0)
            let startOffset = max(0, min(rawCursor, fileSize))
            if startOffset > 0 { skipBytes(startOffset, in: stream) }
            let reader = LineReader(stream: stream)
            var context = LineContext()
            // Resume the model a previous pass established, so an incremental read that starts
            // mid-turn (past this turn's `turn_context`) keeps the real model instead of falling
            // back to "codex". Harmless for stateless formats — their context.model stays nil.
            if startOffset > 0 { context.model = cursorStore?.refreshCursorModel(source: tool, rawSource: path) }
            while let line = reader.nextLine() {
                if let record = parser(line, path, pricing, &context) { records.append(record) }
            }
            cursorStore?.setRefreshCursor(source: tool, rawSource: path, position: Double(fileSize), model: context.model)
        }
        return records
    }

    private func skipBytes(_ count: Int64, in stream: InputStream) {
        guard count > 0 else { return }
        var remaining = count
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let toRead = min(chunk.count, Int(remaining))
            let read = stream.read(&chunk, maxLength: toRead)
            if read <= 0 { break }
            remaining -= Int64(read)
        }
    }
}

public enum FileDiscovery {
    public static func expand(paths: [String]) -> [String] {
        var results: [String] = []
        let maxFilesPerPattern = 10_000
        for raw in paths {
            let expanded = NSString(string: raw).expandingTildeInPath
            if let globbed = expandGlob(expanded, limit: maxFilesPerPattern) {
                results.append(contentsOf: globbed)
                continue
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                results.append(contentsOf: enumerateFiles(root: expanded, limit: maxFilesPerPattern))
            } else {
                results.append(expanded)
            }
        }
        return Array(Set(results)).filter { FileManager.default.fileExists(atPath: $0) }.sorted()
    }

    private static func expandGlob(_ pattern: String, limit: Int) -> [String]? {
        if let recursiveRange = pattern.range(of: "/**/") {
            let root = String(pattern[..<recursiveRange.lowerBound])
            let suffix = String(pattern[recursiveRange.upperBound...])
            guard suffix.hasPrefix("*.") else { return nil }
            let ext = String(suffix.dropFirst(1))
            return enumerateFiles(root: root, extensions: [ext], limit: limit)
        }
        guard pattern.contains("*") else { return nil }
        let ns = pattern as NSString
        let dir = ns.deletingLastPathComponent
        let last = ns.lastPathComponent
        guard last.hasPrefix("*.") else { return nil }
        let ext = String(last.dropFirst(1))
        return enumerateFiles(root: dir, extensions: [ext], limit: limit, recursive: false)
    }

    private static func enumerateFiles(root: String, extensions: [String] = [".jsonl", ".json", ".db", ".sqlite", ".sqlite3"], limit: Int, recursive: Bool = true) -> [String] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        var results: [String] = []
        // Collect past `limit` (bounded against a pathological tree) so that, when truncating, we
        // can keep the newest files instead of whichever the enumerator happened to yield first.
        let hardCap = max(limit * 4, 40_000)
        if recursive {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
            for case let file as String in enumerator {
                if extensions.contains(where: { file.hasSuffix($0) }) {
                    results.append((root as NSString).appendingPathComponent(file))
                    if results.count >= hardCap { break }
                }
            }
        } else if let files = try? FileManager.default.contentsOfDirectory(atPath: root) {
            for file in files where extensions.contains(where: { file.hasSuffix($0) }) {
                results.append((root as NSString).appendingPathComponent(file))
                if results.count >= hardCap { break }
            }
        }
        if results.count > limit {
            // Keep the most recently modified files; truncating in enumerator order could silently
            // drop the newest sessions and under-count recent usage.
            results = results
                .map { (path: $0, modified: modificationDate($0)) }
                .sorted { $0.modified > $1.modified }
                .prefix(limit)
                .map(\.path)
        }
        return results.sorted()
    }

    private static func modificationDate(_ path: String) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }
}

final class LineReader {
    private let stream: InputStream
    private var buffer = Data()
    private var eof = false

    init(stream: InputStream) { self.stream = stream }

    func nextLine() -> String? {
        while true {
            if let range = buffer.firstRange(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: 0..<range.lowerBound)
                buffer.removeSubrange(0..<range.upperBound)
                return String(data: lineData, encoding: .utf8)
            }
            if eof {
                if buffer.isEmpty { return nil }
                let line = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let read = stream.read(&chunk, maxLength: chunk.count)
            if read > 0 {
                buffer.append(chunk, count: read)
            } else {
                eof = true
            }
        }
    }
}
