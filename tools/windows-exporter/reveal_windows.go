//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// reveal opens File Explorer with the exported file selected. Explorer parses its own command
// line, so the quoting is written out rather than left to exec's escaping.
func reveal(path string) {
	cmd := exec.Command("explorer.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CmdLine: `explorer.exe /select,"` + path + `"`}
	_ = cmd.Start()
}
