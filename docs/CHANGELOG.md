# SafeRG Changelog

## 1.3.2 — 2026-08-14

**修复：截断结果集完全确定性（BUG-R4-06，双 AI 强化 Round 4 闭环）**

- 主搜索新增 `--sort path`（rg ≥ 12，懒加载探测 `HasSortSupport`）：输出按路径字典序确定排序，
  消除 rg 并行遍历目录导致的顺序随机性。
- 与 1.3.1 的缓冲保全（`RunTruncationSafe`）配合，截断结果的 (文件→行数) 映射完全确定：
  5 次运行结果一致，且包含全部匹配文件（Tester 场景 `s_trunc_order` 通过，
  strength: `{'big.txt': 198, 'small1.txt': 1, 'small2.txt': 1}`）。
- `AnchorFiles`/`ListFiles`（集合语义）与 JSON/-l/Long Query 路径不加 `--sort`，零影响。

## 1.3.1 — 2026-08-14

**修复：截断保全——截断结果不再整体吞掉小文件（BUG-R3-06，双 AI 强化 Round 3 闭环）**

- 新增 `RunTruncationSafe`（text 模式 + `--max-results`）：缓冲前 N 个 match 行；
  溢出后继续消费流（`-m N+1` 保证每文件最多 N+1 行，消费有界），为每个新出现的文件保留首行；
  流结束时用"行数 > 1 的文件"的最后一行腾位。结果 ≤ N 行、包含全部匹配文件。
- JSON 模式（有 summary 契约）与 `-l` 模式保持原逻辑。
- 新增测试：`tests/optimizer-contract.ps1`（契约回归套件：broken_file_as_dir /
  cp1252 目录 warning / UTF-8 降噪 / unicode 命中 / 显式编码 / 截断保全与确定性）。
- 新增脚本：`scripts/build-candidate.ps1`（统一候选构建 + manifest.json，Orchestrator 用）。
