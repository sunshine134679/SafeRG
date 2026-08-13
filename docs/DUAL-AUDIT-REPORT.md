# SafeRG 1.1.0 收敛完成报告

## 最终状态

```
SafeRG Dual Audit Remediation
==============================
Old Version: 1.0.0 (JIT self-contained, 67.5MB, 启动 ~209ms)
New Version: 1.1.0 (NativeAOT single-file, 3.3MB, 启动 ~28-36ms)

Build:      NativeAOT win-x64（JIT 版备份 artifacts-jit-backup.exe）
Install:    %LOCALAPPDATA%\Programs\SafeRG\bin\srg.exe
rg Version: ripgrep 14.1.0
PowerShell: 7.6.4（PS 5.1 兼容性已在 benchmark 中验证）

Original 166:   166 PASS / 0 FAIL
Original 43:    43 PASS / 0 FAIL
New Regression: 58 PASS / 0 FAIL（Suite C，双黑盒回归）
Security Regression: 注入对抗 11 项全过、Long Query 假阳性 0、无副作用

CRITICAL: 0
HIGH:     0
MEDIUM:   0
LOW:      0
INHERITED-RG: 2（binary 行为、Unicode case folding）
DOCUMENT:     3（glob 可靠写法、context 行格式、--ignore-case 语义）
NOT VERIFIED: 3（真实 Ctrl+C 按键、Long Path >260、Symlink）
```

## 逐项处置表

| Issue | 来源 | 决策 | 修改 |
|---|---|---|---|
| No-query NRE（9 种调用） | 两份报告 | **FIX** | QueryReader 统一 null→""；Main 统一"缺少搜索内容"exit 2；11 项 R01 断言验证无 NRE/stack trace |
| flag-only invocation | 两份报告 | FIX | 同上（`srg --regex`/`-i`/`--hidden` 等全部 exit 2 友好提示） |
| empty-query 一致性 | A/B | FIX | 空 positional/stdin/纯 LF/纯 CRLF/空 query-file/只有 options → 统一 exit 2；单个空格是合法查询（R03 a-f） |
| GBK 静默假阴性 | A/B | FIX | 无匹配+非 ASCII 自动 GBK/UTF-16LE/BE 补搜；严格 UTF-8 校验过滤假匹配；stderr warning；`--encoding gbk/auto`（R04/R21） |
| BOM-less UTF-16 | A/B | FIX | 补搜覆盖 utf-16le/utf-16be（R05） |
| context + max-results | B | FIX | 截断检查改为仅对 match 行触发（第 N 个 match 的 context 保留）；`-C 2 --max-results 2` = 2 match + 4 context（R06） |
| path separator 混乱 | B | FIX | `--path-separator /` + 搜索根规范化，单文件/目录/绝对/相对输出恒为 `/`（R08/R09） |
| truncation 不可检测 | B | FIX | `--json` saferg-summary 事件（truncated/complete/matches_shown）+ `--require-complete` exit 3；默认截断仍 exit 0（R07） |
| `--max-results` 提前终止 | B | FIX | `-m N+1`（rg 每文件提前停 + SafeRG 仍能检测"还有更多"）；全局 N 由流控保证 |
| 1MB 单行 flood | B | FIX | `--max-line-length` 默认 8192；以匹配位置为中心窗口截断+省略标记，匹配本身保留（R15） |
| rg `-n` | B | FIX | 兼容 no-op（SafeRG 恒输出行号）（R12） |
| rg `-F` | B | FIX | 默认 no-op；`--regex -F` 透传 rg 固定字符串语义（R13） |
| rg `-v` | B | FIX | **正确实现**（透传 rg -v 反转匹配），非 no-op；与 Long Query 冲突明确报错（R14） |
| regex 错误泄漏内部 pattern | B | FIX | 翻译器净化 regex parse error 块；`--pcre2` 提示改写为 SafeRG 明确说明（R16） |
| 错误信息混杂 | A/B | FIX | 全部经统一翻译器：`[SafeRG]` 前缀 + 分类（R16） |
| Long Query 泄漏 query/anchor | A/B | FIX | 默认 stderr 无查询内容；`--debug` 才输出并提示（R17） |
| `--help`/`--version` 字面查询 | B | FIX | 新增 `--query <文本>`；`--` 分隔保留；Help 明确两种写法（R10） |
| Binary 行为 | A/B | INHERITED-RG | 目录跳过/显式提示与 rg 一致；新增 `--text` 强制；JSON 事件可表达（R18） |
| Unicode case folding（İ/ß） | B | INHERITED-RG | Help 注明遵循 rg 语义，不自行实现 |
| Glob 示例误导 | A/B | DOCUMENT+FIX | Help 示例改为 `!**/node_modules/**`（绝对路径根可靠）+ 相对根说明（R19） |
| context 行格式契约 | B | DOCUMENT | Help 明确：match `path:line:col:text`、context `path-line-text`；`--json` 提供结构化 |
| `--json` 机器输出 | B | FIX | 透传 rg --json 事件流 + SafeRG 截断事件（R22） |
| 性能 benchmark | A/B | DONE | PS7/PS5 × warm(50 交替)/cold；srg ~199ms warm vs rg ~101-108ms；见下 |
| 启动性能 | A/B | FIX | NativeAOT：67.5MB→3.3MB，209ms→28-36ms（8 倍）；三套件全绿无退化 |
| 真实 Ctrl+C | 两份报告 | NOT VERIFIED | 自动化无法发送控制台 Ctrl+C；kill 模拟（S58）无残留；架构上 Ctrl+C 发进程组，rg 同组终止 |
| Long Path >260 | — | NOT VERIFIED | 系统 LongPathsEnabled=0，规格禁止修改系统设置 |
| Symlink | — | NOT VERIFIED | 无管理员权限创建 symlink；junction 场景已覆盖 |

## 性能数据（§二十四 benchmark：PS7/PS5 × warm 50 次交替 + cold 5 次）

| Mode | Median | P90 | Min | Max |
|---|---|---|---|---|
| PS7-warm-rg | 108ms | 129 | 95 | 211 |
| PS7-warm-srg | 199ms | 206 | 173 | 219 |
| PS5-warm-rg | 101ms | 103 | 94 | 111 |
| PS5-warm-srg | 199ms | 204 | 177 | 207 |
| AOT 版启动（--version） | **28-36ms** | — | 28 | 36 |

srg 的固定开销为 self-contained 运行时装载；AOT 后启动与 rg 同量级。脚本：`tests/benchmark.ps1`。

## 测试套件（全部可重跑）

- `tests/stress-test.ps1` — 76 节压力验收，166 项断言
- `tests/run-tests.ps1` — 基础回归 43 项
- `tests/release-regression.ps1` — 双黑盒回归（Suite C）58 项
- `tests/compare-rg.ps1` — 原生 rg 对照实验
- `tests/benchmark.ps1` — 性能基准

## 1. 最难修的三个问题

1. **截断语义的叠加缺陷**：context 丢失（截断检查对 context 行也生效）与 truncated 检测失效（`-m N` 让 rg 只输出 N 个，SafeRG 永远读不到第 N+1 个）两个 bug 相互掩盖——修了第一个，`--require-complete`/JSON summary 才暴露第二个；最终方案：检查仅对 match 行触发 + `-m N+1`。
2. **MatchLineRe 少一个捕获组**：行判定正则只有 3 组，`Groups[4]` 抛 ArgumentException 时发生在赋值表达式内（`line` 保持原值输出原行），错误被 Main 捕获后表现为"截断完全失效"；排查中还因 .NET 程序集字符串字面量是 UTF-16 存储（grep/strings 找不到 ASCII 形式）一度误判构建产物，浪费了验证时间。
3. **Legacy 补搜的假匹配过滤**：GBK 解码命中并不等于文件是 GBK（UTF-8 文件按 GBK 解码也可能碰巧匹配）——必须对命中文件做严格 UTF-8 校验（非 UTF-8 才算真命中），否则纯 UTF-8 项目会被误报。

## 2. 仍然存在的限制

| 限制 | 原因 | 影响 | 替代方案 |
|---|---|---|---|
| 真实 Ctrl+C 未按键验证 | 自动化无法发送控制台 Ctrl+C | 理论风险低（进程组广播） | kill 模拟验证无残留；人工验证可在 Windows Terminal 进行 |
| Long Path >260 未验证 | 系统 LongPathsEnabled=0 | 超长路径项目不可测 | 用户启用系统设置后可跑 |
| Symlink 未验证 | 无管理员权限创建 | 符号链接场景不可测 | junction 已覆盖 |
| `--regex` >28000 字符拒绝 | 命令行安全上限 | 超长正则不可搜 | 拆分正则或字面量模式 |
| legacy 补搜仅单行字面量 | 多行/正则补搜复杂度与误报风险 | 这些场景给明确提示 | `--encoding gbk` 显式指定 |
| `--json` 不截断行内容 | 透传 rg 原生 JSON | 大文本行由 Agent 自行处理 | `--max-line-length`（文本模式） |
| 传统 conhost CP936 捕获解码 | PowerShell 侧行为（与 rg 一致） | 旧控制台中文乱码 | Windows Terminal / VS Code |

## 3. 是否适合 Codex / Claude Code / OpenCode 日常使用

**是。** 三套件全绿（166+43+58），CRITICAL/HIGH 为 0；注入对抗 0 执行、Long Query 假阳性 0、legacy 编码不再静默漏报、截断机器可检测、输出契约稳定（路径统一 `/`、错误统一 `[SafeRG]`）、启动 28-36ms 与 rg 同量级。

## 4. 是否建议 AI 默认优先使用 srg

**建议。** 对照实验（compare-rg.ps1）：同样 43 项原生 rg 失败 7 项（其中 4 项直接正则解析报错）+ 2 项片段误报；srg 全部通过且增加 legacy 补搜、截断检测、JSON 输出等 Agent 必需能力。策略：含特殊字符/多行/超长/中文/legacy 编码一律 `srg`；需要 `--type`/`-c`/`--stats` 等深度选项时退回原生 rg。

## 5. 最终三个标准调用方式

```powershell
srg "keyword" .
```

```powershell
$query | srg --stdin .
```

```powershell
srg --regex "pattern" .
```
