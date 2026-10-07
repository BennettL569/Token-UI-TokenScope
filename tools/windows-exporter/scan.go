package main

import (
	"bufio"
	"bytes"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"

	_ "modernc.org/sqlite"
)

type locationKind int

const (
	kindClaude locationKind = iota // a Claude Code `projects` directory
	kindCowork                     // Claude Desktop's local-agent-mode-sessions (Cowork)
	kindCodex                      // a Codex home (`sessions/`, `archived_sessions/`)
	kindOpenCode                   // an OpenCode database file
)

// Location is one place usage is read from.
type Location struct {
	Name string
	Kind locationKind
	Path string
}

// LocationResult is what one location contributed.
type LocationResult struct {
	Location
	Found   bool
	Files   int
	Records int
	Err     error
}

type options struct {
	account string
	prices  []Price
}

// defaultLocations lists where each tool keeps its usage on this OS. Missing ones are reported as
// "not found" and skipped.
func defaultLocations() []Location {
	home, _ := os.UserHomeDir()
	var locations []Location

	claudeConfig := filepath.Join(home, ".claude")
	if dir := os.Getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		claudeConfig = dir
	}
	// The CLI and Claude Desktop's Code tab share this store.
	locations = append(locations, Location{"Claude Code", kindClaude, filepath.Join(claudeConfig, "projects")})

	for _, dir := range claudeDesktopDirs(home) {
		locations = append(locations, Location{"Claude 桌面端 Cowork", kindCowork, filepath.Join(dir, "local-agent-mode-sessions")})
	}

	codexHome := filepath.Join(home, ".codex")
	if dir := os.Getenv("CODEX_HOME"); dir != "" {
		codexHome = dir
	}
	locations = append(locations, Location{"Codex", kindCodex, codexHome})

	var openCodeDirs []string
	if dir := os.Getenv("XDG_DATA_HOME"); dir != "" {
		openCodeDirs = append(openCodeDirs, filepath.Join(dir, "opencode"))
	}
	openCodeDirs = append(openCodeDirs, filepath.Join(home, ".local", "share", "opencode"))
	if runtime.GOOS == "windows" {
		openCodeDirs = append(openCodeDirs, filepath.Join(os.Getenv("APPDATA"), "opencode"), filepath.Join(os.Getenv("LOCALAPPDATA"), "opencode"))
	}
	for _, dir := range openCodeDirs {
		locations = append(locations, Location{"OpenCode", kindOpenCode, filepath.Join(dir, "opencode.db")})
	}
	return dedupeLocations(locations)
}

// claudeDesktopDirs returns Claude Desktop's data directories. On Windows the Microsoft Store
// build keeps its data in a virtualized copy of %APPDATA% under its package folder.
func claudeDesktopDirs(home string) []string {
	switch runtime.GOOS {
	case "windows":
		appData, localAppData := os.Getenv("APPDATA"), os.Getenv("LOCALAPPDATA")
		dirs := []string{
			filepath.Join(appData, "Claude"),
			filepath.Join(appData, "Claude-3p"),
			filepath.Join(localAppData, "Claude-3p"),
		}
		packages, _ := filepath.Glob(filepath.Join(localAppData, "Packages", "Claude_*"))
		for _, pkg := range packages {
			dirs = append(dirs,
				filepath.Join(pkg, "LocalCache", "Roaming", "Claude"),
				filepath.Join(pkg, "LocalCache", "Roaming", "Claude-3p"),
				filepath.Join(pkg, "LocalCache", "Local", "Claude-3p"))
		}
		return dirs
	case "darwin":
		support := filepath.Join(home, "Library", "Application Support")
		return []string{filepath.Join(support, "Claude"), filepath.Join(support, "Claude-3p")}
	default:
		return []string{filepath.Join(home, ".config", "Claude"), filepath.Join(home, ".config", "Claude-3p")}
	}
}

func dedupeLocations(locations []Location) []Location {
	seen := map[string]bool{}
	var unique []Location
	for _, l := range locations {
		key := fmt.Sprint(l.Kind) + "|" + pathKey(l.Path)
		if !seen[key] {
			seen[key] = true
			unique = append(unique, l)
		}
	}
	return unique
}

// pathKey normalizes a path for de-duplication (Windows paths are case-insensitive).
func pathKey(path string) string {
	clean := filepath.Clean(path)
	if runtime.GOOS == "windows" {
		return strings.ToLower(clean)
	}
	return clean
}

// collect reads every location. Records are merged by dedupe key with the last occurrence winning,
// matching the Mac app's upserts: Claude Code repeats a message on several lines as it streams,
// and only the last line carries the final output count.
func collect(locations []Location, opts options) ([]Record, []LocationResult) {
	byKey := map[string]Record{}
	owner := map[string]int{}
	readFiles := map[string]bool{}
	results := make([]LocationResult, len(locations))
	for i, location := range locations {
		results[i].Location = location
		add := func(r Record) {
			byKey[r.DedupeKey] = r
			owner[r.DedupeKey] = i
		}
		var err error
		switch location.Kind {
		case kindClaude, kindCowork:
			account := opts.account
			if location.Kind == kindCowork {
				account += " · Cowork"
			}
			var files []string
			files, results[i].Found, err = jsonlFiles(location, readFiles)
			for _, file := range files {
				results[i].Files++
				err = errors.Join(err, readLines(file, func(line []byte) {
					if r, ok := parseClaudeLine(line, file, account, opts.prices); ok {
						add(r)
					}
				}))
			}
		case kindCodex:
			var files []string
			files, results[i].Found, err = jsonlFiles(location, readFiles)
			for _, file := range files {
				results[i].Files++
				// The model is announced once per turn in a turn_context line; carry it forward.
				model := ""
				err = errors.Join(err, readLines(file, func(line []byte) {
					if r, ok := parseCodexLine(line, file, opts.account, model, opts.prices); ok {
						add(r)
					} else if m, ok := codexModel(line); ok {
						model = m
					}
				}))
			}
		case kindOpenCode:
			if _, statErr := os.Stat(location.Path); statErr == nil {
				results[i].Found, results[i].Files = true, 1
				err = readOpenCode(location.Path, opts, add)
			}
		}
		results[i].Err = err
	}
	for _, i := range owner {
		results[i].Records++
	}
	records := make([]Record, 0, len(byKey))
	for _, r := range byKey {
		records = append(records, r)
	}
	sort.Slice(records, func(a, b int) bool {
		if records[a].Timestamp != records[b].Timestamp {
			return records[a].Timestamp < records[b].Timestamp
		}
		return records[a].DedupeKey < records[b].DedupeKey
	})
	return records, results
}

// jsonlFiles lists a location's JSONL logs in sorted order, skipping files another location
// already covers.
//   - Claude Code: every *.jsonl under `projects/` (sessions and their subagents).
//   - Cowork: only transcripts under a session's `.claude/projects/`; the session's audit.jsonl
//     repeats the same messages.
//   - Codex: `sessions/**/*.jsonl` plus `archived_sessions/*.jsonl`.
func jsonlFiles(location Location, readFiles map[string]bool) ([]string, bool, error) {
	var files []string
	var walkErr error
	found := false
	walk := func(root string, recursive bool, keep func(string) bool) {
		info, err := os.Stat(root)
		if err != nil || !info.IsDir() {
			return
		}
		found = true
		walkErr = errors.Join(walkErr, filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil // unreadable entry: skip it, keep going
			}
			if d.IsDir() {
				if !recursive && path != root {
					return filepath.SkipDir
				}
				return nil
			}
			if strings.HasSuffix(d.Name(), ".jsonl") && keep(path) {
				files = append(files, path)
			}
			return nil
		}))
	}
	switch location.Kind {
	case kindClaude:
		walk(location.Path, true, func(string) bool { return true })
	case kindCowork:
		marker := string(filepath.Separator) + ".claude" + string(filepath.Separator) + "projects" + string(filepath.Separator)
		walk(location.Path, true, func(path string) bool { return strings.Contains(path, marker) })
	case kindCodex:
		walk(filepath.Join(location.Path, "sessions"), true, func(string) bool { return true })
		walk(filepath.Join(location.Path, "archived_sessions"), false, func(string) bool { return true })
	}
	sort.Strings(files)
	unique := files[:0]
	for _, file := range files {
		if key := pathKey(file); !readFiles[key] {
			readFiles[key] = true
			unique = append(unique, file)
		}
	}
	return unique, found, walkErr
}

// readLines calls `handle` for each line of a file, however long the line is.
func readLines(path string, handle func([]byte)) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	reader := bufio.NewReaderSize(file, 1<<20)
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			handle(bytes.TrimSuffix(line, []byte("\n")))
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
	}
}

// readOpenCode reads every row of OpenCode's `message` table, oldest first, like the Mac adapter.
func readOpenCode(path string, opts options, add func(Record)) error {
	db, err := openReadOnly(path)
	if err != nil {
		return err
	}
	defer db.Close()
	rows, err := db.Query("SELECT id, session_id, time_created, data FROM message ORDER BY time_created ASC")
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	defer rows.Close()
	for rows.Next() {
		var id, sessionID, data sql.NullString
		var timeCreated sql.NullFloat64
		if err := rows.Scan(&id, &sessionID, &timeCreated, &data); err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		if !data.Valid {
			continue
		}
		if r, ok := parseOpenCodeRow(id.String, timeCreated.Float64, data.String, path+":message", opts.account, opts.prices); ok {
			add(r)
		}
	}
	return rows.Err()
}

// openReadOnly opens a SQLite database without writing anything next to it. With no -wal file the
// app is closed and the main file holds everything, so it is read as immutable: no locks, and no
// sidecar files (a read-only connection of this SQLite build would otherwise create -wal/-shm in
// the app's folder). With a -wal file the app may be running and recent writes may still be in the
// WAL, so it is opened read-only to see them, falling back to immutable.
func openReadOnly(path string) (*sql.DB, error) {
	modes := []string{"immutable=1"}
	if _, err := os.Stat(path + "-wal"); err == nil {
		modes = []string{"mode=ro", "immutable=1"}
	}
	var lastErr error
	for _, query := range modes {
		db, err := sql.Open("sqlite", sqliteURI(path, query))
		if err != nil {
			lastErr = err
			continue
		}
		var tables int
		if err := db.QueryRow("SELECT count(*) FROM sqlite_master").Scan(&tables); err != nil {
			lastErr = err
			db.Close()
			continue
		}
		return db, nil
	}
	return nil, fmt.Errorf("%s: %w", path, lastErr)
}

func sqliteURI(path, query string) string {
	abs, err := filepath.Abs(path)
	if err != nil {
		abs = path
	}
	slashed := filepath.ToSlash(abs)
	if !strings.HasPrefix(slashed, "/") {
		slashed = "/" + slashed // a Windows drive path: file:///C:/...
	}
	return (&url.URL{Scheme: "file", Path: slashed, RawQuery: query}).String()
}
