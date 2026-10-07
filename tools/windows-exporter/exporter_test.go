package main

import (
	"database/sql"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"
)

// Expected values below were produced by TokenScopeCore itself (LocalUsageParser, Dedupe.makeKey,
// Swift's Double description), so these tests pin the port to the Swift behaviour.

func TestSwiftDoubleMatchesSwiftDescription(t *testing.T) {
	for _, c := range []struct {
		bits uint64
		want string
	}{
		{4745255765447540736, "1780738223.5"},
		{4745255765445443584, "1780738223.0"},
		{4745252458513244881, "1779949788.924"},
		{4532020583610935537, "1e-05"},
		{4547006384149180840, "9.999e-05"},
		{4547007122018943789, "0.0001"},
		{4533405181463712916, "1.23456e-05"},
		{4845873199050653696, "9007199254740992.0"},
		{4845873199050653697, "9.007199254740994e+15"},
		{4846369599423283200, "1e+16"},
		{4848869599423283200, "1.5e+16"},
		{13836183955189006336, "-2.5"},
	} {
		if got := swiftDouble(math.Float64frombits(c.bits)); got != c.want {
			t.Errorf("swiftDouble(%v) = %q, want %q", math.Float64frombits(c.bits), got, c.want)
		}
	}
}

func TestTimestampsMatchFoundation(t *testing.T) {
	ts, ok := parseDate("2026-05-11T19:59:41.206Z")
	if !ok || math.Float64bits(ts) != 4745246501730332443 {
		t.Fatalf("parseDate = %v (bits %d), want Foundation's bits 4745246501730332443", ts, math.Float64bits(ts))
	}
	if _, ok := parseDate("2026-05-11T19:59:41Z"); !ok {
		t.Error("timestamps without fractional seconds must parse")
	}
	if _, ok := parseDate("yesterday"); ok {
		t.Error("garbage must not parse")
	}
}

func TestFallbackDedupeKeysMatchSwift(t *testing.T) {
	if got := dedupeKey(toolCodex, nil, 1_700_000_000, "m", 1, 2, 3, "raw"); got != "CodeX::fallback::e79fb38d41a9cf5d3f21952c34cea3786d750c19898d07cca3f3269596153b7c" {
		t.Errorf("fallback key = %s", got)
	}
	if got := dedupeKey(toolClaudeCode, nil, 1_779_949_788.924, "claude", 5, 6, 7, "/a b/c.jsonl"); got != "ClaudeCode::fallback::bf2a90d4f7843c2692f141613693b3f3f2f48ca233b7119e8a6b43ba30474bca" {
		t.Errorf("fallback key with a fractional timestamp = %s", got)
	}
	if got := dedupeKey(toolClaudeCode, ptr(""), 1, "m", 1, 1, 1, "r"); got[:len("ClaudeCode::fallback::")] != "ClaudeCode::fallback::" {
		t.Errorf("an empty request id must fall back, got %s", got)
	}
}

func TestClaudeParserReadsUsageLine(t *testing.T) {
	line := `{"type":"assistant","uuid":"u1","timestamp":"2026-05-11T19:59:41.206Z","message":{"id":"m1","model":"claude-sonnet-4.5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}`
	r, ok := parseClaudeLine([]byte(line), "/tmp/claude.jsonl", "acct", nil)
	if !ok {
		t.Fatal("no record")
	}
	if r.Source != toolClaudeCode || r.InputTokens != 10 || r.OutputTokens != 20 || r.CacheTokens != 7 || r.CacheCreationTokens != 3 {
		t.Errorf("unexpected tokens: %+v", r)
	}
	if r.Model != "claude-sonnet-4.5" || r.DedupeKey != "ClaudeCode::request::m1" || r.APIKeyHash != "local-claude-code" || r.AccountID != "acct" {
		t.Errorf("unexpected identity: %+v", r)
	}
	if math.Abs(r.EstimatedCost-0.0003321) > 1e-12 {
		t.Errorf("cost at the $3/$15/$0.30 fallback = %v", r.EstimatedCost)
	}
}

func TestClaudeParserDoesNotDoubleCountCacheCreation(t *testing.T) {
	line := `{"type":"assistant","uuid":"u2","timestamp":"2026-05-11T19:59:41.206Z","message":{"id":"m2","model":"claude-sonnet-4.5","usage":{"input_tokens":2,"output_tokens":10,"cache_creation_input_tokens":2170,"cache_read_input_tokens":16218,"cache_creation":{"ephemeral_5m_input_tokens":2170,"ephemeral_1h_input_tokens":0}}}}`
	r, _ := parseClaudeLine([]byte(line), "/tmp/claude.jsonl", "acct", nil)
	if r.CacheTokens != 18388 || r.CacheCreationTokens != 2170 {
		t.Errorf("cache = %d, creation = %d; want 18388 and 2170", r.CacheTokens, r.CacheCreationTokens)
	}
	breakdownOnly := `{"type":"assistant","timestamp":"2026-05-11T19:59:41.206Z","message":{"id":"m3","usage":{"input_tokens":1,"cache_creation":{"ephemeral_5m_input_tokens":5,"ephemeral_1h_input_tokens":6}}}}`
	r, _ = parseClaudeLine([]byte(breakdownOnly), "/tmp/claude.jsonl", "acct", nil)
	if r.CacheCreationTokens != 11 || r.Model != "unknown" {
		t.Errorf("breakdown fallback: creation = %d, model = %q", r.CacheCreationTokens, r.Model)
	}
}

func TestCodexParserSplitsCachedInputAndKeysByFileName(t *testing.T) {
	line := `{"timestamp":"2026-04-18T15:41:12.238Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3,"reasoning_output_tokens":2,"total_tokens":20}}}}`
	r, ok := parseCodexLine([]byte(line), "/x/sessions/2026/04/18/rollout-A.jsonl", "acct", "", nil)
	if !ok {
		t.Fatal("no record")
	}
	if r.InputTokens != 10 || r.OutputTokens != 3 || r.CacheTokens != 7 || r.CacheCreationTokens != 0 || r.Model != "codex" {
		t.Errorf("unexpected record: %+v", r)
	}
	if *r.RequestID != "rollout-A.jsonl#1776526872.238#10#3#7" || r.DedupeKey != "CodeX::request::rollout-A.jsonl#1776526872.238#10#3#7" {
		t.Errorf("request id = %s, key = %s", *r.RequestID, r.DedupeKey)
	}
	if math.Float64bits(r.Timestamp) != 4745238101760097124 {
		t.Errorf("timestamp bits = %d", math.Float64bits(r.Timestamp))
	}
	archived, _ := parseCodexLine([]byte(line), `C:\Users\me\.codex\archived_sessions\rollout-A.jsonl`, "acct", "gpt-5.5", nil)
	if filepath.Separator == '\\' && archived.DedupeKey != r.DedupeKey {
		t.Errorf("an archived session must keep its key: %s vs %s", archived.DedupeKey, r.DedupeKey)
	}
	moved, _ := parseCodexLine([]byte(line), "/x/archived_sessions/rollout-A.jsonl", "acct", "gpt-5.5", nil)
	if moved.DedupeKey != r.DedupeKey || moved.Model != "gpt-5.5" {
		t.Errorf("moved session: key %s, model %s", moved.DedupeKey, moved.Model)
	}
	cumulativeOnly := `{"timestamp":"2026-06-13T16:45:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9999,"output_tokens":8888,"total_tokens":18887}}}}`
	if _, ok := parseCodexLine([]byte(cumulativeOnly), "/tmp/c.jsonl", "acct", "", nil); ok {
		t.Error("a cumulative-only token_count must be skipped")
	}
	if m, ok := codexModel([]byte(`{"timestamp":"2026-06-13T16:45:32.000Z","type":"turn_context","payload":{"turn_id":"t1","model":"gpt-5.5"}}`)); !ok || m != "gpt-5.5" {
		t.Errorf("turn_context model = %q", m)
	}
}

func TestOpenCodeRows(t *testing.T) {
	r, ok := parseOpenCodeRow("row_1", 1_777_777_777_000, `{"id":"msg_1","providerID":"anthropic","modelID":"claude-sonnet-4","role":"assistant","usage":{"inputTokens":31,"outputTokens":41,"cacheReadTokens":5,"cacheWriteTokens":7,"cost":0.234}}`, "/tmp/opencode.db:message", "acct", nil)
	if !ok || r.InputTokens != 31 || r.OutputTokens != 41 || r.CacheTokens != 12 || r.CacheCreationTokens != 7 || r.EstimatedCost != 0.234 || r.APIKeyHash != "anthropic" || r.Model != "claude-sonnet-4" || r.DedupeKey != "OpenCode::request::msg_1" {
		t.Errorf("message row: %+v", r)
	}
	if r.Timestamp != 1_777_777_777 {
		t.Errorf("millisecond time_created should become seconds, got %v", r.Timestamp)
	}
	nested, _ := parseOpenCodeRow("row_nested", 1_778_759_081_253, `{"role":"assistant","modelID":"gpt-5.5","providerID":"xomodel-opencode-gpt","tokens":{"total":9807,"input":299,"output":292,"reasoning":11,"cache":{"write":13,"read":9216}},"time":{"created":1778759081253,"completed":1778759095240},"finish":"stop"}`, "/tmp/opencode.db:message", "acct", nil)
	if nested.InputTokens != 299 || nested.OutputTokens != 303 || nested.CacheTokens != 9229 || nested.DedupeKey != "OpenCode::request::row_nested" {
		t.Errorf("nested tokens shape: %+v", nested)
	}
	openAI, _ := parseOpenCodeRow("row_oa", 1_777_000_000, `{"role":"assistant","modelID":"gpt-5.1-codex","providerID":"openai","usage":{"input_tokens":120,"output_tokens":48,"cached_input_tokens":30,"reasoning_output_tokens":8}}`, "/tmp/opencode.db:message", "acct", nil)
	if openAI.InputTokens != 90 || openAI.OutputTokens != 56 || openAI.CacheTokens != 30 || openAI.CacheCreationTokens != 0 {
		t.Errorf("OpenAI cached subset: %+v", openAI)
	}
	if _, ok := parseOpenCodeRow("u", 1, `{"role":"user","time":{"created":1}}`, "/tmp/opencode.db:message", "acct", nil); ok {
		t.Error("a message without usage must be skipped")
	}
}

func TestPricing(t *testing.T) {
	prices := []Price{
		{"CodeX", "gpt-5.5", 5, 30, 0.5},
		{"Hermes", "shared", 1, 1, 1},
		{"CodeX", "shared", 2, 2, 2},
	}
	cost := func(source, model string) float64 {
		return estimateCost(prices, Record{Source: source, Model: model, InputTokens: 1_000_000, OutputTokens: 1_000_000, CacheTokens: 1_000_000})
	}
	if cost("CodeX", "gpt-5.5") != 35.5 {
		t.Error("exact tool + model row should be used")
	}
	if cost("OpenCode", "gpt-5.5") != 35.5 || cost("OpenCode", "shared") != 3 {
		t.Error("model-only match should take the first row for the model")
	}
	if cost("CodeX", "shared") != 6 {
		t.Error("exact match should beat an earlier model-only row")
	}
	if math.Abs(cost("CodeX", "unknown")-18.3) > 1e-9 {
		t.Error("unknown models fall back to $3 / $15 / $0.30")
	}

	dir := t.TempDir()
	backup := filepath.Join(dir, "backup.json")
	os.WriteFile(backup, []byte(`{"format":"tokenscope-backup","records":[],"pricing":[{"tool":"CodeX","model":"gpt-5.5","inputPerMillion":5,"outputPerMillion":30,"cachePerMillion":0.5}]}`), 0o644)
	if rows, err := loadPrices(backup); err != nil || len(rows) != 1 || rows[0].OutputPerMillion != 30 {
		t.Errorf("pricing from a TokenScope backup: %v %v", rows, err)
	}
	array := filepath.Join(dir, "pricing.json")
	os.WriteFile(array, []byte(`[{"tool":"ClaudeCode","model":"claude-opus-4-8","inputPerMillion":5,"outputPerMillion":25,"cachePerMillion":0.5}]`), 0o644)
	if rows, err := loadPrices(array); err != nil || len(rows) != 1 || rows[0].Model != "claude-opus-4-8" {
		t.Errorf("pricing array: %v %v", rows, err)
	}
	garbage := filepath.Join(dir, "garbage.json")
	os.WriteFile(garbage, []byte(`{"hello":1}`), 0o644)
	if _, err := loadPrices(garbage); err == nil {
		t.Error("a file without pricing rows must be rejected")
	}
}

func writeLines(t *testing.T, path string, lines ...string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	var data []byte
	for _, l := range lines {
		data = append(append(data, l...), '\n')
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCollectMatchesMacSemantics(t *testing.T) {
	dir := t.TempDir()
	// Claude Code repeats a message as it streams; only the last line has the final output count.
	writeLines(t, filepath.Join(dir, "claude", "projects", "p", "s.jsonl"),
		`{"type":"assistant","timestamp":"2026-05-11T19:59:41.206Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":2,"output_tokens":3,"cache_read_input_tokens":100}}}`,
		`not json at all`,
		`{"type":"assistant","timestamp":"2026-05-11T19:59:45.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":2,"output_tokens":277,"cache_read_input_tokens":100}}}`)
	// Codex: the model comes from the turn's turn_context; a file without one falls back to "codex".
	writeLines(t, filepath.Join(dir, "codex", "sessions", "2026", "06", "13", "rollout-A.jsonl"),
		`{"timestamp":"2026-06-13T16:45:32.000Z","type":"turn_context","payload":{"model":"gpt-5.5"}}`,
		`{"timestamp":"2026-06-13T16:45:40.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":17,"cached_input_tokens":7,"output_tokens":3}}}}`)
	writeLines(t, filepath.Join(dir, "codex", "archived_sessions", "rollout-B.jsonl"),
		`{"timestamp":"2026-06-14T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":5,"output_tokens":1}}}}`)
	// Cowork: the transcript counts; audit.jsonl repeats the same messages and must be ignored.
	session := filepath.Join(dir, "cowork", "local-agent-mode-sessions", "org", "user", "local_1")
	cowork := `{"type":"assistant","timestamp":"2026-07-01T09:00:00.000Z","message":{"id":"cw1","model":"claude-opus-4-8","usage":{"input_tokens":1,"output_tokens":9}}}`
	writeLines(t, filepath.Join(session, ".claude", "projects", "-session", "t.jsonl"), cowork)
	writeLines(t, filepath.Join(session, "audit.jsonl"), cowork, `{"type":"assistant","message":{"id":"audit-only","usage":{"input_tokens":50}}}`)

	locations := []Location{
		{"Claude Code", kindClaude, filepath.Join(dir, "claude", "projects")},
		{"Cowork", kindCowork, filepath.Join(dir, "cowork", "local-agent-mode-sessions")},
		{"Codex", kindCodex, filepath.Join(dir, "codex")},
		{"Codex again", kindCodex, filepath.Join(dir, "codex")}, // the same files twice are read once
		{"Missing", kindClaude, filepath.Join(dir, "nope")},
	}
	records, results := collect(locations, options{account: "Windows · TEST", prices: defaultPrices})
	byKey := map[string]Record{}
	for _, r := range records {
		byKey[r.DedupeKey] = r
	}
	if len(records) != 4 {
		t.Fatalf("got %d records, want 4: %v", len(records), byKey)
	}
	if r := byKey["ClaudeCode::request::m1"]; r.OutputTokens != 277 {
		t.Errorf("the last line of a streamed message must win, got output %d", r.OutputTokens)
	}
	if r := byKey["CodeX::request::rollout-A.jsonl#1781369140.0#10#3#7"]; r.Model != "gpt-5.5" {
		t.Errorf("codex model not threaded from turn_context: %+v (keys %v)", r, keysOf(byKey))
	}
	for _, r := range records {
		if r.Source == toolCodex && r.RawSource == filepath.Join(dir, "codex", "archived_sessions", "rollout-B.jsonl") && r.Model != "codex" {
			t.Errorf("a file without turn_context should fall back to codex, got %q", r.Model)
		}
	}
	if r, ok := byKey["ClaudeCode::request::cw1"]; !ok || r.AccountID != "Windows · TEST · Cowork" {
		t.Errorf("cowork transcript record: %+v", r)
	}
	if _, ok := byKey["ClaudeCode::request::audit-only"]; ok {
		t.Error("audit.jsonl must not be read")
	}
	if results[3].Files != 0 || results[4].Found {
		t.Errorf("duplicate location should read nothing new, missing location should be not found: %+v %+v", results[3], results[4])
	}
	for i := 1; i < len(records); i++ {
		if records[i-1].Timestamp > records[i].Timestamp {
			t.Error("records should be sorted by time")
		}
	}
}

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func keysOf(m map[string]Record) []string {
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}

// openCodeFixture creates an OpenCode-shaped WAL database and returns it with the writer still open.
func openCodeFixture(t *testing.T) (string, *sql.DB) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "opencode.db")
	writer, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	writer.SetMaxOpenConns(1)
	for _, stmt := range []string{
		"PRAGMA journal_mode=WAL",
		"CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL)",
		`INSERT INTO message VALUES ('row_1', 'ses_1', 1777777777000, 1777777777000, '{"id":"msg_1","providerID":"anthropic","modelID":"claude-sonnet-4","usage":{"inputTokens":31,"outputTokens":41}}')`,
	} {
		if _, err := writer.Exec(stmt); err != nil {
			t.Fatal(err)
		}
	}
	return path, writer
}

func readAll(t *testing.T, path string) []Record {
	t.Helper()
	var got []Record
	if err := readOpenCode(path, options{account: "a", prices: defaultPrices}, func(r Record) { got = append(got, r) }); err != nil {
		t.Fatal(err)
	}
	return got
}

func TestOpenCodeDatabaseOfAClosedApp(t *testing.T) {
	// The app closed: its SQLite checkpointed and removed the -wal/-shm files.
	path, writer := openCodeFixture(t)
	writer.Close()
	os.Remove(path + "-wal")
	os.Remove(path + "-shm")
	got := readAll(t, path)
	if len(got) != 1 || got[0].DedupeKey != "OpenCode::request::msg_1" || got[0].RawSource != path+":message" {
		t.Errorf("records from a closed WAL database: %+v", got)
	}
	for _, sidecar := range []string{"-wal", "-shm"} {
		if _, err := os.Stat(path + sidecar); err == nil {
			t.Errorf("reading must not create %s next to the app's database", sidecar)
		}
	}
}

func TestOpenCodeDatabaseOfARunningApp(t *testing.T) {
	// The app is running: a row written after the last checkpoint lives only in the -wal file,
	// which an immutable read would miss.
	path, writer := openCodeFixture(t)
	defer writer.Close()
	if _, err := writer.Exec("PRAGMA wal_autocheckpoint=0"); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Exec(`INSERT INTO message VALUES ('row_2', 'ses_1', 1777777778000, 1777777778000, '{"id":"msg_2","usage":{"inputTokens":5,"outputTokens":6}}')`); err != nil {
		t.Fatal(err)
	}
	if got := readAll(t, path); len(got) != 2 {
		t.Errorf("a running app's latest rows (still in the WAL) must be read, got %d records", len(got))
	}
}

func TestBackupFileFormat(t *testing.T) {
	r := newRecord(toolCodex, "Windows · TEST", "local-codex", "gpt-5.5", 1781369140.5, 10, 3, 7, 0, nil, `C:\x.jsonl`)
	path := filepath.Join(t.TempDir(), "export.json")
	if err := writeBackup(newBackup([]Record{r}, mustTime(t, "2026-10-06T14:00:00.123Z")), path); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	if raw["format"] != "tokenscope-backup" || raw["formatVersion"] != 1.0 || raw["recordCount"] != 1.0 {
		t.Errorf("header: %v", raw)
	}
	// Foundation's .iso8601 date decoding rejects fractional seconds.
	if !regexp.MustCompile(`^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$`).MatchString(raw["exportedAt"].(string)) {
		t.Errorf("exportedAt %q must be whole-second ISO 8601", raw["exportedAt"])
	}
	// Swift decodes [Pricing] / [Budget]: they must be empty arrays, never null.
	if p, ok := raw["pricing"].([]any); !ok || len(p) != 0 {
		t.Errorf("pricing must be [], got %v", raw["pricing"])
	}
	if b, ok := raw["budgets"].([]any); !ok || len(b) != 0 {
		t.Errorf("budgets must be [], got %v", raw["budgets"])
	}
	rec := raw["records"].([]any)[0].(map[string]any)
	if v, present := rec["requestId"]; !present || v != nil {
		t.Errorf("a missing request id must be written as null, got %v", v)
	}
	if !regexp.MustCompile(`^[0-9A-F]{8}-[0-9A-F]{4}-5[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$`).MatchString(rec["id"].(string)) {
		t.Errorf("id %q must be a UUID", rec["id"])
	}
	if rec["id"] != newRecord(toolCodex, "other label", "x", "gpt-5.5", 1781369140.5, 10, 3, 7, 0, nil, `C:\x.jsonl`).ID {
		t.Error("ids must be stable across exports")
	}
}
