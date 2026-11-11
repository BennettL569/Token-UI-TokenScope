import Foundation

/// Reads DeepSeek Harness (DSH), DeepSeek's desktop / CLI coding agent.
///
/// DSH keeps one append-only event log per session under `$DSH_HOME/sessions` (default
/// `~/.dsh/sessions`): `<root>/--<project>--/<session-id>/session.v4.jsonl.zstd`, a concatenation of
/// independent, checksummed zstd frames — one holding the header line, then one per durable append
/// batch, each ending on a complete line — or plain `session.vN.jsonl` when compression is off.
/// Every LLM request it makes settles as one event:
///  • `assistant/message` — a successful attempt. Usage is `data.usage` (the same sample as the last
///    `usage` chunk of `data.stream`), the route is `data.message.source.{provider,model}`, and
///    `data.message.id` is a UUID that survives DSH's format migrations.
///  • `assistant/attempt` — a failed, retried or aborted attempt: a separately billed request. Its
///    usage is only the last `usage` chunk of its stream (often all zeros, e.g. a 429, and then
///    skipped). It names no model, so the route comes from the latest `request/context` or
///    `request/header` before it.
///  • `compaction/summary` — a context-compaction call with its own `data.usage` (DSH's own token
///    meter leaves these out).
/// `inputTokens` is already the uncached input (DSH's adapters subtract cache reads) and reasoning is
/// inside `outputTokens`, so the counts map straight onto TokenScope's disjoint buckets. No event
/// records money, so cost is always estimated. Title, web-search and translator calls persist no
/// usage at all and cannot be counted.
///
/// Three things would double count if read naively:
///  • DSH keeps older format generations (`session.v3.jsonl.zstd`, …) byte-identical next to the
///    migrated file. Only the highest generation in a session directory is read.
///  • A forked session (`isSeeded` header) physically copies its parent's events, usage included,
///    up to a `session/end-seed {"inherited":true}` marker. Events before the LAST such marker (a fork
///    of a fork carries its ancestor's marker too) belong to the parent and are skipped. Their ids
///    equal the parent's as well, so even a missed cut collapses onto the parent's records.
///  • Format migrations renumber `seq`, so records are keyed by message / compaction ids, never by
///    `seq` or byte offsets.
///
/// Incremental sync keeps a byte cursor at the end of the last complete frame. A frame still being
/// written — or a torn tail after a crash, which DSH later truncates and rewrites in place — is left
/// for the next pass. The cursor also carries the current route, so a resumed read can attribute an
/// `assistant/attempt` whose `request/context` came before the cursor.
public struct DeepSeekHarnessUsageAdapter: UsageAdapter {
    public let id = "deepseekharness-local-sessions"
    public let tool: ToolKind = .deepSeekHarness
    public let displayName = "DeepSeek Harness Sessions"
    public let capabilities: AdapterCapabilities = [.supportsLocalLogs, .supportsImport, .supportsCostEstimation]
    private let defaultRoots: [String]

    public init(defaultRoots: [String] = DeepSeekHarnessUsageAdapter.defaultRoots()) {
        self.defaultRoots = defaultRoots
    }

    /// `$DSH_HOME/sessions` when that is set (the `dsh` CLI honours it), plus the default
    /// `~/.dsh/sessions` the desktop app always uses.
    public static func defaultRoots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var roots: [String] = []
        if let home = environment["DSH_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            roots.append(((home as NSString).expandingTildeInPath as NSString).appendingPathComponent("sessions"))
        }
        roots.append("~/.dsh/sessions")
        return roots
    }

    public func refresh(source: UsageSource, pricing: [ModelPricing], cursorStore: UsageCursorStore? = nil, fullScan: Bool = false) async throws -> [UsageRecord] {
        try await scan(source: source, pricing: pricing, cursorStore: cursorStore, fullScan: fullScan).records
    }

    public func scan(source: UsageSource, pricing: [ModelPricing], cursorStore: UsageCursorStore?, fullScan: Bool) async throws -> AdapterScanResult {
        guard source.isEnabled else { throw AdapterError.sourceDisabled }
        let logs = Self.discoverLogs(roots: source.localLogPath.isEmpty ? defaultRoots : [source.localLogPath])
        var records: [UsageRecord] = []
        var fullyReadFiles: [String: Int64] = [:]
        for log in logs where log.generation >= Self.minimumGeneration {
            let result = read(log, pricing: pricing, cursorStore: cursorStore, fullScan: fullScan)
            records.append(contentsOf: result.records)
            if let bytes = result.fullyReadBytes { fullyReadFiles[log.path] = bytes }
        }
        return AdapterScanResult(records: records, fullyReadFiles: fullyReadFiles)
    }

    // MARK: - Discovery

    /// One session's log: the file path, its format generation and whether it is zstd-compressed.
    public struct SessionLog: Equatable, Sendable {
        public var path: String
        public var generation: Int
        public var compressed: Bool
    }

    /// v0/v1 were pre-release formats with chunk-per-event assistant streams; DSH migrates them to the
    /// current format the next time the session is opened for writing.
    static let minimumGeneration = 2

    /// `session.jsonl[.zstd]` is generation 0 and `session.vN.jsonl[.zstd]` generation N. Anything
    /// else in a session directory — `session.lock`, temp and migration files — is not a log.
    public static func generation(ofFileName name: String) -> (generation: Int, compressed: Bool)? {
        var base = Substring(name)
        let compressed = base.hasSuffix(".zstd")
        if compressed { base = base.dropLast(5) }
        guard base.hasPrefix("session"), base.hasSuffix(".jsonl"), base.count >= 13 else { return nil }
        let middle = base.dropFirst(7).dropLast(6)
        if middle.isEmpty { return (0, compressed) }
        guard middle.hasPrefix(".v") else { return nil }
        let digits = middle.dropFirst(2)
        guard let first = digits.first, first != "0", digits.count <= 9,
              digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), let generation = Int(digits) else { return nil }
        return (generation, compressed)
    }

    /// The newest-generation log of every session under `roots`. A root may be the sessions root, a
    /// project directory, a session directory, or a log file itself.
    public static func discoverLogs(roots: [String]) -> [SessionLog] {
        let fileManager = FileManager.default
        var found: [String: SessionLog] = [:]
        for raw in roots {
            let root = (raw as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if let parsed = generation(ofFileName: (root as NSString).lastPathComponent) {
                    found[root] = SessionLog(path: root, generation: parsed.generation, compressed: parsed.compressed)
                }
                continue
            }
            // sessions root → project directories → session directories.
            var frontier = [root]
            for depth in 0...2 {
                var next: [String] = []
                for directory in frontier {
                    guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
                    if let log = newestLog(in: directory, names: names) {
                        found[log.path] = log
                        continue
                    }
                    guard depth < 2 else { continue }
                    for name in names where !name.hasPrefix(".") {
                        let path = (directory as NSString).appendingPathComponent(name)
                        var childIsDirectory: ObjCBool = false
                        if fileManager.fileExists(atPath: path, isDirectory: &childIsDirectory), childIsDirectory.boolValue {
                            next.append(path)
                        }
                    }
                }
                frontier = next
            }
        }
        return found.values.sorted { $0.path < $1.path }
    }

    private static func newestLog(in directory: String, names: [String]) -> SessionLog? {
        var best: SessionLog?
        for name in names {
            guard let parsed = generation(ofFileName: name) else { continue }
            let candidate = SessionLog(path: (directory as NSString).appendingPathComponent(name), generation: parsed.generation, compressed: parsed.compressed)
            // Highest generation wins; DSH never mixes encodings in one root, but prefer zstd if so.
            if let current = best, (current.generation, current.compressed ? 1 : 0) >= (candidate.generation, candidate.compressed ? 1 : 0) { continue }
            best = candidate
        }
        return best
    }

    // MARK: - Reading one log

    private struct LogResult {
        var records: [UsageRecord] = []
        /// Bytes read from the start of the file when this pass read every complete record in it.
        var fullyReadBytes: Int64?
    }

    private func read(_ log: SessionLog, pricing: [ModelPricing], cursorStore: UsageCursorStore?, fullScan: Bool) -> LogResult {
        let size = Self.fileSize(log.path)
        guard size > 0 else { return LogResult() }
        var start = fullScan ? 0 : Int64(cursorStore?.refreshCursor(source: tool, rawSource: log.path) ?? 0)
        // A log shorter than the cursor was cut back — a torn tail DSH truncated, or a rolled-back
        // append — so read it again from the top; records are keyed by stable ids, so re-reading is
        // harmless.
        if start < 0 || start > size { start = 0 }
        if !fullScan, start > 0, start == size { return LogResult() }

        guard var bytes = Self.readBytes(log.path, from: start) else { return LogResult() }
        var chunk = Self.completeRecords(bytes, compressed: log.compressed, fileOffset: start)
        if chunk.misaligned {
            // No frame starts at the cursor: the file was replaced. Read it from the top.
            let previousCursor = start
            start = 0
            guard let whole = Self.readBytes(log.path, from: 0) else { return LogResult() }
            bytes = whole
            chunk = Self.completeRecords(bytes, compressed: log.compressed, fileOffset: 0)
            // It still decodes up to exactly the old cursor and stops there: the log is unchanged and
            // only junk follows (DeepSeek Harness refuses such a log and never appends again). Its
            // records were read already, so don't re-emit the whole log on every pass.
            if chunk.end == previousCursor { return LogResult() }
        }
        bytes = []

        let lines = Self.lineRanges(chunk.content)
        let header: [String: Any]?
        if start == 0 {
            header = lines.first.flatMap { Self.jsonObject(chunk.content[$0]) }
        } else {
            header = Self.readHeader(log)
        }
        guard let header, LocalUsageParser.string(header["type"]) == "session" else { return LogResult() }
        let sessionId = LocalUsageParser.string(header["id"]) ?? ((log.path as NSString).deletingLastPathComponent as NSString).lastPathComponent

        var state = DeepSeekHarnessParseState()
        if start > 0 {
            state.restoreRoute(cursorStore?.refreshCursorModel(source: tool, rawSource: log.path))
        } else if header["isSeeded"] as? Bool == true {
            // A fork: everything before the last inherited-seed marker is the parent's. The seed is
            // published with the header in one atomic write, so it is complete once the file exists;
            // without a marker, leave the cursor alone and look again next pass.
            guard let cut = Self.inheritedPrefixEnd(lines: lines, content: chunk.content) else { return LogResult() }
            state.ownFromSeq = cut
        }
        // Once a fork's cut has been passed, a resumed read starts beyond it: DSH never appends another
        // inherited marker to a live session, so everything after the cursor is the fork's own.

        var result = LogResult()
        for range in lines {
            if let record = Self.parseEvent(chunk.content[range], sessionId: sessionId, state: &state, pricing: pricing, rawSource: log.path) {
                result.records.append(record)
            }
        }
        cursorStore?.setRefreshCursor(source: tool, rawSource: log.path, position: Double(chunk.end), model: state.encodedRoute)
        if start == 0, !chunk.damaged { result.fullyReadBytes = chunk.end }
        return result
    }

    /// Decoded JSONL from one read, cut back to whole records.
    struct CompleteRecords {
        /// Decoded lines, each ending in a newline.
        var content: [UInt8]
        /// File offset just past the bytes `content` came from: the next cursor.
        var end: Int64
        /// A complete frame failed to decode; reading stopped before it.
        var damaged = false
        /// The bytes don't start with a frame — the cursor no longer points at a frame boundary.
        var misaligned = false
    }

    /// The complete records in `bytes`, which is the log from `fileOffset` on: everything up to the end
    /// of the last complete frame whose content ends a line (or, uncompressed, the last newline). A
    /// trailing frame that is still being written is left for the next pass.
    static func completeRecords(_ bytes: [UInt8], compressed: Bool, fileOffset: Int64) -> CompleteRecords {
        guard compressed else {
            guard let lastNewline = bytes.lastIndex(of: 0x0A) else { return CompleteRecords(content: [], end: fileOffset) }
            return CompleteRecords(content: Array(bytes[...lastNewline]), end: fileOffset + Int64(lastNewline + 1))
        }
        // Fewer than 4 bytes can't hold a frame magic: a frame whose first bytes are still being
        // written (or a tiny torn tail), not a sign the cursor is off.
        guard bytes.count >= 4 else { return CompleteRecords(content: [], end: fileOffset) }
        guard Zstd.hasFrameMagic(bytes, at: 0) else {
            return CompleteRecords(content: [], end: fileOffset, misaligned: true)
        }
        var content: [UInt8] = []
        var committedLength = 0
        var committedEnd = 0
        var damaged = false
        var position = 0
        while position < bytes.count {
            do {
                let frame = try Zstd.decodeFrame(bytes, at: position)
                if let decoded = frame.content { content.append(contentsOf: decoded) }
                position = frame.end
            } catch Zstd.DecodeError.truncated {
                break
            } catch {
                // A complete frame that doesn't decode. DeepSeek Harness itself refuses such a log and
                // never appends to it again, so stop here and keep the cursor before it.
                damaged = true
                break
            }
            if content.count == committedLength || content.last == 0x0A {
                committedLength = content.count
                committedEnd = position
            }
        }
        content.removeSubrange(committedLength...)
        return CompleteRecords(content: content, end: fileOffset + Int64(committedEnd), damaged: damaged)
    }

    // MARK: - Events

    /// Parses one log line (exposed for tests); see `parseEvent(_:sessionId:state:pricing:rawSource:)`
    /// on bytes.
    public static func parseEvent(_ line: String, sessionId: String, state: inout DeepSeekHarnessParseState, pricing: [ModelPricing], rawSource: String) -> UsageRecord? {
        parseEvent(ArraySlice(Array(line.utf8)), sessionId: sessionId, state: &state, pricing: pricing, rawSource: rawSource)
    }

    private static let routeTypes: Set<String> = ["request/context", "request/header"]
    private static let usageTypes: Set<String> = ["assistant/message", "assistant/attempt", "compaction/summary"]

    /// One usage record for a usage-bearing event with non-zero usage; `request/context` and
    /// `request/header` only update the route in `state`; every other line is skipped unparsed.
    static func parseEvent(_ line: ArraySlice<UInt8>, sessionId: String, state: inout DeepSeekHarnessParseState, pricing: [ModelPricing], rawSource: String) -> UsageRecord? {
        if let type = fastEventType(line), !routeTypes.contains(type), !usageTypes.contains(type) { return nil }
        guard let object = jsonObject(line), let type = LocalUsageParser.string(object["type"]) else { return nil }
        let data = object["data"] as? [String: Any] ?? [:]

        switch type {
        case "request/context":
            state.updateRoute(provider: LocalUsageParser.string(data["provider"]), model: LocalUsageParser.string(data["model"]))
            return nil
        case "request/header":
            let config = (data["header"] as? [String: Any])?["config"] as? [String: Any] ?? [:]
            state.updateRoute(provider: LocalUsageParser.string(config["provider"]), model: LocalUsageParser.string(config["model"]))
            return nil
        default:
            guard usageTypes.contains(type) else { return nil }
        }

        // A fork's copy of its parent's events.
        if let seq = object["seq"] as? NSNumber, seq.intValue < state.ownFromSeq { return nil }

        let usage: [String: Any]?
        var provider = state.provider
        var model = state.model
        var requestId: String?
        switch type {
        case "assistant/message":
            usage = data["usage"] as? [String: Any] ?? lastUsageChunk(data["stream"])
            let message = data["message"] as? [String: Any] ?? [:]
            let source = message["source"] as? [String: Any] ?? [:]
            provider = LocalUsageParser.string(source["provider"]) ?? provider
            model = LocalUsageParser.string(source["model"]) ?? model
            requestId = LocalUsageParser.string(message["id"]).map { "message:\($0)" }
        case "assistant/attempt":
            usage = lastUsageChunk(data["stream"])
        default: // compaction/summary
            usage = data["usage"] as? [String: Any]
            provider = LocalUsageParser.string(data["provider"]) ?? provider
            model = LocalUsageParser.string(data["model"]) ?? model
            requestId = LocalUsageParser.string(data["compactionId"]).map { "compaction:\($0)" }
        }
        guard let usage else { return nil }
        let input = count(usage["inputTokens"])
        let output = count(usage["outputTokens"])
        let cacheRead = count(usage["cacheReadTokens"])
        let cacheWrite = count(usage["cacheWriteTokens"])
        guard input + output + cacheRead + cacheWrite > 0 else { return nil }

        // Epoch milliseconds; anything outside 1970…year 33658 is not a real time.
        let milliseconds = ((object["time"] as? NSNumber)?.doubleValue).flatMap { $0.isFinite && $0 >= 0 && $0 < 1e15 ? $0 : nil }
        let timestamp = milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let turn = count(data["turn"])
        let step = count(data["step"])
        let time = milliseconds.map { String(Int64($0)) } ?? "?"
        if requestId == nil {
            if type == "assistant/attempt" {
                // Attempts carry no id. Turn, step, time and counts survive format migrations and are
                // copied verbatim into forks, so a fork's copy collapses onto the parent's record.
                requestId = "attempt:\(turn):\(step):\(time):\(input):\(output):\(cacheRead):\(cacheWrite)"
            } else {
                requestId = "\(type):\(sessionId):\(turn):\(step):\(time)"
            }
        }

        var record = UsageRecord(
            source: .deepSeekHarness,
            accountId: sessionId,
            apiKeyHash: provider ?? "local-deepseek-harness",
            model: model ?? "unknown",
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output,
            cacheTokens: cacheRead + cacheWrite,
            cacheCreationTokens: cacheWrite,
            requestId: requestId,
            rawSource: rawSource
        )
        record.estimatedCost = PricingEngine.estimate(record: record, pricing: pricing)
        return record
    }

    /// A non-negative count no larger than 2^53 (JavaScript's safe-integer range, which DSH writes), or
    /// 0. Third-party gateways pass provider numbers through, and converting an out-of-range or
    /// non-integral double with `Int(_:)` would trap — before the cursor advances, so on every launch.
    private static func count(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        let double = number.doubleValue
        guard double.isFinite, double >= 1, double <= 9_007_199_254_740_992 else { return 0 }
        return Int(double)
    }

    /// The usage sample a stream settled on: its last `{"type":"chunk","chunk":{"type":"usage"}}`.
    /// Usage chunks are cumulative within an attempt, so earlier ones must not be added.
    private static func lastUsageChunk(_ stream: Any?) -> [String: Any]? {
        guard let stream = stream as? [Any] else { return nil }
        for element in stream.reversed() {
            guard let record = element as? [String: Any], LocalUsageParser.string(record["type"]) == "chunk",
                  let chunk = record["chunk"] as? [String: Any], LocalUsageParser.string(chunk["type"]) == "usage" else { continue }
            return chunk["usage"] as? [String: Any]
        }
        return nil
    }

    /// `seq` of the last `session/end-seed` marker with `"inherited": true`: the first event a fork
    /// owns. Untagged markers are written on every resume and are not cuts.
    static func inheritedPrefixEnd(lines: [Range<Int>], content: [UInt8]) -> Int? {
        var cut: Int?
        for range in lines {
            let line = content[range]
            if let type = fastEventType(line), type != "session/end-seed" { continue }
            guard let object = jsonObject(line), LocalUsageParser.string(object["type"]) == "session/end-seed",
                  (object["data"] as? [String: Any])?["inherited"] as? Bool == true,
                  let seq = object["seq"] as? NSNumber else { continue }
            cut = seq.intValue
        }
        return cut
    }

    /// The event type of a line written as `{"type":"…",…}` — DSH always writes `type` first — read
    /// without a JSON parse, so the bulky tool and message lines can be skipped cheaply. `nil` when
    /// the line isn't in that shape; the caller then parses it in full.
    private static let typePrefix = Array(#"{"type":""#.utf8)
    static func fastEventType(_ line: ArraySlice<UInt8>) -> String? {
        guard line.count > typePrefix.count, line.starts(with: typePrefix) else { return nil }
        let valueStart = line.startIndex + typePrefix.count
        guard let quote = line[valueStart...].firstIndex(of: 0x22) else { return nil }
        let value = line[valueStart..<quote]
        guard !value.contains(0x5C) else { return nil } // an escape: let the JSON parser decide
        return String(decoding: value, as: UTF8.self)
    }

    // MARK: - Helpers

    static func lineRanges(_ content: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for index in content.indices where content[index] == 0x0A {
            if index > start { ranges.append(start..<index) }
            start = index + 1
        }
        if start < content.count { ranges.append(start..<content.count) }
        return ranges
    }

    private static func jsonObject(_ bytes: ArraySlice<UInt8>) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    }

    /// The header line, for a read that resumes past it: the first frame (or line) of the log.
    private static func readHeader(_ log: SessionLog) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: log.path) else { return nil }
        defer { try? handle.close() }
        var prefix = [UInt8](handle.readData(ofLength: 64 * 1024))
        var content: [UInt8]
        if log.compressed {
            do {
                content = try Zstd.decodeFrame(prefix, at: 0).content ?? []
            } catch Zstd.DecodeError.truncated {
                prefix.append(contentsOf: handle.readDataToEndOfFile())
                guard let decoded = try? Zstd.decodeFrame(prefix, at: 0).content else { return nil }
                content = decoded
            } catch {
                return nil
            }
        } else {
            content = prefix
        }
        let end = content.firstIndex(of: 0x0A) ?? content.endIndex
        return jsonObject(content[..<end])
    }

    private static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func readBytes(_ path: String, from offset: Int64) -> [UInt8]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return [UInt8](try handle.readToEnd() ?? Data())
        } catch {
            return nil
        }
    }
}

/// Per-log state threaded through `DeepSeekHarnessUsageAdapter.parseEvent`.
public struct DeepSeekHarnessParseState: Equatable, Sendable {
    /// The current request route, from the latest `request/context` or `request/header`.
    public var provider: String?
    public var model: String?
    /// Usage events with a lower `seq` are a fork's inherited copy of its parent's log.
    public var ownFromSeq = 0

    public init(provider: String? = nil, model: String? = nil, ownFromSeq: Int = 0) {
        self.provider = provider
        self.model = model
        self.ownFromSeq = ownFromSeq
    }

    mutating func updateRoute(provider: String?, model: String?) {
        if let provider { self.provider = provider }
        if let model { self.model = model }
    }

    /// The route as stored in the refresh cursor's model column (a small JSON object), so an
    /// incremental read resuming past the `request/context` still knows it.
    var encodedRoute: String? {
        var route: [String: String] = [:]
        if let provider { route["provider"] = provider }
        if let model { route["model"] = model }
        guard !route.isEmpty, let data = try? JSONSerialization.data(withJSONObject: route, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    mutating func restoreRoute(_ encoded: String?) {
        guard let encoded, let object = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] else { return }
        updateRoute(provider: LocalUsageParser.string(object["provider"]), model: LocalUsageParser.string(object["model"]))
    }
}
