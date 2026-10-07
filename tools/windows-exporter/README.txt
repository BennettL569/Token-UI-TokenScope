TokenScope 用量导出工具（Windows）
====================================

把这台电脑上 AI 编程工具的 token 用量导出成一个文件，再导入 Mac 上的 TokenScope，
两台电脑的用量就能放在一起统计。

能导出的数据
------------
- Claude Code：命令行，以及 Claude 桌面端的 Code 标签页（两者共用 %USERPROFILE%\.claude）
- Claude 桌面端的 Cowork 会话
- Codex：命令行、IDE 插件和桌面端（都在 %USERPROFILE%\.codex）
- OpenCode（%USERPROFILE%\.local\share\opencode\opencode.db）

Claude 桌面端的普通聊天不会在电脑上记录 token 用量，所以导不出来。

使用方法
--------
1. 先把整个文件夹解压出来，不要在压缩包里直接运行。
2. 双击 TokenScopeExport.exe。ARM 处理器的电脑（如骁龙笔记本）用 TokenScopeExport-arm64.exe。
   如果弹出「Windows 已保护你的电脑」，点「更多信息」→「仍要运行」。这是因为程序没有付费签名。
3. 运行结束后，程序旁边会生成 TokenScope-电脑名-日期时间.json，资源管理器会自动选中它。
4. 把这个 .json 文件传到 Mac，在 TokenScope 的「导出 / 导入」页点「导入备份…」选择它。

需要知道的
----------
- 可以随时重复导出、重复导入，不会重复计数：Mac 只会新增它还没有的记录。
- 导入后，在 Mac 的搜索框输入 Windows 或电脑名，就能只看这台电脑的用量。
- 工具只读取上面这些数据，不会修改、删除任何文件，也不联网。
- pricing.json 是 Mac 上的价格表，用来计算费用，要和 exe 放在同一个文件夹。
  在 Mac 上改了价格之后，可以在 Mac 上「导出完整备份」，把备份文件放到 exe 旁边并改名为
  pricing.json（工具只读取其中的价格表）。没有 pricing.json 时会使用内置默认价格。
- Claude Code 默认只保留最近 30 天的会话日志，更早的会被自动删除。建议至少每个月导出一次，
  或者在 %USERPROFILE%\.claude\settings.json 里把 cleanupPeriodDays 调大（例如 3650，不要设为 0）。

命令行用法（可选）
------------------
  TokenScopeExport.exe -out D:\exports                    指定输出文件或文件夹
  TokenScopeExport.exe -claude D:\other\.claude\projects  额外读取一个 Claude Code 目录（可重复）
  TokenScopeExport.exe -codex D:\other\.codex             额外读取一个 Codex 目录（可重复）
  TokenScopeExport.exe -opencode D:\other\opencode.db     额外读取一个 OpenCode 数据库（可重复）
  TokenScopeExport.exe -label "公司电脑"                  自定义记录标签
  TokenScopeExport.exe -no-pause                          结束后不等待回车

工具装在 WSL 里时，数据在 WSL 的文件系统中，例如：
  TokenScopeExport.exe -claude \\wsl.localhost\Ubuntu\home\你的用户名\.claude\projects
