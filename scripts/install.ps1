# SafeRG 安装脚本：把 srg.exe 复制到 %LOCALAPPDATA%\Programs\SafeRG\bin，
# 并【增量】追加到当前用户 User PATH（不覆盖已有 PATH，不修改 System PATH，不依赖 $PROFILE）。
param(
    [string]$SourceExe = '',
    [string]$InstallRoot = ''
)
$ErrorActionPreference = 'Stop'

if (-not $InstallRoot) { $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\SafeRG' }
if (-not $SourceExe) { $SourceExe = Join-Path $PSScriptRoot '..\artifacts\srg.exe' }
if (-not (Test-Path $SourceExe)) { throw "找不到 srg.exe: $SourceExe（请先 dotnet publish）" }
$SourceExe = (Resolve-Path $SourceExe).Path

$bin = Join-Path $InstallRoot 'bin'
$target = Join-Path $bin 'srg.exe'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
Copy-Item -Path $SourceExe -Destination $target -Force
Write-Host "[install] 已复制: $SourceExe"
Write-Host "[install]     ->  $target"

# ---- 增量加入 User PATH（只追加缺失项，其余原样保留）----
$normBin = $bin.TrimEnd('\')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$parts = [System.Collections.Generic.List[string]]::new()
if (-not [string]::IsNullOrEmpty($userPath)) {
    foreach ($p in ($userPath -split ';')) {
        $t = $p.Trim().TrimEnd('\')
        if ($t -ne '') { $parts.Add($t) }
    }
}
if ($parts -contains $normBin) {
    Write-Host "[install] User PATH 已包含 $normBin，无需修改"
} else {
    $parts.Add($normBin)
    [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
    Write-Host "[install] 已增量追加到 User PATH: $normBin"
    Write-Host "[install] 提示：已打开的终端需要重启后生效；新开的 PowerShell/CMD/Windows Terminal 立即可用"
}

# ---- 自检 ----
& $target --version
if ($LASTEXITCODE -ne 0) { throw "srg.exe 自检失败（exit=$LASTEXITCODE）" }
Write-Host ""
Write-Host "[install] 完成。安装位置: $target"
Write-Host "[install] 当前 User PATH:"
[Environment]::GetEnvironmentVariable('Path', 'User')
