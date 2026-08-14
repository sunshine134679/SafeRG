# SafeRG 1.3.0 Agent UX Optimization 报告

## 最终状态

```
SafeRG 1.3.0 Agent UX Optimization
==================================
Old Version: 1.2.0（已发布 GitHub v1.2.0）
New Version: 1.3.0（新增功能 bump minor；规格写 1.2.0 时未考虑 RC 轮已发布 1.2.0）

New supported options:
-l / --files-with-matches:     ✓ 文件列表（Long Query 全文验证后才输出，anchor 命中不输出）
-o / --only-matching:          ✓ 匹配片段（保持 path:line:col 前缀；-o+Long Query 明确拒绝）
-t / --type:                   ✓ 透传 rg 类型定义（白名单格式校验；未知 type 由 rg 清晰报错）
--type-add:                    ✓ name:glob 独立 argv 传递（格式白名单，无注入面）
-S / --smart-case:             ✓ rg 一致语义；与 -i/--case-sensitive 冲突明确报错
--no-ignore:                   ✓ 透传 rg（与 --hidden 相互独立，不混为一谈）
--stats:                       暂缓（rg stats 无法代表 SafeRG 完整工作：补搜/截断/Long Query 验证）
--no-column:                   ✓ path:line:text（仅文本模式；JSON 模式明确拒绝）

Fast Path:
Implemented:                   文本行识别去正则化（手写冒号段数字校验，替代逐行 Regex）
Criteria:                      所有文本模式统一生效（-l/-o/--no-column 均适用）；保留全部安全策略
实测收益:                      median 165→164ms（~1ms；核心开销为 AOT 启动+rg 启动，无 daemon 前提下不可再降）

Legacy warning:
Old behavior:                  无匹配+非 ASCII → 每次输出大段编码说明（GBK/UTF-16/Shift-JIS/CP1252...）
New behavior:                  补搜命中 → 一行总结 warning；补搜全 miss → 轻量探测（rg --files +
                               前 4KB 严格 UTF-8 采样，上限 10000 文件），仅检测到真实 legacy 风险时
                               输出一行 "Search may be incomplete..."；纯 UTF-8 项目安静 exit 1；
                               详细编码信息进 --debug

Benchmark Before (50 次交替):
rg:  median=140 p90=155 p95=173 min=125 max=350
srg: median=165 p90=179 p95=185 min=149 max=197

Benchmark After (50 次交替):
rg:  median=135 p90=143 p95=146 min=123 max=278
srg: median=164 p90=174 p95=176 min=146 max=221

Stress:                 166 PASS / 0 FAIL
Regression:             43 PASS / 0 FAIL
Black-box Regression:   58 PASS / 0 FAIL
RC Regression:          20 PASS / 0 FAIL
Agent UX Regression:    44 PASS / 0 FAIL（新增，含 199/200/201/1000 完整性边界）
Security Regression:    注入 0（S47/R24/U17d type-add 注入）、Long Query FP 0、副作用 0

Injection: 0
Long Query False Positive: 0
Legacy Encoding: 完整（UTF-8/BOM/UTF-16LE/BE 含 no BOM/GBK/SJIS/CP1252 显式 + 补搜 + 降噪）
Completeness: 199/200 complete，201/1000 truncated（text 与 JSON 双验证）
```

## Deliberate Changes（规格 §三十六 说明）

| 旧行为 | 新行为 | 原因 |
|---|---|---|
| legacy warning 列出编码清单（gbk/utf-16le/utf-16be/shift-jis/windows-1252...） | 一行通用 "Search may be incomplete: legacy/non-UTF-8 text files were detected. Use 'srg --help'..." | 规格 §二十二 明确要求：默认一行、不列编码清单、详细进 --debug；§二十四 禁止为安静删除风险提示（仅在探测无风险时安静） |
| 无匹配+非 ASCII 每次提示 | 纯 UTF-8 项目安静 exit 1；检测到 legacy 文件才提示（rg --files + 4KB 采样探测） | 规格 §二十/二十一：只有存在实际不完整风险时才提示 |
| `--json -l` 透传（rg 输出文本路径，JSON 契约静默失效） | 明确拒绝：exit 2 + 提示 | 规格 §四/二十七：无法可靠组合时明确拒绝，不静默降级 |
| `--no-column` 单文件行号消失（rg 行为） | 文本模式显式 -n，恒为 path:line:text | 输出契约稳定（§二十六） |
| `--type-add` 仅透传 | name 段白名单校验（字母数字 _ . -）+ 控制字符拒绝 | 防注入（§七）；值整体仍作为独立 argv |

## 回答（§四十 十问）

1. **Agent 日常调用预计多少场景不再需要 fallback rg？** 绝大多数内容搜索：普通搜索/文件列表（-l）/语言过滤（-t）/片段提取（-o）/智能大小写（-S）/ignored 内容（--no-ignore）/stdin/JSON 完整证明均已覆盖；仅剩计数、替换、着色、多 pattern、排序等专用场景需 rg。
2. **哪些常用 rg 功能仍明确不支持？** --files、-c/--count、--color、--heading、--pretty、--sort、-r/--replace、--pcre2、--no-messages、-e/--regexp、--max-count、--files-without-match、-L/--follow、--stats（暂缓）——全部给出明确 fallback 提示（非笼统"未知选项"）。
3. **Fast Path 实际提升多少？** ~1ms（165→164ms median）。核心开销为 AOT 启动（~30ms）与 rg 启动，禁止 daemon 前提下不可再降；手写行识别同时消除了正则依赖（AOT 友好）。
4. **是否增加新的安全风险？** 否。新增参数全部走白名单格式校验 + 独立 argv 传递；type-add 注入对抗测试通过（U17d：注入值作为单参数、无执行）；安全回归（注入/Literal/glob/type-add/regex/path 注入）全部 0。
5. **Legacy warning 是否减少但没有重新制造 silent false-negative？** 是。纯 UTF-8 项目安静；检测到非 UTF-8 文本文件（4KB 采样严格校验）才一行提示；补搜机制完全保留（U20a/b/c 验证）。
6. **-l/-o/-t/-S/--no-ignore 是否都经过组合测试？** 是。Suite E：-l+glob/type/regex/legacy/LongQuery；-o+regex/max-results/context/LongQuery拒绝；-t+glob/hidden/no-ignore；-S+显式冲突/大小写语义；共 17 项组合断言。
7. **Long Query 精确性是否完全未退化？** 是。S30-32（A）+ R25（C）+ U12（E，-l+Long Query anchor 诱饵）全过，假阳性 0；-l 模式全文验证后才输出文件。
8. **JSON completeness contract 是否完全未退化？** 是。恒输出 saferg-summary；199/200 complete vs 201/1000 truncated 双验证；-o JSON 与文本 match 数一致（U19b）；-l+JSON 明确拒绝不静默降级。
9. **是否建议正式发布 1.3.0？** 建议。五套件 331 项全绿，CRITICAL/HIGH=0，无已知未决缺陷。
10. **是否适合设置为 Codex/Claude Code/OpenCode/ZCode/TRAE 默认终端搜索工具？** 适合。绝大多数日常搜索不再需要 fallback；建议配置规则：内容搜索默认 srg；含特殊字符走 --stdin；exit 2 检查 stdout 部分结果；计数/替换等专用功能回退 rg。
