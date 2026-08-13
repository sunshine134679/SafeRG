# AI Agent 使用 SafeRG 指南

`srg` 是 `rg` 的安全包装：**默认纯文本搜索，绝不猜测转义**。
本指南告诉 Agent 什么场景用 `srg`、什么场景保留原生 `rg`。

## 最常用的三个命令

```powershell
srg "keyword" .
```

```powershell
$query | srg --stdin .
```

```powershell
srg --regex "pattern" .
```

## 按场景选择

| 场景 | 命令 | 原因 |
|---|---|---|
| 普通关键字（无特殊字符） | `srg "SecondhandItem" .` | 字面量模式，等价 `rg -F` |
| 含 `$ " ' \` \| & ;` 等特殊字符 | `$query \| srg --stdin .` | **优先 STDIN**：内容不经 Shell/PS 解释 |
| 多行代码片段（≥2 行） | `$query \| srg --stdin .` | 自动多行模式，兼容 LF/CRLF |
| 超长文本（>4000 字符） | `srg --query-file query.txt .` | 自动 Long Query Mode：anchor + 全文验证 |
| 真正需要正则 | `srg --regex "..." .` | 只有显式 `--regex` 才解释正则 |
| 大小写 | `--ignore-case` / `--case-sensitive` | 默认区分大小写（Regex 模式也是） |

## 关键约定（Agent 必须遵守）

1. **默认 Literal**：`user.name[0]`、`foo(bar)`、`$user` 一律按字面搜索。
   想用正则必须显式 `--regex`。
2. **复杂内容走 STDIN**：查询含 `"` `'` `$` `` ` `` `|` `&` `;` 或换行时，
   不要研究 PowerShell 引号转义，直接 `$query | srg --stdin .`。
   SafeRG 自己读取完整内容，PowerShell 不参与转义。
3. **超长内容走 --query-file**：Agent 生成的大段代码/JSON/XML 先写入临时文件，
   再 `srg --query-file 文件 .`；或直接管道给 `--stdin` 触发 Long Query Mode。
4. **输出格式**：`path:line:col:text`，可直接定位文件。
5. **Exit Code**：0=有匹配，1=无匹配，2=错误。
6. **结果上限**：默认最多 200 行，超限会输出
   `[SafeRG] Results truncated: showing first 200 matches.`（stderr），
   如需更多用 `--max-results N`，N 不要超过 2000 以免灌爆上下文。
7. **`[SafeRG]` 前缀** 的提示（模式通知/错误）在 stderr；stdout 只有搜索结果，
   解析输出时直接按行解析即可。

## 1.1.0 新增能力（Agent 可用）

| 能力 | 命令 |
|---|---|
| 查询以 `-` 开头（无需猜 `--` 位置） | `srg --query "-pattern" .` |
| 机器可读输出（JSON 事件流 + 截断标记） | `srg --json "foo" .` |
| legacy 编码显式指定（GBK/UTF-16） | `srg --encoding gbk "中文" .` |
| 自动 legacy 补搜（默认开启，仅无匹配+非 ASCII 时） | 无需参数 |
| 截断可检测（机器/退出码） | `--json` 事件 / `--require-complete`（exit 3） |
| 超长行保护 | `--max-line-length N`（默认 8192，0=关闭） |
| 反转匹配（rg 语义） | `srg -v "pattern" .` |
| 强制按文本搜索二进制 | `srg --text "pattern" file.bin` |

## 什么时候应该用原生 `rg`

- 需要 `--type`, `-c`（计数）, `--files`, `--stats`, `--json` 等 srg 未转发的深度选项时；
- 你已经很确定正则语法且内容简单时。

`srg` 与 `rg` 并存，互不影响。

## 常见坑（SafeRG 已解决，无需再踩）

- `$user` 被 PowerShell 当变量 → 用 STDIN 或单引号参数
- `"name": "张三"` 引号嵌套 → 用 STDIN
- `foo | bar` 被当管道 → 用 STDIN
- `a[b].c` 被当正则 → 默认 Literal
- 多行代码搜不到 → 自动 multiline（`rg -U`），兼容 CRLF
- 10000 字符查询失败 → 自动 Long Query Mode
- 中文乱码 → 内部全程 UTF-8
