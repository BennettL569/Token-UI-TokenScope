# TokenScope usage exporter (Windows)

A small standalone program for computers that can't run TokenScope, such as a Windows PC. It reads
that machine's local usage logs for Claude Code, Claude Desktop's Cowork sessions, Codex and
OpenCode, and writes one TokenScope full-backup file (`tokenscope-backup`, format 1). The Mac app
imports that file from **Export / Import → Import backup…**. An import only adds records the Mac
doesn't have yet, so the same machine can be exported and imported again at any time.

End-user instructions (Chinese) are in [README.txt](README.txt), which ships in the package.

## What it reads

| Tool | Default location on Windows |
|---|---|
| Claude Code (CLI, and Claude Desktop's Code tab) | `%USERPROFILE%\.claude\projects\**\*.jsonl`, or under `CLAUDE_CONFIG_DIR` if set |
| Claude Desktop Cowork | `local-agent-mode-sessions\**\.claude\projects\**\*.jsonl` under `%APPDATA%\Claude`, the Microsoft Store package's `LocalCache\Roaming\Claude`, and the `Claude-3p` variants. Each session's `audit.jsonl` repeats the same messages and is skipped. |
| Codex | `%USERPROFILE%\.codex\sessions\**\*.jsonl` and `archived_sessions\*.jsonl`, or under `CODEX_HOME` if set |
| OpenCode | `%USERPROFILE%\.local\share\opencode\opencode.db`; `XDG_DATA_HOME`, `%APPDATA%` and `%LOCALAPPDATA%` are also checked |

Claude Desktop's ordinary chats keep no token usage on the device, so there is nothing to export
for them. The program also runs on macOS and Linux, using those platforms' paths.

It never writes next to the logs it reads. A SQLite database with no `-wal` file belongs to a
closed app, so it is opened `immutable=1`, which takes no lock and creates no sidecar files. A
database with a `-wal` file is opened read-only, so rows a running app hasn't checkpointed yet are
still read.

## Keeping it in step with the Mac app

The parsers are ports of `LocalUsageParser` (Claude, Codex, OpenCode), `PricingEngine.estimate`,
`Dedupe.makeKey` and `CodexDedupeKey`. A record exported here must equal what the Mac app derives
from the same log: same token buckets, model, request id and dedupe key, with the last line of a
streamed message winning. Otherwise an import would double count or disagree with the Mac.
**When one of those Swift functions changes, change its port here and its test.**

The tests' expected values were produced by TokenScopeCore itself, including the exact `Double`
timestamps Foundation parses and Swift's number formatting. The port was also checked against the
Swift adapters on a real Mac's logs: 24,508 records, with every field identical.

Costs use the Mac's pricing table when a `pricing.json` sits next to the program. That file is
either an array of `UsageBackup.Pricing` rows or a whole TokenScope backup. Without it, TokenScope's
default prices are used. Records carry the account label `Windows · <computer name>`, with
` · Cowork` appended for Cowork sessions, and the Mac's search box matches that label.

## Build and test

```bash
go test ./...
./build.sh                    # dist/windows-exporter/TokenScopeExport-windows-<version>.zip
INCLUDE_PRICING=0 ./build.sh  # a generic package, without this Mac's pricing.json
```

The package holds x64 and ARM64 executables, README.txt and, by default, this Mac's pricing table.
Building needs Go 1.26. SQLite comes from `modernc.org/sqlite`, which is pure Go, so there is no
cgo and the Windows binaries cross-compile from macOS.
