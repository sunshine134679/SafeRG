# 对照实验：43 个测试改用原生 rg 执行，看能通过多少
# 等价写法（Agent 对 rg 的合理用法）：
#   - 位置参数查询    -> rg <pattern> <path>（rg 默认正则模式）
#   - STDIN 查询      -> <内容> | rg -f - <path>（rg 从 stdin 读 pattern，每行一个）
#   - query-file      -> rg -f <file> <path>
# 断言与 run-tests.ps1 完全一致；SafeRG 特有安装验证类测试（T41/T42/T43）改用 rg 本身验证。

$ErrorActionPreference = 'Stop'
$script:Rg = (Get-Command rg -ErrorAction Stop).Source
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

function Invoke-Rg {
    param([string[]]$Args2 = @(), [string]$Stdin = '')
    if (-not [string]::IsNullOrEmpty($Stdin)) {
        $out = $Stdin | & $script:Rg '-f' '-' @Args2 2>&1
    } else {
        $out = & $script:Rg @Args2 2>&1
    }
    $code = $LASTEXITCODE
    [pscustomobject]@{ Code = $code; Out = (($out | ForEach-Object { $_.ToString() }) -join "`n") }
}
function Out-Snippet([string]$s) { if ($s.Length -le 400) { return $s } return $s.Substring(0, 400) + '…' }
function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllBytes($Path, [System.Text.UTF8Encoding]::new($false).GetBytes($Text))
}

$root = Join-Path $env:TEMP ("RgCompare-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
try {
    Write-Utf8 (Join-Path $root 'cn.txt')      '这是交易完成后的系统消息'
    Write-Utf8 (Join-Path $root 'dollar.txt')  '$user = Get-User $id'
    Write-Utf8 (Join-Path $root 'json.txt')    '"name": "张三"'
    Write-Utf8 (Join-Path $root 'single.txt')  "'hello'"
    Write-Utf8 (Join-Path $root 'backtick.txt') 'a`b'
    Write-Utf8 (Join-Path $root 'pipe.txt')    'foo | bar'
    Write-Utf8 (Join-Path $root 'regexchars.txt') 'user.name[0]'
    Write-Utf8 (Join-Path $root 'foo123.txt')  'foo123'
    Write-Utf8 (Join-Path $root 'emoji.txt')   'emoji 🚀 完成'
    Write-Utf8 (Join-Path $root 'case.txt')    'HelloWorld'
    Write-Utf8 (Join-Path $root 'bom.txt')     'BOM中文'
    $u16 = [System.Text.Encoding]::Unicode
    $utf16Bytes = [byte[]]($u16.GetPreamble() + $u16.GetBytes('unicode中文'))
    [System.IO.File]::WriteAllBytes((Join-Path $root 'utf16.txt'), $utf16Bytes)

    $spDir = Join-Path $root 'Test Project';  New-Item -ItemType Directory $spDir | Out-Null
    $cnDir = Join-Path $root '测试项目';       New-Item -ItemType Directory $cnDir | Out-Null
    $hidDir = Join-Path $root '.hid';         New-Item -ItemType Directory $hidDir | Out-Null
    Write-Utf8 (Join-Path $spDir 'sp.txt')    'spacetext in path with spaces'
    Write-Utf8 (Join-Path $cnDir 'cnpath.txt') '中文路径内容'
    Write-Utf8 (Join-Path $hidDir 'h.txt')    'hiddentext'

    Write-Utf8 (Join-Path $root 'a.java')     'globtext java'
    Write-Utf8 (Join-Path $root 'b.cs')       'globtext csharp'
    Write-Utf8 (Join-Path $root 'ctx.txt')    (('ctx line1','ctx line2','needle here','ctx line4','ctx line5') -join "`n")

    $multiLines = @('public void login() {', '    System.out.println("登录成功");', '}')
    Write-Utf8 (Join-Path $root 'multi-lf.txt')   ($multiLines -join "`n")
    Write-Utf8 (Join-Path $root 'multi-crlf.txt') ($multiLines -join "`r`n")
    Write-Utf8 (Join-Path $root 'query.txt')      ($multiLines -join "`n")

    $longQ = "// SafeRG-LONG-BEGIN-9f3a2c`n" + ('x' * 10000) + "`n// SafeRG-LONG-END-5b7d1e"
    Write-Utf8 (Join-Path $root 'long.txt')       $longQ
    Write-Utf8 (Join-Path $root 'longquery.txt')  $longQ
    $longSingle = "// SafeRG-SINGLE-BEGIN-77aa " + ('y' * 9000) + " // SafeRG-SINGLE-END-88bb"
    Write-Utf8 (Join-Path $root 'longsingle.txt') $longSingle

    for ($i = 1; $i -le 30; $i++) { Write-Utf8 (Join-Path $root ("f{0:d2}.txt" -f $i)) "truncword file $i" }

    $mixed = @'
"a" $b 'c' `d | & ; ( ) [ ] { } \
'@
    Write-Utf8 (Join-Path $root 'mixed.txt') $mixed

    # ---------- 逐条测试（rg 等价写法） ----------

    $r = Invoke-Rg @('交易完成', $root)
    Test 'T01 中文（位置参数）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'cn\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg -Stdin '交易完成' @($root)
    Test 'T02 中文（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'cn\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('$user', $root)
    Test 'T03 美元符号 $user' { if (-not ($r.Code -eq 0 -and $r.Out -match 'dollar\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg -Stdin '"name": "张三"' @($root)
    Test 'T04 双引号（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'json\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg @('"name": "张三"', $root)
    Test 'T05 双引号（位置参数）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'json\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @("'hello'", $root)
    Test 'T06 单引号' { if (-not ($r.Code -eq 0 -and $r.Out -match 'single\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg -Stdin 'a`b' @($root)
    Test 'T07 反引号（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'backtick\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg @('a`b', $root)
    Test 'T08 反引号（位置参数）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'backtick\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg -Stdin 'foo | bar' @($root)
    Test 'T09 管道符（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'pipe\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('user.name[0]', $root)
    Test 'T10 正则字符字面量 user.name[0]' { if (-not ($r.Code -eq 0 -and $r.Out -match 'regexchars\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('spacetext', $spDir)
    Test 'T11 路径带空格' { if (-not ($r.Code -eq 0 -and $r.Out -match 'sp\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg @('中文路径内容', $cnDir)
    Test 'T12 中文路径' { if (-not ($r.Code -eq 0 -and $r.Out -match 'cnpath\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $q = $multiLines -join "`n"
    $r = Invoke-Rg -Stdin $q @($root)
    Test 'T13 多行 LF 文件' { if (-not ($r.Code -eq 0 -and $r.Out -match 'multi-lf\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    Test 'T14 多行 CRLF 文件' { if (-not ($r.Code -eq 0 -and $r.Out -match 'multi-crlf\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg @('-f', (Join-Path $root 'query.txt'), $root)
    Test 'T15 多行 query-file' { if (-not ($r.Code -eq 0 -and $r.Out -match 'multi-lf\.txt' -and $r.Out -match 'multi-crlf\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg -Stdin $longQ @($root)
    Test 'T16 超长多行（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'long\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg -Stdin $longSingle @($root)
    Test 'T17 超长单行（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'longsingle\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg @('-f', (Join-Path $root 'longquery.txt'), $root)
    Test 'T18 超长 query-file' { if (-not ($r.Code -eq 0 -and $r.Out -match 'longquery\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('zzz_nonexistent_7f3a9', $root)
    Test 'T19 无匹配 exit=1' { if ($r.Code -ne 1) { throw "code=$($r.Code)（应为 1）" } }
    $r = Invoke-Rg @('x', 'C:\NoSuchDir_RgCompare_9f3')
    Test 'T20 错误路径 exit=2' { if ($r.Code -ne 2) { throw "code=$($r.Code)（应为 2）" } }

    $r = Invoke-Rg @('user\.name\[0\]', $root)
    Test 'T21 Regex 模式' { if (-not ($r.Code -eq 0 -and $r.Out -match 'regexchars\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg @('foo\d+', $root)
    Test 'T22 Regex foo\d+' { if (-not ($r.Code -eq 0 -and $r.Out -match 'foo123\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('helloworld', $root)
    Test 'T23 默认区分大小写' { if ($r.Code -ne 1) { throw "code=$($r.Code)（应为 1，rg 默认 smart-case 会匹配 HelloWorld）" } }
    $r = Invoke-Rg @('-i', 'helloworld', $root)
    Test 'T24 --ignore-case' { if (-not ($r.Code -eq 0)) { throw "code=$($r.Code)" } }
    $r = Invoke-Rg @('--case-sensitive', 'HelloWorld', $root)
    Test 'T25 --case-sensitive' { if (-not ($r.Code -eq 0)) { throw "code=$($r.Code)" } }
    $r = Invoke-Rg @('helloworld', $root)
    Test 'T26 Regex 默认区分大小写' { if ($r.Code -ne 1) { throw "code=$($r.Code)（应为 1，smart-case）" } }
    $r = Invoke-Rg @('-i', 'helloworld', $root)
    Test 'T27 Regex + -i' { if (-not ($r.Code -eq 0)) { throw "code=$($r.Code)" } }

    $r = Invoke-Rg @('--max-results', '5', 'truncword', $root)
    $matchLines = ([regex]::Matches($r.Out, ':truncword')).Count
    Test 'T28 --max-results 截断' { if (-not ($matchLines -eq 5 -and $r.Out -match 'Results truncated')) { throw "匹配行=$matchLines（应为5） notice=$( $r.Out -match 'Results truncated' )" } }

    $r = Invoke-Rg @('hiddentext', $root)
    Test 'T29 默认忽略隐藏' { if ($r.Code -ne 1) { throw "code=$($r.Code)（应为 1）" } }
    $r = Invoke-Rg @('--hidden', 'hiddentext', $root)
    Test 'T30 --hidden 搜索隐藏' { if (-not ($r.Code -eq 0 -and $r.Out -match 'h\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('globtext', $root, '--glob', '*.java')
    Test 'T31 --glob 包含' { if (-not ($r.Code -eq 0 -and $r.Out -match 'a\.java' -and $r.Out -notmatch 'b\.cs')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg @('globtext', $root, '--glob', '!*.cs')
    Test 'T32 --glob 排除' { if (-not ($r.Code -eq 0 -and $r.Out -match 'a\.java' -and $r.Out -notmatch 'b\.cs')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('-C', '1', 'needle', $root)
    Test 'T33 --context' { if (-not ($r.Code -eq 0 -and $r.Out -match 'ctx line2' -and $r.Out -match 'ctx line4')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('🚀', $root)
    Test 'T34 Emoji' { if (-not ($r.Code -eq 0 -and $r.Out -match 'emoji\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg -Stdin $mixed @($root)
    Test 'T35 混合特殊字符 STDIN' { if (-not ($r.Code -eq 0 -and $r.Out -match 'mixed\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('BOM中文', $root)
    Test 'T36 UTF-8 BOM 文件' { if (-not ($r.Code -eq 0 -and $r.Out -match 'bom\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Rg @('unicode中文', $root)
    Test 'T37 UTF-16 文件' { if (-not ($r.Code -eq 0 -and $r.Out -match 'utf16\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    $r = Invoke-Rg @('--help')
    Test 'T38 --help' { if (-not ($r.Code -eq 0 -and $r.Out -match 'ripgrep')) { throw "code=$($r.Code)" } }
    $r = Invoke-Rg @('--version')
    Test 'T39 --version' { if (-not ($r.Code -eq 0 -and $r.Out -match 'ripgrep')) { throw "code=$($r.Code)" } }

    $binFile = Join-Path $root 'out.bin'
    $cmdExe = $env:ComSpec
    & $cmdExe /c "`"$script:Rg`" 交易完成 `"$root`" > `"$binFile`"" 2>&1 | Out-Null
    $bytes = [System.IO.File]::ReadAllBytes($binFile)
    $decoded = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    Test 'T40 字节级 UTF-8 输出' { if ($decoded -notmatch '交易完成' -or $decoded -notmatch 'cn\.txt') { throw "解码后: $(Out-Snippet $decoded)" } }

    # T41/T42/T43：SafeRG 安装验证类，对 rg 退化为"命令全局可用"检查
    $savedPath = $env:Path
    try {
        $userP = [Environment]::GetEnvironmentVariable('Path', 'User')
        $machineP = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $env:Path = $userP + ';' + $machineP
        $out = (& rg --version 2>&1 | ForEach-Object { $_.ToString() }) -join ' '
        Test 'T41 新 PS 会话解析命令' { if (-not ($LASTEXITCODE -eq 0 -and $out -match 'ripgrep')) { throw "out=$(Out-Snippet $out)" } }
        $cmdOut = (& $cmdExe /c "where rg && rg --version" 2>&1 | ForEach-Object { $_.ToString() }) -join ' '
        Test 'T42 CMD 中命令可用' { if (-not ($cmdOut -match 'rg\.exe' -and $cmdOut -match 'ripgrep')) { throw "out=$(Out-Snippet $cmdOut)" } }
    } finally { $env:Path = $savedPath }
    $outV = (& $script:Rg --version 2>&1 | ForEach-Object { $_.ToString() }) -join ' '
    Test 'T43 独立运行' { if (-not ($LASTEXITCODE -eq 0 -and $outV -match 'ripgrep')) { throw "out=$(Out-Snippet $outV)" } }
}
finally { Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "========== 对照实验：43 个测试改用原生 rg =========="
$fails = 0
foreach ($r in $results) {
    if ($r.Status -eq 'FAIL') { $fails++ }
    $marker = if ($r.Status -eq 'PASS') { '[PASS]' } else { '[FAIL]' }
    $line = "{0} {1}" -f $marker, $r.Name
    if ($r.Detail) { $line += "  -> $($r.Detail)" }
    Write-Host $line
}
$passes = $results.Count - $fails
Write-Host ""
Write-Host ("rg 版结果: {0} PASS / {1} FAIL（srg 版为 43 PASS / 0 FAIL）" -f $passes, $fails)
exit 0
