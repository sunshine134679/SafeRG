# SafeRG — ripgrep 的安全包装（面向 AI Agent）

SafeRG 是 `ripgrep` 的 Windows 安全包装层，专为 **AI Agent**（Codex / Claude Code / OpenCode 等）
在 PowerShell 7 / CMD / Windows Terminal / VS Code 终端中调用 `rg` 而设计。

当前版本：**1.2.0**（NativeAOT 单文件 3.3MB，启动 ~30ms）

它解决的核心痛点：引号转义错误、`$` 被 PowerShell 当变量、`| & ;` 被 Shell 解释、
正则字符被误匹配、中文乱码、多行/超长文本搜索失败、结果灌爆 AI 上下文、legacy 编码静默假阴性等。

## 核心设计

| 原则 | 实现 |
|---|---|
| 默认纯文本搜索 | 默认 Literal 模式（等价 `rg -F`），只有显式 `--regex` 才解释正则 |
| 禁止 Shell 拼接 | 全部通过 `ProcessStartInfo.ArgumentList` 独立传参；无 `Invoke-Expression`、无 `cmd /c`、无字符串拼接 |
| 三种查询输入 | 位置参数 / `--stdin` / `--query-file`（另有显式 `--query <文本>`，查询以 `-` 开头时最可靠） |
| 多行搜索 | 自动检测换行 → 逐行转义 + `\r?\n` 连接（`rg -U`），兼容 LF 与 CRLF |
| 超长文本 | >4000 字符自动进入 **Long Query Mode**：提取 anchor → `rg -F -l` 找候选 → 读取文件全文二次验证（隐私：默认不输出查询/anchor 内容，`--debug` 才显示） |
| UTF-8 | 内部全程 UTF-8；**无匹配且查询含非 ASCII 时自动 GBK/UTF-16 补搜**（防静默假阴性，`--encoding` 可显式指定） |
| 结果保护 | `--max-results` 默认 200（提前终止扫描），`--max-line-length` 默认 8192 字符（1MB 单行防灌爆），`--require-complete` 截断时 exit 3 |
| 输出契约 | match 行 `path:line:col:text`、context 行 `path-line-text`，路径分隔符统一 `/`；`--json` 机器可读事件流（含 saferg-summary 截断事件） |
| Exit Code | 0=有匹配，1=无匹配，2=错误，3=结果被截断（仅 `--require-complete` 时） |
| 错误统一 | 所有错误经 SafeRG 翻译器：`[SafeRG]` 前缀、regex 错误净化（不泄漏内部转义 pattern）、`--pcre2` 提示明确化 |
| 不破坏 rg | 原版 `rg` 完全不受影响，两者并存 |

## 安装

```powershell
# 方式一：一键安装脚本（复制 exe + 增量加入 User PATH）
pwsh -NoProfile -File D:\Tools\SafeRG\scripts\install.ps1

# 方式二：手动
#   1. 发布（需 .NET SDK 8+ 与 VS C++ 工具链）：
#      cd D:\Tools\SafeRG\src
#      dotnet publish -c Release -r win-x64 -p:PublishAot=true -p:PublishSingleFile=false -o ..\artifacts
#      （默认 csproj 配置为 JIT 自包含 67MB；加 -p:PublishAot=true 产出 NativeAOT 3.3MB）
#   2. 复制 artifacts\srg.exe 到 %LOCALAPPDATA%\Programs\SafeRG\bin\
#   3. 将该 bin 目录增量追加到 User PATH（[Environment]::SetEnvironmentVariable('Path', ..., 'User')）
```

安装位置：`%LOCALAPPDATA%\Programs\SafeRG\bin\srg.exe`（单文件、独立、win-x64，无任何外部依赖）。
新开的终端立即可用 `srg`；已打开的终端需重启后生效。

## 用法

```powershell
srg "SecondhandItem" .                 # 字面量搜索（默认）
$query | srg --stdin .                  # 特殊字符/多行：从 STDIN 读完整查询（推荐）
srg --query-file query.txt .            # 超长文本：从文件读查询
srg --regex "foo.*bar" .                # 显式正则
srg "hello" . --ignore-case             # 忽略大小写
srg "hello" . --case-sensitive          # 区分大小写（默认）
srg "hello" . --hidden                  # 含隐藏文件
srg "hello" . --glob "*.java"           # 文件过滤
srg "hello" . --glob "!node_modules/**" # 排除
srg "hello" . --context 3               # 上下文
srg --help                              # 帮助
```

## 选项

| 选项 | 说明 |
|---|---|
| `--regex` | 正则模式（默认关闭；Regex 模式默认区分大小写，不做 smart-case） |
| `--stdin` | 从 STDIN 读取完整查询 |
| `--query-file 文件` | 从文件读取查询（UTF-8/UTF-16/GBK 均可） |
| `-i, --ignore-case` | 忽略大小写 |
| `--case-sensitive` | 区分大小写（默认） |
| `--hidden` | 搜索隐藏文件/目录 |
| `-g, --glob 模式` | 文件过滤，可重复 |
| `-C, --context N` | 上下文行数 |
| `--max-results N` | 结果上限（默认 200，0=不限） |
| `-h, --help` / `--version` | 帮助 / 版本 |

## Long Query Mode（>4000 字符）

```
超长查询 → 提取 1~3 个高辨识度 anchor（8~300 字符的非空行/token）
→ rg -F -l 逐 anchor 找候选文件（取交集，最多 300 个）
→ SafeRG 亲自读取候选文件，规范化换行（\r\n → \n）后验证完整查询
→ 输出真正匹配的 path:line:col
```

不会因为 Windows 命令行长度限制（32767 字符）或引号转义失败。

## 目录结构

```
D:\Tools\SafeRG\
├── src\            C# 源码（.NET 8，手写参数解析，零第三方框架）
├── scripts\install.ps1   安装脚本（复制 exe + 增量 User PATH）
├── tests\run-tests.ps1   完整测试套件（43 项，全部通过）
├── docs\AI-AGENT-GUIDE.md 给 AI Agent 的使用指南
└── artifacts\      发布产物（srg.exe 单文件）
```

## 测试

```powershell
pwsh -NoProfile -File D:\Tools\SafeRG\tests\run-tests.ps1
```

覆盖：中文（参数/STDIN/GBK/BOM/UTF-16）、`$`、单双引号、反引号、管道符、正则字符字面量、
空格/中文路径、多行 LF/CRLF、超长文本（>10000 字符，多行+单行）、退出码、Regex、大小写、
结果截断、隐藏文件、glob、context、Emoji、混合特殊字符、字节级 UTF-8、新终端 PATH 解析、
CMD 可用性、单文件独立运行。

## 重新构建

```powershell
cd D:\Tools\SafeRG\src
dotnet publish -c Release -o ..\artifacts   # 产出单文件 srg.exe（~67MB，自带 .NET 运行时）
```
