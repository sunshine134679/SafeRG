# SafeRG Optimizer 契约回归套件（Round 2 audit 固化）
# 固化 2026-08-14 round-002 审计确认的契约行为，防止未来回归：
#   1) broken_file_as_dir（文件路径带尾随 '\'）-> exit 1 静默（与原生 rg 相同，
#      INHERITED_RG，不视为 Bug）
#   2) cp1252 目录自动探测 -> exit 1 + 单行 legacy warning（warning 优于错误识别）
#   3) 纯 UTF-8 无匹配 -> exit 1 且无 warning（legacy 降噪契约）
#   4) unicode（中/日/韩/俄/希/阿/emoji）搜索正常命中
#   5) cp1252 显式 --encoding 命中；单文件 cp1252 自动补搜 ASCII 命中
# 用法: pwsh -NoProfile -File tests\optimizer-contract.ps1 [-Srg 路径]
param(
    [string]$Srg = (Join-Path $env:LOCALAPPDATA 'Programs\SafeRG\bin\srg.exe')
)
$ErrorActionPreference = 'Stop'
$script:Srg = (Resolve-Path $Srg).Path
if (-not (Test-Path $script:Srg)) { throw "未找到 srg.exe: $script:Srg" }
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, [string]$Status, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}
function Pass([string]$Name, [string]$Detail = '') { Add-Result $Name 'PASS' $Detail }
function Fail([string]$Name, [string]$Detail) { Add-Result $Name 'FAIL' $Detail }
function Test([string]$Name, [scriptblock]$Body, [string]$Detail = '') {
    try { & $Body; Pass $Name $Detail } catch { Fail $Name ($_.Exception.Message) }
}
function Invoke-Srg {
    param([string[]]$SrgArgs = @())
    $out = & $script:Srg @SrgArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = (($out | ForEach-Object { $_.ToString() }) -join "`n") }
}
function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllBytes($Path, [System.Text.UTF8Encoding]::new($false).GetBytes($Text))
}

$work = Join-Path $env:TEMP ("srg-contract-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    # ---- 1) broken_file_as_dir 契约（INHERITED_RG，与原生 rg 完全一致） ----
    # 真实传参（保留尾随 '\'）：srg 与 rg 均报 os error 267 -> exit 2 + 错误信息
    # （非静默、可感知）。audit 记录的 exit=1 系 Tester 参数传递吞掉尾随反斜杠、
    # 且 fixture 不含查询词所致；无论哪种传参 srg 都不比 rg 差。
    Test '文件+尾随反斜杠 -> exit 2 + 错误信息（与 rg 相同，非静默）' {
        $f = Join-Path $work 'broken_file_as_dir'
        Write-Utf8 $f "line needle`n"
        $r = Invoke-Srg @('needle', ($f + '\'))
        if ($r.Code -ne 2) { throw "期望 exit 2，实际 $($r.Code) out=$($r.Out)" }
        if ($r.Out -notmatch 'os error') { throw "期望错误信息含 os error: $($r.Out)" }
    }
    Test '文件+尾随反斜杠 --json -> exit 2 + 错误信息' {
        $f = Join-Path $work 'broken_file_as_dir2'
        Write-Utf8 $f "line needle`n"
        $r = Invoke-Srg @('--json', 'needle', ($f + '\'))
        if ($r.Code -ne 2) { throw "期望 exit 2，实际 $($r.Code) out=$($r.Out)" }
        if ($r.Out -notmatch 'os error') { throw "期望错误信息含 os error: $($r.Out)" }
    }
    Test '同文件无反斜杠 -> 正常命中（对照）' {
        $f = Join-Path $work 'broken_file_as_dir3'
        Write-Utf8 $f "line needle`n"
        $r = Invoke-Srg @('needle', $f)
        if ($r.Code -ne 0) { throw "期望 exit 0，实际 $($r.Code) out=$($r.Out)" }
    }

    # ---- 2) cp1252 目录自动探测 -> 单行 warning ----
    Test 'cp1252 目录自动探测 exit 1 + 单行 warning' {
        $d = Join-Path $work 'cp1252dir'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $cp = [System.Text.Encoding]::GetEncoding(1252)
        [System.IO.File]::WriteAllBytes(
            (Join-Path $d 'a.txt'), $cp.GetBytes('café résumé needle_cp'))
        $r = Invoke-Srg @('中文查询', $d)
        if ($r.Code -ne 1) { throw "期望 exit 1，实际 $($r.Code) out=$($r.Out)" }
        if ($r.Out -notmatch 'Search may be incomplete') { throw "缺少 legacy warning: $($r.Out)" }
        $warnLines = ($r.Out -split "`n" | Where-Object { $_ -match 'Search may be incomplete' }).Count
        if ($warnLines -ne 1) { throw "warning 应为单行，实际 $warnLines 行" }
    }

    # ---- 3) 纯 UTF-8 降噪 ----
    Test '纯 UTF-8 无匹配 exit 1 且无 warning' {
        $f = Join-Path $work 'utf8.txt'
        Write-Utf8 $f "plain ascii line`n"
        $r = Invoke-Srg @('zzz_no_match_zzz', $f)
        if ($r.Code -ne 1) { throw "期望 exit 1，实际 $($r.Code)" }
        if ($r.Out -match 'Search may be incomplete') { throw "不应出现 legacy warning: $($r.Out)" }
    }

    # ---- 4) unicode 正常命中（反证 Tester uni_* 崩溃非 SafeRG 缺陷） ----
    $uni = [ordered]@{
        zh_cn = '中文测试 needle_uni 日本語'
        ja    = '日本語 needle_uni テスト'
        ko    = '한국어 needle_uni 테스트'
        ru    = 'русский needle_uni тест'
        el    = 'ελληνικά needle_uni'
        ar    = 'العربية needle_uni'
        emoji = 'emoji 🚀🔥 needle_uni'
    }
    foreach ($k in $uni.Keys) {
        Test ("unicode/$k 命中 (exit 0)") {
            $f = Join-Path $work ("u_$k.txt")
            Write-Utf8 $f ($uni[$k] + "`n")
            $r = Invoke-Srg @('needle_uni', $f)
            if ($r.Code -ne 0) { throw "期望 exit 0，实际 $($r.Code) out=$($r.Out)" }
        }
    }

    # ---- 5) cp1252 显式指定 / 单文件自动补搜 ----
    Test 'cp1252 显式 --encoding cp1252 命中' {
        $d = Join-Path $work 'cp1252dir2'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $cp = [System.Text.Encoding]::GetEncoding(1252)
        $f = Join-Path $d 'a.txt'
        [System.IO.File]::WriteAllBytes($f, $cp.GetBytes('café résumé needle_cp'))
        $r = Invoke-Srg @('--encoding', 'cp1252', 'needle_cp', $f)
        if ($r.Code -ne 0) { throw "期望 exit 0，实际 $($r.Code) out=$($r.Out)" }
    }
    Test '单文件 cp1252 ASCII 查询自动补搜命中' {
        $f = Join-Path $work 'cp_single.txt'
        $cp = [System.Text.Encoding]::GetEncoding(1252)
        [System.IO.File]::WriteAllBytes($f, $cp.GetBytes('café résumé needle_cp'))
        $r = Invoke-Srg @('needle_cp', $f)
        if ($r.Code -ne 0) { throw "期望 exit 0，实际 $($r.Code) out=$($r.Out)" }
    }

    # ---- 6) 截断保全（BUG-R3-06 regression） ----
    # rg 并行遍历目录使输出顺序不稳定；截断结果必须包含全部匹配文件，
    # 且 5 次运行文件集一致（不让 Agent 误判缺失文件无匹配）。
    Test '截断保全: 多文件截断结果含全部文件 + 截断提示 + ≤200 行' {
        $d = Join-Path $work 'trunc_dir'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $big = (0..200 | ForEach-Object { "big line $_ needle" }) -join "`n"
        $s1 = (0..5 | ForEach-Object { "s1 line $_ needle" }) -join "`n"
        $s2 = (0..2 | ForEach-Object { "s2 line $_ needle" }) -join "`n"
        Write-Utf8 (Join-Path $d 'big.txt') ($big + "`n")
        Write-Utf8 (Join-Path $d 'small1.txt') ($s1 + "`n")
        Write-Utf8 (Join-Path $d 'small2.txt') ($s2 + "`n")
        $r = Invoke-Srg @('needle', $d)
        if ($r.Out -notmatch 'big\.txt') { throw "结果缺 big.txt" }
        if ($r.Out -notmatch 'small1\.txt') { throw "结果缺 small1.txt" }
        if ($r.Out -notmatch 'small2\.txt') { throw "结果缺 small2.txt" }
        if ($r.Out -notmatch 'Results truncated') { throw "缺少截断提示: $($r.Out)" }
        $matchLines = @($r.Out -split "`n" | Where-Object { $_ -match ':\d+:\d+:' }).Count
        if ($matchLines -gt 200) { throw "match 行 $matchLines > 200" }
    }
    Test '截断保全: 5 次运行 (文件→行数) 映射完全一致（Tester distinct 判定）' {
        $d = Join-Path $work 'trunc_dir3'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $big = (0..200 | ForEach-Object { "big line $_ needle" }) -join "`n"
        $s1 = (0..5 | ForEach-Object { "s1 line $_ needle" }) -join "`n"
        $s2 = (0..2 | ForEach-Object { "s2 line $_ needle" }) -join "`n"
        Write-Utf8 (Join-Path $d 'big.txt') ($big + "`n")
        Write-Utf8 (Join-Path $d 'small1.txt') ($s1 + "`n")
        Write-Utf8 (Join-Path $d 'small2.txt') ($s2 + "`n")
        $maps = @()
        for ($i = 1; $i -le 5; $i++) {
            $r = Invoke-Srg @('needle', $d)
            $map = @{}
            foreach ($ln in ($r.Out -split "`n")) {
                if ($ln -match '^(.+):\d+:\d+:') {
                    $name = [System.IO.Path]::GetFileName($Matches[1])
                    $map[$name] = [int]$map[$name] + 1
                }
            }
            $maps += , $map
        }
        $first = $maps[0] | ConvertTo-Json -Compress
        if ($first -notmatch 'small1') { throw "映射缺 small1: $first" }
        if ($first -notmatch 'small2') { throw "映射缺 small2: $first" }
        for ($i = 1; $i -lt 5; $i++) {
            $cur = $maps[$i] | ConvertTo-Json -Compress
            if ($cur -ne $first) { throw "run$i 映射不一致: $cur vs $first" }
        }
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

$passed = @($results | Where-Object Status -eq 'PASS').Count
$failed = @($results | Where-Object Status -eq 'FAIL').Count
foreach ($r in $results) { Write-Output ("{0,-5} {1}" -f $r.Status, $r.Name) }
Write-Output ("optimizer-contract: {0} PASS / {1} FAIL" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
