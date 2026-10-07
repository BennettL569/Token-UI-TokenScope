package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"reflect"
	"time"
)

// Backup is TokenScope's full-backup format (`UsageBackup` in TokenScopeCore, format version 1),
// which the Mac app's Export / Import screen imports. Pricing and budgets are left empty so the
// import only adds records and never offers to overwrite the Mac's settings.
type Backup struct {
	AppVersion    string   `json:"appVersion"`
	Budgets       []any    `json:"budgets"`
	ExportedAt    string   `json:"exportedAt"`
	Format        string   `json:"format"`
	FormatVersion int      `json:"formatVersion"`
	Pricing       []any    `json:"pricing"`
	RecordCount   int      `json:"recordCount"`
	Records       []Record `json:"records"`
}

func newBackup(records []Record, now time.Time) Backup {
	return Backup{
		AppVersion: "TokenScope Windows Exporter " + version,
		Budgets:    []any{},
		// Foundation's .iso8601 decoding rejects fractional seconds.
		ExportedAt:    now.UTC().Format("2006-01-02T15:04:05Z"),
		Format:        "tokenscope-backup",
		FormatVersion: 1,
		Pricing:       []any{},
		RecordCount:   len(records),
		Records:       records,
	}
}

// writeBackup writes the backup atomically, then reads the file back and checks it decodes to the
// same records, so a file reported as written is known to be importable. A file that fails the
// check is removed.
func writeBackup(backup Backup, path string) error {
	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(backup); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, buf.Bytes(), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	data, err := os.ReadFile(path)
	if err == nil {
		var reread Backup
		if err = json.Unmarshal(data, &reread); err == nil && !reflect.DeepEqual(reread.Records, backup.Records) {
			err = errors.New("records differ after reading the file back")
		}
	}
	if err != nil {
		os.Remove(path)
		return fmt.Errorf("verification failed, file removed: %w", err)
	}
	return nil
}
