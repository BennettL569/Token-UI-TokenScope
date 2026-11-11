package main

import (
	"encoding/json"
	"errors"
	"os"
)

// Price is one row of TokenScope's pricing table (`UsageBackup.Pricing`): USD per million tokens.
type Price struct {
	Tool             string  `json:"tool"`
	Model            string  `json:"model"`
	InputPerMillion  float64 `json:"inputPerMillion"`
	OutputPerMillion float64 `json:"outputPerMillion"`
	CachePerMillion  float64 `json:"cachePerMillion"`
}

// defaultPrices is `UsageStore.defaultPricing()`, the table a fresh TokenScope install starts
// with. The Mac app prices records with its own (often edited) table, so a `pricing.json` exported
// from it should be used whenever possible; these are only the fallback.
var defaultPrices = []Price{
	{"ClaudeCode", "claude-sonnet-4.5", 3, 15, 0.3},
	{"ClaudeCode", "claude-opus-4.1", 15, 75, 1.5},
	{"CodeX", "gpt-5.5", 5, 20, 0.5},
	{"CodeX", "gpt-5.4", 5, 20, 0.5},
	{"CodeX", "gpt-5.4-mini", 0.5, 2, 0.1},
	{"CodeX", "gpt-5.1-codex", 5, 20, 0.5},
	{"CodeX", "gpt-5-mini", 0.5, 2, 0.1},
	{"Hermes", "gpt-5.5", 5, 20, 0.5},
	{"Hermes", "claude-sonnet-4", 3, 15, 0.3},
	{"OpenClaw", "openclaw-agent", 1, 3, 0.1},
	{"OpenClaw", "qwen3-coder", 0.8, 2.4, 0.08},
	{"OpenCode", "opencode", 1, 3, 0.1},
	{"OpenCode", "claude-sonnet-4", 3, 15, 0.3},
	{"OpenCode", "gpt-5.1-codex", 5, 20, 0.5},
	{"Qoder", "qoder", 1, 3, 0.1},
	{"Qoder", "qmodel_latest", 1, 3, 0.1},
	{"Qoder", "claude-sonnet-4", 3, 15, 0.3},
	{"QoderCN", "qoder", 1, 3, 0.1},
	{"QoderCN", "qmodel_latest", 1, 3, 0.1},
	{"QoderCN", "claude-sonnet-4", 3, 15, 0.3},
	{"ZCode", "GLM-5.2", 0.6, 2.2, 0.11},
	{"ZCode", "GLM-5", 0.6, 2.2, 0.11},
	{"DeepSeekHarness", "deepseek-flash", 0.3, 1.2, 0.006},
	{"DeepSeekHarness", "deepseek-v4.1-flash", 0.3, 1.2, 0.006},
	{"DeepSeekHarness", "deepseek-v4-pro", 1.32, 3.96, 0.044},
	{"DeepSeekHarness", "deepseek-v4-flash", 0.3, 1.2, 0.006},
	{"DeepSeekHarness", "gpt-6.1-sol", 2, 10, 0.1},
	{"DeepSeekHarness", "glm-5.3", 1.4, 4.4, 0.26},
	{"ClaudeCode", "claude-fable-5-2", 8, 40, 0.2},
	{"ClaudeCode", "claude-fable-5-1", 10, 50, 0.25},
	{"ClaudeCode", "claude-fable-5", 10, 50, 1},
	{"ClaudeCode", "claude-opus-5-5", 4, 20, 0.2},
	{"ClaudeCode", "claude-opus-5", 5, 25, 0.5},
	{"ClaudeCode", "claude-opus-4-8", 5, 25, 0.5},
	{"ClaudeCode", "claude-opus-4-7", 5, 25, 0.5},
	{"ClaudeCode", "claude-opus-4-6", 5, 25, 0.5},
	{"ClaudeCode", "claude-sonnet-5-5", 2, 10, 0.1},
	{"ClaudeCode", "claude-sonnet-5", 2, 10, 0.2},
	{"ClaudeCode", "claude-sonnet-4-6", 3, 15, 0.3},
	{"ClaudeCode", "claude-haiku-5-5", 0.1, 0.5, 0.01},
	{"ClaudeCode", "claude-haiku-4-5", 1, 5, 0.1},
	{"ClaudeCode", "claude-haiku-4-5-20251001", 1, 5, 0.1},
	{"Hermes", "anthropic/claude-opus-4.7", 5, 25, 0.5},
	{"CodeX", "gpt-5.6-sol", 5, 30, 0.5},
	{"CodeX", "gpt-5.6-terra", 2, 12, 0.2},
	{"CodeX", "gpt-6-astra", 10, 50, 1},
	{"CodeX", "gpt-6.1-sol", 2, 10, 0.1},
	{"CodeX", "codex-auto-review", 0.2, 1.2, 0.02},
	{"Hermes", "gpt-image-2", 5, 30, 1.25},
	{"OpenCode", "glm-5.3", 1.4, 4.4, 0.26},
	{"Hermes", "glm-5.1", 1.4, 4.4, 0.26},
	{"Hermes", "glm-5-turbo", 1.2, 4, 0.24},
	{"OpenCode", "deepseek-v4.1-flash-abliterated", 0.3, 1.2, 0.006},
	{"Qoder", "DeepSeek-V4-Pro", 1.32, 3.96, 0.044},
	{"Hermes", "mimo-v2.5-pro", 0.435, 0.87, 0.0036},
	{"Hermes", "moonshotai/kimi-k2.6", 0.95, 4, 0.16},
}

// estimateCost ports `PricingEngine.estimate`: the row for this tool and model, else the first row
// for the model under any tool, else $3 / $15 / $0.30 per million.
func estimateCost(prices []Price, r Record) float64 {
	match := Price{InputPerMillion: 3, OutputPerMillion: 15, CachePerMillion: 0.3}
	found := false
	for _, p := range prices {
		if p.Tool == r.Source && p.Model == r.Model {
			match, found = p, true
			break
		}
	}
	if !found {
		for _, p := range prices {
			if p.Model == r.Model {
				match = p
				break
			}
		}
	}
	return float64(r.InputTokens)/1e6*match.InputPerMillion +
		float64(r.OutputTokens)/1e6*match.OutputPerMillion +
		float64(r.CacheTokens)/1e6*match.CachePerMillion
}

// loadPrices reads a pricing table: a TokenScope full backup (its "pricing" array) or a bare array
// of the same rows.
func loadPrices(path string) ([]Price, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var backup struct {
		Pricing []Price `json:"pricing"`
	}
	if json.Unmarshal(data, &backup) == nil && len(backup.Pricing) > 0 {
		return backup.Pricing, nil
	}
	var rows []Price
	if json.Unmarshal(data, &rows) == nil && len(rows) > 0 {
		return rows, nil
	}
	return nil, errors.New("no pricing rows found (expected a TokenScope backup or an array of pricing rows)")
}
