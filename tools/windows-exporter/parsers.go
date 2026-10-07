package main

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"sort"
	"strconv"
	"time"
)

// The parsers below are ports of `LocalUsageParser` in TokenScopeCore
// (Sources/TokenScopeCore/Adapters/LocalUsageAdapters.swift). They must produce the same records —
// same token buckets, model, request id and therefore dedupe key — or an imported export would
// disagree with what the Mac app counts. When a Swift parser changes, change its port here too.

func parseObject(line []byte) (map[string]any, bool) {
	var obj map[string]any
	if json.Unmarshal(line, &obj) != nil || obj == nil {
		return nil, false
	}
	return obj, true
}

// parseClaudeLine ports `parseClaudeLine`: one assistant message with usage per line.
func parseClaudeLine(line []byte, path, account string, prices []Price) (Record, bool) {
	if !bytes.Contains(line, []byte("assistant")) || !bytes.Contains(line, []byte("usage")) {
		return Record{}, false
	}
	obj, ok := parseObject(line)
	if !ok || obj["type"] != "assistant" {
		return Record{}, false
	}
	message, ok := obj["message"].(map[string]any)
	if !ok {
		return Record{}, false
	}
	usage, ok := message["usage"].(map[string]any)
	if !ok {
		return Record{}, false
	}
	input := intValue(usage["input_tokens"])
	output := intValue(usage["output_tokens"])
	cacheCreation := intValue(usage["cache_creation_input_tokens"])
	cacheRead := intValue(usage["cache_read_input_tokens"])
	detail, _ := usage["cache_creation"].(map[string]any)
	detailSum := intValue(detail["ephemeral_1h_input_tokens"]) + intValue(detail["ephemeral_5m_input_tokens"])
	// The canonical total wins; the ephemeral breakdown sums to the same value and is only a
	// fallback (adding both double-counts cache).
	cacheCreationTotal := cacheCreation
	if cacheCreation <= 0 {
		cacheCreationTotal = detailSum
	}
	cache := cacheCreationTotal + cacheRead
	if input+output+cache <= 0 {
		return Record{}, false
	}
	timestamp, ok := parseDate(obj["timestamp"])
	if !ok {
		timestamp = swiftTimestamp(time.Now())
	}
	model, ok := stringValue(message["model"])
	if !ok {
		model = "unknown"
	}
	var requestID *string
	if id, ok := stringValue(message["id"]); ok {
		requestID = ptr(id)
	} else if id, ok := stringValue(obj["uuid"]); ok {
		requestID = ptr(id)
	}
	record := newRecord(toolClaudeCode, account, "local-claude-code", model, timestamp, input, output, cache, cacheCreationTotal, requestID, path)
	record.EstimatedCost = estimateCost(prices, record)
	return record, true
}

// codexModel ports `codexModel(fromLine:)`: the model a `turn_context` line announces.
func codexModel(line []byte) (string, bool) {
	if !bytes.Contains(line, []byte("turn_context")) {
		return "", false
	}
	obj, ok := parseObject(line)
	if !ok || obj["type"] != "turn_context" {
		return "", false
	}
	payload, ok := obj["payload"].(map[string]any)
	if !ok {
		return "", false
	}
	return stringValue(payload["model"])
}

// parseCodexLine ports `parseCodexLine`: a `token_count` event's per-turn usage. Codex follows
// OpenAI accounting — cached input is a subset of input and reasoning a subset of output — so
// cache is split out of input and output is kept as is.
func parseCodexLine(line []byte, path, account, model string, prices []Price) (Record, bool) {
	if !bytes.Contains(line, []byte("token_count")) {
		return Record{}, false
	}
	obj, ok := parseObject(line)
	if !ok || obj["type"] != "event_msg" {
		return Record{}, false
	}
	payload, ok := obj["payload"].(map[string]any)
	if !ok || payload["type"] != "token_count" {
		return Record{}, false
	}
	info, ok := payload["info"].(map[string]any)
	if !ok {
		return Record{}, false
	}
	// Only the per-event delta; the session-cumulative total would be re-added on every event.
	usage, ok := info["last_token_usage"].(map[string]any)
	if !ok {
		return Record{}, false
	}
	cache := intValue(usage["cached_input_tokens"])
	input := max(0, intValue(usage["input_tokens"])-cache)
	output := intValue(usage["output_tokens"])
	if input+output+cache <= 0 {
		return Record{}, false
	}
	timestamp, ok := parseDate(obj["timestamp"])
	if !ok {
		timestamp = swiftTimestamp(time.Now())
	}
	if model == "" {
		model = "codex"
	}
	// Keyed on the session file's name, not its path (`CodexDedupeKey`).
	requestID := filepath.Base(path) + "#" + swiftDouble(timestamp) + "#" + strconv.Itoa(input) + "#" + strconv.Itoa(output) + "#" + strconv.Itoa(cache)
	record := newRecord(toolCodex, account, "local-codex", model, timestamp, input, output, cache, 0, ptr(requestID), path)
	record.EstimatedCost = estimateCost(prices, record)
	return record, true
}

// parseOpenCodeRow ports `parseOpenCodeMessageRow`: one row of OpenCode's `message` table.
func parseOpenCodeRow(id string, timeCreated float64, data, rawSource, account string, prices []Price) (Record, bool) {
	obj, ok := parseObject([]byte(data))
	if !ok {
		return Record{}, false
	}
	usage := firstUsageDictionary(obj)
	cacheDict, _ := usage["cache"].(map[string]any)
	// OpenAI-style cached input is a subset of input: move it out of input into the cache bucket.
	cachedSubset := intFromKeys(usage, "cachedInputTokens", "cached_input_tokens")
	rawInput := intFromKeys(usage, "inputTokens", "input_tokens", "promptTokens", "prompt_tokens", "input")
	input := max(0, rawInput-cachedSubset)
	output := intFromKeys(usage, "outputTokens", "output_tokens", "completionTokens", "completion_tokens", "output") +
		intFromKeys(usage, "reasoningTokens", "reasoning_tokens", "reasoningOutputTokens", "reasoning_output_tokens", "reasoning")
	cacheRead := cachedSubset +
		intFromKeys(usage, "cacheReadTokens", "cache_read_tokens", "cacheRead") +
		intFromKeys(cacheDict, "read", "cacheRead", "cache_read_tokens", "cachedInputTokens", "cached_input_tokens")
	cacheWrite := intFromKeys(usage, "cacheWriteTokens", "cache_write_tokens", "cacheCreationInputTokens", "cache_creation_input_tokens", "cacheWrite") +
		intFromKeys(cacheDict, "write", "cacheWrite", "cache_write_tokens", "cacheCreationInputTokens", "cache_creation_input_tokens")
	cache := cacheRead + cacheWrite
	if input+output+cache <= 0 {
		return Record{}, false
	}
	provider, ok := stringFromKeys(obj, "provider", "providerID", "providerId")
	if !ok {
		provider, ok = stringFromKeys(usage, "provider", "providerID", "providerId")
	}
	if !ok {
		provider = "local-opencode"
	}
	model, ok := stringFromKeys(obj, "model", "modelID", "modelId")
	if !ok {
		model, ok = stringFromKeys(usage, "model", "modelID", "modelId")
	}
	if !ok {
		model = "opencode"
	}
	timestamp, ok := 0.0, false
	if s, found := stringFromKeys(obj, "timeCreated", "time_created", "timestamp", "createdAt"); found {
		timestamp, ok = parseDate(s)
	}
	if !ok {
		timestamp = timeCreated
		if timestamp >= 10_000_000_000 {
			timestamp /= 1000.0
		}
	}
	requestID, ok := stringFromKeys(obj, "id", "requestId", "request_id")
	if !ok {
		requestID = id
	}
	record := newRecord(toolOpenCode, account, provider, model, timestamp, input, output, cache, cacheWrite, ptr(requestID), rawSource)
	// A cost reported on the usage object wins; otherwise estimate it.
	if cost, ok := decimalFromKeys(usage, "cost", "costUSD", "cost_usd", "estimatedCost", "estimated_cost"); ok {
		record.EstimatedCost = cost
	} else {
		record.EstimatedCost = estimateCost(prices, record)
	}
	return record, true
}

// firstUsageDictionary ports the Swift helper: the first usage-like object, searched breadth-first
// by key priority, then nested values. Swift visits nested values in hash order; sorted keys keep
// this deterministic (it only matters when several nested objects look like usage).
func firstUsageDictionary(value any) map[string]any {
	switch v := value.(type) {
	case map[string]any:
		for _, key := range []string{"usage", "tokens", "tokenUsage", "token_usage", "cost"} {
			if usage, ok := v[key].(map[string]any); ok {
				return usage
			}
		}
		keys := make([]string, 0, len(v))
		for key := range v {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			if found := firstUsageDictionary(v[key]); len(found) > 0 {
				return found
			}
		}
	case []any:
		for _, item := range v {
			if found := firstUsageDictionary(item); len(found) > 0 {
				return found
			}
		}
	}
	return map[string]any{}
}
