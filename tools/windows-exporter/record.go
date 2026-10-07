package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// Record is one row of a TokenScope backup (`UsageBackup.Record` in TokenScopeCore). Field names
// and meanings must stay in step with the Swift type: the Mac app imports this JSON as is.
type Record struct {
	DedupeKey           string  `json:"dedupeKey"`
	ID                  string  `json:"id"`
	Source              string  `json:"source"`
	AccountID           string  `json:"accountId"`
	APIKeyHash          string  `json:"apiKeyHash"`
	Model               string  `json:"model"`
	Timestamp           float64 `json:"timestamp"`
	InputTokens         int     `json:"inputTokens"`
	OutputTokens        int     `json:"outputTokens"`
	CacheTokens         int     `json:"cacheTokens"`
	CacheCreationTokens int     `json:"cacheCreationTokens"`
	EstimatedCost       float64 `json:"estimatedCost"`
	RequestID           *string `json:"requestId"`
	RawSource           string  `json:"rawSource"`
}

// Tool names, as the Mac app's `ToolKind` raw values.
const (
	toolClaudeCode = "ClaudeCode"
	toolCodex      = "CodeX"
	toolOpenCode   = "OpenCode"
)

// newRecord mirrors `UsageRecord.init`: cache creation is clamped into [0, cache], and the dedupe
// key is derived exactly like `Dedupe.makeKey`, so a record exported here and the same event read
// by the Mac app share one key.
func newRecord(source, accountID, apiKeyHash, model string, timestamp float64, input, output, cache, cacheCreation int, requestID *string, rawSource string) Record {
	cacheCreation = min(max(0, cacheCreation), cache)
	key := dedupeKey(source, requestID, timestamp, model, input, output, cache, rawSource)
	return Record{
		DedupeKey:           key,
		ID:                  uuidFromKey(key),
		Source:              source,
		AccountID:           accountID,
		APIKeyHash:          apiKeyHash,
		Model:               model,
		Timestamp:           timestamp,
		InputTokens:         input,
		OutputTokens:        output,
		CacheTokens:         cache,
		CacheCreationTokens: cacheCreation,
		RequestID:           requestID,
		RawSource:           rawSource,
	}
}

// dedupeKey is `Dedupe.makeKey`: `source::request::<id>`, or a SHA-256 of the event's fields when
// there is no request id.
func dedupeKey(source string, requestID *string, timestamp float64, model string, input, output, cache int, rawSource string) string {
	if requestID != nil && *requestID != "" {
		return source + "::request::" + *requestID
	}
	payload := fmt.Sprintf("%s|%s|%d|%d|%d|%s|%s", swiftDouble(timestamp), model, input, output, cache, source, rawSource)
	sum := sha256.Sum256([]byte(payload))
	return source + "::fallback::" + hex.EncodeToString(sum[:])
}

// uuidFromKey derives a stable UUID from the dedupe key, so re-exporting the same usage yields
// the same record ids.
func uuidFromKey(key string) string {
	sum := sha256.Sum256([]byte(key))
	b := sum[:16]
	b[6] = (b[6] & 0x0f) | 0x50
	b[8] = (b[8] & 0x3f) | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}

// swiftDouble formats a Double the way Swift's `description` does: shortest round-trip digits,
// ".0" on whole numbers, and exponent notation below 1e-4 or above 2^53. Codex request ids embed a
// timestamp in this form, so the text must match the Mac app's byte for byte.
func swiftDouble(x float64) string {
	if a := math.Abs(x); a != 0 && (a < 1e-4 || a > 1<<53) {
		return strconv.FormatFloat(x, 'e', -1, 64)
	}
	s := strconv.FormatFloat(x, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s
}

// swiftTimestamp converts a parsed time to the `timeIntervalSince1970` Foundation reports for it:
// ISO 8601 parsing keeps milliseconds and goes through the 2001 reference date, and repeating
// that arithmetic reproduces the same Double.
func swiftTimestamp(t time.Time) float64 {
	const referenceOffset = 978307200.0
	sinceReference := float64(t.UnixMilli())/1000.0 - referenceOffset
	return sinceReference + referenceOffset
}

// parseDate mirrors `LocalUsageParser.parseDate`: ISO 8601 with or without fractional seconds.
func parseDate(value any) (float64, bool) {
	s, ok := stringValue(value)
	if !ok {
		return 0, false
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return 0, false
	}
	return swiftTimestamp(t), true
}

// The value helpers below mirror `LocalUsageParser.int` / `string` / `decimal` on JSON values as
// encoding/json decodes them (numbers are float64).

func intValue(v any) int {
	switch t := v.(type) {
	case float64:
		return int(t)
	case string:
		n, err := strconv.Atoi(t)
		if err != nil {
			return 0
		}
		return n
	case bool:
		if t {
			return 1
		}
	}
	return 0
}

func stringValue(v any) (string, bool) {
	s, ok := v.(string)
	return s, ok && s != ""
}

func decimalValue(v any) (float64, bool) {
	switch t := v.(type) {
	case float64:
		return t, true
	case string:
		f, err := strconv.ParseFloat(strings.TrimSpace(t), 64)
		return f, err == nil
	case bool:
		if t {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}

// intFromKeys returns the first non-zero value among `keys`, like the Swift helper.
func intFromKeys(dict map[string]any, keys ...string) int {
	for _, key := range keys {
		if n := intValue(dict[key]); n != 0 {
			return n
		}
	}
	return 0
}

func stringFromKeys(dict map[string]any, keys ...string) (string, bool) {
	for _, key := range keys {
		if s, ok := stringValue(dict[key]); ok {
			return s, true
		}
	}
	return "", false
}

func decimalFromKeys(dict map[string]any, keys ...string) (float64, bool) {
	for _, key := range keys {
		if f, ok := decimalValue(dict[key]); ok {
			return f, true
		}
	}
	return 0, false
}

func ptr(s string) *string { return &s }
