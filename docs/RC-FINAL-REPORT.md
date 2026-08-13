# SafeRG 1.2.0 RC 最终收敛报告

## 最终状态

```
SafeRG RC Final Remediation
===========================
Old Version: 1.1.0
New Version: 1.2.0（JSON summary 恒输出、-CN 紧凑、partial results 语义）

Build:      NativeAOT win-x64 单文件 3.3MB（启动 ~30ms）
Install:    %LOCALAPPDATA%\Programs\SafeRG\bin\srg.exe
PowerShell: 7.6.4（PS 5.1 兼容性已由 benchmark 验证）
rg:         ripgrep 14.1.0

Suite A: 166 PASS / 0 FAIL
Suite B: 43 PASS / 0 FAIL
Suite C: 58 PASS / 0 FAIL
Suite D: 20 PASS / 0 FAIL（RC 新增回归）
Security Regression: 注入对抗全过、Long Query 假阳性 0、副作用 0

CRITICAL: 0
HIGH:     0
MEDIUM:   0
LOW:      0
```

## 处置矩阵

| Issue | Decision | Result |
|---|---|---|
| RC-001 Long Query + IO error 丢结果 | **FIX** | AnchorFiles 不再因 rg exit 2 抛错——候选保留，继续全文验证，stdout 输出完整匹配，错误写 stderr，exit 2（RC001/RC016 验证） |
| RC-002 partial match exit 2 | INHERITED-RG + DOC | 普通模式 rg 语义透传（stdout 有结果 + exit 2）；Help 明确 "exit 2 不保证 stdout 为空"（RC002 验证） |
| RC-003 CP1252/SJIS | FIX + DOCUMENT | 显式 `--encoding windows-1252 / shift-jis` 透传可用；**不自动识别 CP1252/SJIS**（宁缺毋滥，防误判）；warning 通用化并列出全部可用编码（RC008/RC009/RC010 验证） |
| RC-004 -C1 | FIX | `-C0/-C1/-C10` 紧凑形式解析；`-Cabc/-C-1/-C999999999999` 友好报错 exit 2（RC011-013 验证） |
| RC-005 rg advanced flags | DOCUMENT | Help 增加 fallback 说明（--type/--files/--stats/-o/-l/--no-ignore/--color/-S/--smart-case/-e 用原生 rg），不再无限兼容 |
| RC-006 mixed separator | FIX | 错误翻译器对 `[SafeRG] rg:` 行路径分隔符规范化为 /（RC017 验证） |
| RC-007 binary default | DESIGN + DOCUMENT | 保持 Agent-safe 默认（目录跳过二进制）；Help 明确 + --text 强制选项 |
| RC-008 truncation | KEEP + MACHINE CONTRACT | 默认 exit 0 保持；JSON summary 恒输出（complete/truncated/had_errors/matches_shown），截断机器可检测（RC014/RC015 验证） |
| RC-009 exact-limit ambiguity | JSON SUMMARY | 恒输出 summary：Agent 可直接区分 exactly-N 与 truncated（无需"无 summary=完整"隐式约定） |
| RC-010 UTF16BE directory | **FIX** | 根因是 LegacyProbe 多编码**短路**（首个命中编码即 return）而非编码检测；改为收集全部编码真命中；补搜加 --text（UTF-16 no BOM 含 NUL，目录遍历需强制按编码解码）（RC003-007 验证） |

## 本轮修复的根因（非表面补丁）

1. **RC-001**：`AnchorFiles` 对 rg exit 2 直接 `throw SafeRgException`——把"部分路径不可读"升级成"整个 Long Query 中止"。改为 `(候选, hadErrors)` 返回，验证继续，exit 综合（有匹配+有错误 → 2）。
2. **RC-010**：`LegacyProbe` 遍历 `{gbk, utf-16le, utf-16be}` 时首个命中编码立即 return——目录同时含 UTF-16LE 与 UTF-16BE 文件时 BE 永远不被检查（黑盒观察到的"显式文件可命中、目录漏检"实为编码竞争短路）。改为收集所有编码的真命中；同时补搜强制 `--text`（UTF-16 no BOM 原始字节含 NUL，目录遍历时 rg 按二进制跳过）。
3. **JSON summary 契约**：从"仅截断时输出"改为**恒输出**（`complete`/`truncated`/`had_errors`/`matches_shown`），NDJSON 一行一对象不变；had_errors 由 stderr 翻译器同步标记（截断 kill 后 rg exit code 不可靠）。

## 性能回归（30 次 × 场景，median）

| 场景 | median | 说明 |
|---|---|---|
| UTF-8 有匹配（热路径） | 127ms | 无退化 |
| UTF-8 无匹配（ASCII） | 126ms | 无退化（不触发补搜） |
| UTF-8 无匹配（非 ASCII，补搜全 miss） | 409ms | 3 编码确认成本，仅无结果时发生 |
| GBK 命中（补搜） | 510ms | 救回 legacy 结果的成本，可接受 |

## 回答（§三十三 十问）

1. **RC-001 是否彻底修复？** 是。stdout 保留完整匹配 + stderr 错误 + exit 2（RC001/RC016 断言验证）。
2. **partial result 是否仍能返回？** 能。普通模式 rg 透传（有匹配+exit 2）；Long Query 候选保留继续验证；JSON summary 显式 `had_errors:true, complete:false`。
3. **UTF-16BE no BOM 目录扫描是否修复？** 是。多编码收集 + 补搜 --text，BE/LE 共存目录双命中（RC004）。
4. **CP1252/SJIS 如何处理？** 显式 `--encoding windows-1252 / shift-jis` 透传可用；**不自动识别**（CP1252 几乎任意字节序列都可解码，误判风险不可接受）；无匹配时 warning 明确列出全部可用编码，绝不静默。
5. **JSON 是否始终可判断 complete/truncated/had_errors？** 是。恒输出 saferg-summary 四字段。
6. **正常 UTF-8 搜索性能是否退化？** 否。热路径 127ms（与 1.1.0 相同量级）；补搜仅在"无匹配 + 非 ASCII"时触发。
7. **Long Query false positive 是否仍为 0？** 是。验证核心算法未动（本轮只改错误处理/候选保留/输出），Suite A S30-32 与 Suite C R25 全过。
8. **命令注入是否仍为 0？** 是。Suite A S47 与 Suite C R24 全过，无副作用。
9. **是否建议正式冻结当前版本？** 建议冻结 1.2.0 作为正式发布版本（CRITICAL/HIGH/MEDIUM/LOW 全 0，四套件 287 项全绿）。
10. **是否建议配置 Codex/Claude Code/OpenCode 全局规则？** 建议。规则要点：复杂/多行/超长/中文/legacy 内容优先 `srg`；含特殊字符走 `--stdin`；`exit 2` 时检查 stdout 部分结果；需要 rg 高级选项（--type/--files/--stats 等）时回退原生 rg。

## NOT VERIFIED（保持，不造假）

- 真实 Ctrl+C 按键（自动化无法发送控制台信号；kill 模拟 S58 无残留）
- Symlink（无管理员权限创建）
- 50+ 并发（20 并发 + 100 重复已覆盖）
- SJIS/CP1252 自动识别（**有意不实现**，防误判）
