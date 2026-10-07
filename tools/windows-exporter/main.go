// Command TokenScopeExport collects AI coding-tool token usage on this computer (Claude Code,
// Claude Desktop's Cowork, Codex, OpenCode) into one TokenScope backup file that the TokenScope Mac
// app imports from Export / Import → Import backup….
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const version = "1.0.0"

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ", ") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

func main() {
	var claudeDirs, codexDirs, openCodeDBs multiFlag
	out := flag.String("out", "", "output file or folder (default: next to this program)")
	label := flag.String("label", "", `account label stored on every record (default "Windows · <computer name>")`)
	pricingPath := flag.String("pricing", "", "pricing table: pricing.json or a TokenScope full backup (default: pricing.json next to this program)")
	flag.Var(&claudeDirs, "claude", "extra Claude Code projects folder to read (repeatable)")
	flag.Var(&codexDirs, "codex", "extra Codex home folder to read (repeatable)")
	flag.Var(&openCodeDBs, "opencode", "extra OpenCode opencode.db to read (repeatable)")
	noDefaults := flag.Bool("no-defaults", false, "read only the folders given with -claude / -codex / -opencode")
	noPause := flag.Bool("no-pause", false, "exit without waiting for Enter")
	flag.Parse()

	code := run(*out, *label, *pricingPath, claudeDirs, codexDirs, openCodeDBs, *noDefaults, !*noPause)
	if !*noPause {
		fmt.Print("\n按回车键退出…")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
	os.Exit(code)
}

func run(out, label, pricingPath string, claudeDirs, codexDirs, openCodeDBs []string, noDefaults, interactive bool) int {
	fmt.Printf("TokenScope 用量导出工具 %s\n\n", version)
	host, _ := os.Hostname()
	if label == "" {
		label = platformName() + " · " + host
	}

	prices, pricingNote := choosePrices(pricingPath)
	fmt.Printf("记录标签：%s（在 Mac 上搜索这个标签即可只看这台电脑的数据）\n", label)
	fmt.Printf("价格表：%s\n\n", pricingNote)

	var locations []Location
	if !noDefaults {
		locations = defaultLocations()
	}
	for _, dir := range claudeDirs {
		locations = append(locations, Location{"Claude Code", kindClaude, dir})
	}
	for _, dir := range codexDirs {
		locations = append(locations, Location{"Codex", kindCodex, dir})
	}
	for _, db := range openCodeDBs {
		locations = append(locations, Location{"OpenCode", kindOpenCode, db})
	}
	locations = dedupeLocations(locations)

	records, results := collect(locations, options{account: label, prices: prices})
	printResults(results)

	if len(records) == 0 {
		fmt.Println("\n没有找到任何用量记录，未生成文件。")
		return 1
	}
	path, err := outputPath(out, host)
	if err != nil {
		fmt.Printf("\n无法确定输出位置：%v\n", err)
		return 1
	}
	if err := writeBackup(newBackup(records, time.Now()), path); err != nil {
		fmt.Printf("\n写入失败：%v\n", err)
		return 1
	}
	first := time.Unix(int64(records[0].Timestamp), 0).Format("2006-01-02")
	last := time.Unix(int64(records[len(records)-1].Timestamp), 0).Format("2006-01-02")
	fmt.Printf("\n共 %d 条记录（%s ~ %s），已写入并回读校验：\n%s\n", len(records), first, last, path)
	fmt.Println("\n把这个文件传到 Mac，在 TokenScope 的「导出 / 导入」页点「导入备份…」选择它即可。")
	fmt.Println("重复导入不会重复计数：Mac 只会新增它还没有的记录。")
	if interactive {
		reveal(path)
	}
	return 0
}

func platformName() string {
	switch runtime.GOOS {
	case "windows":
		return "Windows"
	case "darwin":
		return "macOS"
	default:
		return "Linux"
	}
}

func choosePrices(path string) ([]Price, string) {
	if path == "" {
		if exe, err := os.Executable(); err == nil {
			candidate := filepath.Join(filepath.Dir(exe), "pricing.json")
			if _, err := os.Stat(candidate); err == nil {
				path = candidate
			}
		}
	}
	if path != "" {
		prices, err := loadPrices(path)
		if err == nil {
			return prices, fmt.Sprintf("%s（%d 项）", path, len(prices))
		}
		fmt.Printf("读取价格表 %s 失败：%v，改用内置默认价格。\n", path, err)
	}
	return defaultPrices, "内置默认价格（费用可能和 Mac 上的价格表不一致；把 Mac 导出的 pricing.json 放在本程序旁边即可）"
}

// printResults lists the locations that held something, then sums up the rest per tool: each tool
// has several candidate folders, so listing every miss or empty folder would be noise.
func printResults(results []LocationResult) {
	found, printed := map[string]bool{}, map[string]bool{}
	var names []string
	for _, r := range results {
		if _, seen := found[r.Name]; !seen {
			names = append(names, r.Name)
		}
		found[r.Name] = found[r.Name] || r.Found
		if !r.Found || (r.Files == 0 && r.Records == 0 && r.Err == nil) {
			continue
		}
		printed[r.Name] = true
		fmt.Printf("• %s：%d 条记录，%d 个文件\n  %s\n", r.Name, r.Records, r.Files, r.Path)
		if r.Err != nil {
			fmt.Printf("  部分内容读取出错：%v\n", r.Err)
		}
	}
	var missing []string
	for _, name := range names {
		switch {
		case !found[name]:
			missing = append(missing, name)
		case !printed[name]:
			fmt.Printf("• %s：没有记录\n", name)
		}
	}
	if len(missing) > 0 {
		fmt.Printf("• 这台电脑上没有找到：%s\n", strings.Join(missing, "、"))
	}
}

// outputPath resolves -out (a file or a folder) or defaults to a timestamped file next to the
// program, falling back to the working folder when that isn't writable.
func outputPath(out, host string) (string, error) {
	name := fmt.Sprintf("TokenScope-%s-%s.json", sanitize(host), time.Now().Format("20060102-150405"))
	if out != "" {
		if info, err := os.Stat(out); err == nil && info.IsDir() {
			return filepath.Join(out, name), nil
		}
		return out, nil
	}
	var dirs []string
	if exe, err := os.Executable(); err == nil {
		dirs = append(dirs, filepath.Dir(exe))
	}
	if wd, err := os.Getwd(); err == nil {
		dirs = append(dirs, wd)
	}
	for _, dir := range dirs {
		probe, err := os.CreateTemp(dir, ".tokenscope-write-test-*")
		if err == nil {
			probe.Close()
			os.Remove(probe.Name())
			return filepath.Join(dir, name), nil
		}
	}
	return "", fmt.Errorf("no writable folder; pass -out")
}

func sanitize(s string) string {
	if s == "" {
		return "export"
	}
	return strings.Map(func(r rune) rune {
		if strings.ContainsRune(`<>:"/\|?* `, r) {
			return '-'
		}
		return r
	}, s)
}
