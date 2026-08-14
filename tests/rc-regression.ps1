# SafeRG 1.2.0 RC Final Regression（Suite D）
# RC001-RC017：Long Query partial、UTF-16BE 目录、-C1、JSON summary、混合分隔符等
# 用法: pwsh -NoProfile -File tests\rc-regression.ps1

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }

$script:Srg = Join-Path $env:LOCALAPPDATA 'Programs\SafeRG\bin\srg.exe'
if (-not (Test-Path $script:Srg)) { throw "未找到 srg.exe: $script:Srg" }

$root = Join-Path $env:TEMP ("SafeRG-RC-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, [string]$Status, [string]$Detail = '') { $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }) }
function Pass([string]$Name) { Add-Result $Name 'PASS' }
function Fail([string]$Name, [string]$Detail) { Add-Result $Name 'FAIL' $Detail }
function Skip([string]$Name, [string]$Detail) { Add-Result $Name 'SKIP' $Detail }
function Test([string]$Name, [scriptblock]$Body) { try { & $Body; Pass $Name } catch { Fail $Name ($_.Exception.Message) } }
function Assert([bool]$Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }
function Write-Utf8([string]$Path, [string]$Text) { [System.IO.File]::WriteAllBytes($Path, [System.Text.UTF8Encoding]::new($false).GetBytes($Text)) }

function Invoke-Srg {
    param([string[]]$SrgArgs = @(), [string]$Stdin = '')
    if ($PSBoundParameters.ContainsKey('Stdin')) {
        $out = $Stdin | & $script:Srg '--stdin' @SrgArgs 2>&1
    } else {
        $out = & $script:Srg @SrgArgs 2>&1
    }
    $code = $LASTEXITCODE
    [pscustomobject]@{ Code = $code; Out = (($out | ForEach-Object { $_.ToString() }) -join "`n") }
}
function Out-Snippet([string]$s) { if ($s.Length -le 300) { return $s } return $s.Substring(0, 300) + '…' }

$who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$denyDir = $null

try {
    # ===== 夹具 =====
    Write-Utf8 (Join-Path $root 'plain.txt') "hello world`nSecondhandItem`nTARGET_NEEDLE`nTARGET_SECOND"
    Write-Utf8 (Join-Path $root 'ctx6.txt') "line1`nline2`nTARGET_CONTEXT_LINE`nline4`nline5`nline6"
    # 长 Query（RC001）
    $lq = '// RC001_HEAD_' + ('a' * 6600) + '_RC001_TAIL'
    Write-Utf8 (Join-Path $root 'lq_full.txt') $lq
    Write-Utf8 (Join-Path $root 'lq_query.txt') $lq
    # legacy 编码夹具
    [System.IO.File]::WriteAllBytes((Join-Path $root 'be.txt'), [System.Text.Encoding]::BigEndianUnicode.GetBytes('UTF16BE中文目标文本支付成功'))
    [System.IO.File]::WriteAllBytes((Join-Path $root 'le.txt'), [System.Text.Encoding]::Unicode.GetBytes('UTF16LE中文目标文本支付成功'))
    [System.IO.File]::WriteAllBytes((Join-Path $root 'gbk.txt'), [System.Text.Encoding]::GetEncoding(936).GetBytes('GBK中文目标文本交易完成'))
    [System.IO.File]::WriteAllBytes((Join-Path $root 'cp1252.txt'), [System.Text.Encoding]::GetEncoding(1252).GetBytes('CP1252 café €100 完成'))
    [System.IO.File]::WriteAllBytes((Join-Path $root 'sjis.txt'), [System.Text.Encoding]::GetEncoding(932).GetBytes('ShiftJIS日本語テスト'))

    # ===== RC001: Long Query + 不可读目录 =====
    $denyDir = Join-Path $root 'deny'
    New-Item -ItemType Directory -Path $denyDir | Out-Null
    Write-Utf8 (Join-Path $denyDir 'secret.txt') 'rc001 secret'
    $denyWorks = $false
    & icacls $denyDir /deny "${who}:(R)" 2>&1 | Out-Null
    try { $null = [System.IO.Directory]::GetFiles($denyDir) } catch { $denyWorks = $true }
    if ($denyWorks) {
        $r = Invoke-Srg @('--query-file', (Join-Path $root 'lq_query.txt'), $root)
        Test 'RC001 Long Query+IO错误：保留匹配+exit2' {
            Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）"
            Assert ($r.Out -match 'lq_full\.txt') 'stdout 丢失了完整匹配！'
            Assert ($r.Out -match 'denied|拒绝访问|deny') '缺少错误提示'
        }
        $r = Invoke-Srg @('TARGET_NEEDLE', $root)
        Test 'RC002 短查询+IO错误：stdout匹配+exit2' {
            Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2，INHERITED-RG 语义）"
            Assert ($r.Out -match 'plain\.txt') 'stdout 丢失匹配！'
        }
        $r = Invoke-Srg @('--json', 'TARGET_NEEDLE', $root)
        Test 'RC016 JSON partial+IO错误 summary' {
            Assert ($r.Out -match '"type":"match"') '缺少 match 事件'
            Assert ($r.Out -match '"type":"saferg-summary","complete":false') 'summary 未表达 complete=false'
            Assert ($r.Out -match '"had_errors":true') 'summary 未表达 had_errors=true'
        }
    } else {
        Skip 'RC001 Long Query+IO错误' '当前为管理员，ACL deny 不生效'
        Skip 'RC002 短查询+IO错误' '同上'
        Skip 'RC016 JSON partial+IO错误' '同上'
    }
    & icacls $denyDir /remove:d $who 2>&1 | Out-Null

    # ===== RC003-RC007: legacy 编码显式/目录/文件 =====
    $r = Invoke-Srg @('支付成功', (Join-Path $root 'be.txt'))
    Test 'RC003 UTF-16BE no BOM 显式文件' { Assert ($r.Code -eq 0 -and $r.Out -match 'be\.txt') "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('支付成功', $root)
    Test 'RC004 UTF-16BE no BOM 目录（与 LE 共存）' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'be\.txt') 'BE 被漏检！'
        Assert ($r.Out -match 'le\.txt') 'LE 应同时命中'
    }
    $r = Invoke-Srg @('支付成功', (Join-Path $root 'le.txt'))
    Test 'RC005 UTF-16LE no BOM 显式文件' { Assert ($r.Code -eq 0 -and $r.Out -match 'le\.txt') "code=$($r.Code)" }
    $r = Invoke-Srg @('交易完成', $root)
    Test 'RC007 GBK 显式+目录' { Assert ($r.Code -eq 0 -and $r.Out -match 'gbk\.txt') "code=$($r.Code)" }

    # ===== RC008: CP1252（西欧编码，用 é/€；不自动识别，宁缺毋滥） =====
    $r = Invoke-Srg @('--encoding', 'windows-1252', 'café', (Join-Path $root 'cp1252.txt'))
    Test 'RC008a CP1252 显式 --encoding' { Assert ($r.Code -eq 0 -and $r.Out -match 'cp1252\.txt') "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('café', (Join-Path $root 'cp1252.txt'))
    Test 'RC008b CP1252 不自动误判（无结果+一行 warning）' {
        Assert ($r.Code -eq 1) "code=$($r.Code)（CP1252 不自动识别，宁缺毋滥）"
        Assert ($r.Out -match 'Search may be incomplete') "缺风险提示: $(Out-Snippet $r.Out)"
        Assert (([regex]::Matches($r.Out, 'Search may be incomplete')).Count -eq 1) 'warning 超过一行'
    }

    # ===== RC009/RC010: Shift-JIS =====
    $r = Invoke-Srg @('--encoding', 'shift-jis', '日本語', (Join-Path $root 'sjis.txt'))
    Test 'RC009 Shift-JIS 显式 --encoding' { Assert ($r.Code -eq 0 -and $r.Out -match 'sjis\.txt') "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('日本語', $root)
    Test 'RC010 Shift-JIS 无匹配时一行 warning' {
        Assert ($r.Code -eq 1) "code=$($r.Code)"
        Assert ($r.Out -match 'Search may be incomplete') "缺风险提示: $(Out-Snippet $r.Out)"
    }

    # ===== RC011-RC013: -CN 兼容 =====
    $r = Invoke-Srg @('-C1', 'TARGET_CONTEXT_LINE', (Join-Path $root 'ctx6.txt'))
    Test 'RC011 -C1 紧凑形式' { Assert ($r.Code -eq 0 -and $r.Out -match 'line2' -and $r.Out -match 'line4' -and $r.Out -notmatch 'line5') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('-C0', 'TARGET_CONTEXT_LINE', (Join-Path $root 'ctx6.txt'))
    Test 'RC012 -C0 无上下文' { Assert ($r.Code -eq 0 -and $r.Out -notmatch 'line2') "out=$(Out-Snippet $r.Out)" }
    foreach ($bad in @('-Cabc', '-C-1', '-C999999999999')) {
        $r = Invoke-Srg @($bad, 'x', (Join-Path $root 'plain.txt'))
        Test "RC013 $bad 友好报错 exit=2" { Assert ($r.Code -eq 2) "code=$($r.Code)"; Assert ($r.Out -match '非负整数') "提示: $(Out-Snippet $r.Out)" }
    }

    # ===== RC014/RC015: JSON summary 恒输出 =====
    $r = Invoke-Srg @('--json', 'TARGET_NEEDLE', (Join-Path $root 'plain.txt'))
    Test 'RC014 JSON 完整 summary' {
        Assert ($r.Out -match '"type":"saferg-summary","complete":true') "缺少 complete summary: $(Out-Snippet $r.Out)"
        Assert ($r.Out -match '"truncated":false') 'truncated 应为 false'
        Assert ($r.Out -match '"had_errors":false') 'had_errors 应为 false'
    }
    $r = Invoke-Srg @('--json', '--max-results', '1', 'TARGET_', (Join-Path $root 'plain.txt'))
    Test 'RC015 JSON 截断 summary' {
        Assert ($r.Out -match '"type":"saferg-summary","complete":false') 'summary 未表达 complete=false'
        Assert ($r.Out -match '"truncated":true') 'truncated 应为 true'
    }

    # ===== RC017: 混合分隔符错误规范化 =====
    $r = Invoke-Srg @('x', 'Z:\NO_SUCH_DIR_9281')
    Test 'RC017 错误路径分隔符统一 /' { Assert ($r.Out -notmatch '\\\\') "错误路径含反斜杠: $(Out-Snippet $r.Out)" }

    # ===== JSON NDJSON 契约（一行一个对象） =====
    $r = Invoke-Srg @('--json', 'TARGET_NEEDLE', (Join-Path $root 'plain.txt'))
    $lines = @($r.Out -split "`n" | Where-Object { $_.Trim() -ne '' })
    Test 'RC020 JSON NDJSON 每行一个对象' {
        Assert ($lines.Count -ge 3) "行数=$($lines.Count)"
        foreach ($ln in $lines) {
            Assert ($ln.Trim().StartsWith('{') -and $ln.Trim().EndsWith('}')) "非 JSON 行: $(Out-Snippet $ln)"
        }
    }
}
finally {
    if ($denyDir) { & icacls $denyDir /remove:d $who 2>&1 | Out-Null }
    Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========== SafeRG RC Regression (Suite D) =========="
$fails = 0
foreach ($r in $results) {
    if ($r.Status -eq 'FAIL') { $fails++ }
    $marker = if ($r.Status -eq 'PASS') { '[PASS]' } else { if ($r.Status -eq 'SKIP') { '[SKIP]' } else { '[FAIL]' } }
    $line = "{0} {1}" -f $marker, $r.Name
    if ($r.Detail) { $line += "  -> $($r.Detail)" }
    Write-Host $line
}
$passes = $results.Count - $fails - (@($results | Where-Object { $_.Status -eq 'SKIP' }).Count)
$skips = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
Write-Host ""
Write-Host ("Suite D: {0} PASS / {1} FAIL / {2} SKIP" -f $passes, $fails, $skips)
exit $fails
