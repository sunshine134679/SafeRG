# SafeRG 统一 Candidate 构建脚本（Orchestrator 侧）
# 从 dev/ 源码构建 AOT 候选并生成 manifest.json（版本/提交/SHA-256/时间）。
# Developer 不得用手工复制代替本脚本；正式安装须在 Release Gate PASS 后执行。
# 用法: pwsh -NoProfile -File scripts\build-candidate.ps1 [-OutDir D:\SafeRG-Auto\candidate]
param(
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) '..\candidate')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent   # dev/
$out = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path + '\candidate'
if ($OutDir -ne (Join-Path (Split-Path $PSScriptRoot -Parent) '..\candidate')) {
    $out = $OutDir
}

$csproj = Join-Path $root 'src\SafeRG.csproj'
$version = ([xml](Get-Content $csproj -Raw)).Project.PropertyGroup.Version
$commit = git -C $root rev-parse --short HEAD
$tmp = Join-Path $env:TEMP ("srg-candidate-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    dotnet publish $csproj -c Release -r win-x64 -p:PublishAot=true `
        -p:PublishSingleFile=false -o $tmp | Out-Host
    $exe = Join-Path $tmp 'srg.exe'
    if (-not (Test-Path $exe)) { throw "构建产物缺失: $exe" }
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    Copy-Item $exe (Join-Path $out 'srg.exe') -Force
    $hash = (Get-FileHash (Join-Path $out 'srg.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        schema_version = 1
        version        = $version
        git_commit     = $commit
        built_at       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        sha256         = $hash
        path           = 'srg.exe'
    }
    $manifest | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $out 'manifest.json')
    Write-Output "Candidate: $out\srg.exe"
    Write-Output "version=$version commit=$commit sha256=$hash"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
