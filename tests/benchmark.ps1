# SafeRG 性能基准（§二十四）：PS7 / PS5.1 × warm / cold，交替 rg/srg，输出 Median/P90/P95/Min/Max
# 用法: pwsh -NoProfile -File tests\benchmark.ps1
# 注意：本脚本兼容 PowerShell 5.1 语法（无三元/?? 等 PS7 特性）

$ErrorActionPreference = 'Stop'
$srg = Join-Path $env:LOCALAPPDATA 'Programs\SafeRG\bin\srg.exe'
$rg = (Get-Command rg).Source
$work = Join-Path $env:TEMP ("srg-bench-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
1..200 | ForEach-Object {
    $txt = if ($_ % 10 -eq 0) { "BENCH_TARGET_$_ some filler content line" } else { 'ordinary filler line for benchmark' }
    [System.IO.File]::WriteAllText((Join-Path $work "f$_.txt"), $txt, [System.Text.UTF8Encoding]::new($false))
}

function Get-Stats($samples) {
    $arr = @($samples | Sort-Object)
    $n = $arr.Count
    $median = $arr[[int]($n / 2)]
    $p90 = $arr[[int]($n * 0.9)]
    $p95 = $arr[[int]($n * 0.95)]
    if ($p95 -ge $n) { $p95 = $n - 1 }
    [pscustomobject]@{ Median = $median; P90 = $p90; P95 = $p95; Min = $arr[0]; Max = $arr[-1] }
}

function Measure-Warm($toolPath, $label, $samples) {
    $sw = [System.Diagnostics.Stopwatch]::new()
    for ($i = 0; $i -lt $samples; $i++) {
        $sw.Restart()
        $null = & $toolPath 'BENCH_TARGET' $work 2>$null
        $sw.Stop()
        $script:results += [pscustomobject]@{ Mode = $label; ms = $sw.ElapsedMilliseconds }
    }
}

function Measure-Cold($toolPath, $shell, $label, $samples) {
    for ($i = 0; $i -lt $samples; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::new()
        $sw.Start()
        $p = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-Command', "& '$toolPath' 'BENCH_TARGET' '$work' | Out-Null") -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $env:TEMP 'srg-bench-cold.out') -RedirectStandardError (Join-Path $env:TEMP 'srg-bench-cold.err')
        $sw.Stop()
        $script:results += [pscustomobject]@{ Mode = $label; ms = $sw.ElapsedMilliseconds }
    }
}

$script:results = [System.Collections.Generic.List[object]]::new()

# ---- PS7 ----
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    Measure-Warm $rg  'PS7-warm-rg'  50
    Measure-Warm $srg 'PS7-warm-srg' 50
    Measure-Cold $rg  (Get-Command pwsh).Source 'PS7-cold-rg'  5
    Measure-Cold $srg (Get-Command pwsh).Source 'PS7-cold-srg' 5
}
# ---- PS5.1 ----
if (Get-Command powershell -ErrorAction SilentlyContinue) {
    Measure-Warm $rg  'PS5-warm-rg'  50
    Measure-Warm $srg 'PS5-warm-srg' 50
    Measure-Cold $rg  (Get-Command powershell).Source 'PS5-cold-rg'  5
    Measure-Cold $srg (Get-Command powershell).Source 'PS5-cold-srg' 5
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("{0,-14} {1,8} {2,8} {3,8} {4,8} {5,8}" -f 'Mode', 'Median', 'P90', 'P95', 'Min', 'Max')
Write-Host ("{0,-14} {1,8} {2,8} {3,8} {4,8} {5,8}" -f '----------', '------', '----', '----', '---', '---')
foreach ($mode in @('PS7-warm-rg','PS7-warm-srg','PS7-cold-rg','PS7-cold-srg','PS5-warm-rg','PS5-warm-srg','PS5-cold-rg','PS5-cold-srg')) {
    $s = @($results | Where-Object { $_.Mode -eq $mode } | ForEach-Object { $_.ms })
    if ($s.Count -gt 0) {
        $st = Get-Stats $s
        Write-Host ("{0,-14} {1,8} {2,8} {3,8} {4,8} {5,8}" -f $mode, $st.Median, $st.P90, $st.P95, $st.Min, $st.Max)
    }
}
