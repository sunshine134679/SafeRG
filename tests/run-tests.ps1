# SafeRG 完整测试套件（PowerShell 7）
# 用法: pwsh -NoProfile -File tests\run-tests.ps1 [-Srg 路径]
param(
    [string]$Srg = (Join-Path $env:LOCALAPPDATA 'Programs\SafeRG\bin\srg.exe')
)
$ErrorActionPreference = 'Stop'
$script:Srg = (Resolve-Path $Srg).Path
if (-not (Test-Path $script:Srg)) { throw "未找到 srg.exe: $script:Srg" }

# 测试会话统一 UTF-8 解码（等价于 Windows Terminal / VS Code 终端的 UTF-8 控制台）
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, [string]$Status, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
}
function Pass([string]$Name, [string]$Detail = '') { Add-Result $Name 'PASS' $Detail }
function Fail([string]$Name, [string]$Detail) { Add-Result $Name 'FAIL' $Detail }
function Skip([string]$Name, [string]$Detail) { Add-Result $Name 'SKIP' $Detail }
function Test([string]$Name, [scriptblock]$Body, [string]$Detail = '') {
    try { & $Body; Pass $Name $Detail } catch { Fail $Name ($_.Exception.Message) }
}

# 运行 srg，返回 { Code, Out }（stdout+stderr 合并，字符串化）
# 注意：管道内容必须在 --stdin 模式下才会被读取，因此 -Stdin 会自动补上 --stdin
# 注意：PowerShell 的 [string] 参数未传时是 ''（不是 $null），必须用 IsNullOrEmpty 判断
function Invoke-Srg {
    param([string[]]$SrgArgs = @(), [string]$Stdin = '')
    $out = if (-not [string]::IsNullOrEmpty($Stdin)) { $Stdin | & $script:Srg '--stdin' @SrgArgs 2>&1 } else { & $script:Srg @SrgArgs 2>&1 }
    $code = $LASTEXITCODE
    [pscustomobject]@{ Code = $code; Out = (($out | ForEach-Object { $_.ToString() }) -join "`n") }
}
function Out-Snippet([string]$s) {
    if ($s.Length -le 400) { return $s }
    return $s.Substring(0, 400) + '…'
}

# 精确写 UTF-8（无 BOM）文件，避免 PowerShell 换行/编码干扰
function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllBytes($Path, [System.Text.UTF8Encoding]::new($false).GetBytes($Text))
}

# ==================== 准备临时测试目录与夹具 ====================
$root = Join-Path $env:TEMP ("SafeRG-Test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$cleanup = { Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue }

$psMajor = $PSVersionTable.PSVersion.Major
$psMinor = $PSVersionTable.PSVersion.Minor
$modernPassing = ($psMajor -gt 7) -or ($psMajor -eq 7 -and $psMinor -ge 3) # 标准参数传递

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

    # ==================== 测试 ====================

    # T01/T02 中文
    $r = Invoke-Srg @('交易完成', $root)
    Test 'T01 中文（位置参数）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'cn\.txt' -and $r.Out -match ':\d+:\d+:')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Srg -Stdin '交易完成' @($root)
    Test 'T02 中文（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'cn\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T03 美元符号（不能被 PowerShell 当变量）
    $r = Invoke-Srg @('$user', $root)
    Test 'T03 美元符号 $user' { if (-not ($r.Code -eq 0 -and $r.Out -match 'dollar\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T04 双引号
    $r = Invoke-Srg -Stdin '"name": "张三"' @($root)
    Test 'T04 双引号（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'json\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    if ($modernPassing) {
        $r = Invoke-Srg @('"name": "张三"', $root)
        Test 'T05 双引号（位置参数）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'json\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    } else { Skip 'T05 双引号（位置参数）' 'PS < 7.3 原生参数传递缺陷，与 SafeRG 无关' }

    # T06 单引号
    $r = Invoke-Srg @("'hello'", $root)
    Test 'T06 单引号' { if (-not ($r.Code -eq 0 -and $r.Out -match 'single\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T07 反引号
    $r = Invoke-Srg -Stdin 'a`b' @($root)
    Test 'T07 反引号（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'backtick\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Srg @('a`b', $root)
    Test 'T08 反引号（位置参数）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'backtick\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T09 管道符
    $r = Invoke-Srg -Stdin 'foo | bar' @($root)
    Test 'T09 管道符（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'pipe\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T10 正则字符按字面搜索
    $r = Invoke-Srg @('user.name[0]', $root)
    Test 'T10 正则字符字面量 user.name[0]' { if (-not ($r.Code -eq 0 -and $r.Out -match 'regexchars\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T11 路径带空格
    $r = Invoke-Srg @('spacetext', $spDir)
    Test 'T11 路径带空格' { if (-not ($r.Code -eq 0 -and $r.Out -match 'sp\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T12 中文路径
    $r = Invoke-Srg @('中文路径内容', $cnDir)
    Test 'T12 中文路径' { if (-not ($r.Code -eq 0 -and $r.Out -match 'cnpath\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T13/T14/T15 多行（LF / CRLF / query-file）
    $q = $multiLines -join "`n"
    $r = Invoke-Srg -Stdin $q @($root)
    Test 'T13 多行 LF 文件' { if (-not ($r.Code -eq 0 -and $r.Out -match 'multi-lf\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    Test 'T14 多行 CRLF 文件' { if (-not ($r.Code -eq 0 -and $r.Out -match 'multi-crlf\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'query.txt'), $root)
    Test 'T15 多行 query-file' { if (-not ($r.Code -eq 0 -and $r.Out -match 'multi-lf\.txt' -and $r.Out -match 'multi-crlf\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T16/T17/T18 超长文本（>10000 字符，Long Query Mode）
    $r = Invoke-Srg -Stdin $longQ @($root)
    Test 'T16 超长多行（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'long\.txt' -and $r.Out -match 'Long query mode')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Srg -Stdin $longSingle @($root)
    Test 'T17 超长单行（STDIN）' { if (-not ($r.Code -eq 0 -and $r.Out -match 'longsingle\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'longquery.txt'), $root)
    Test 'T18 超长 query-file' { if (-not ($r.Code -eq 0 -and $r.Out -match 'longquery\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T19 无匹配 → exit 1
    $r = Invoke-Srg @('zzz_nonexistent_7f3a9', $root)
    Test 'T19 无匹配 exit=1' { if ($r.Code -ne 1) { throw "code=$($r.Code)（应为 1）" } }

    # T20 错误参数 → exit 2
    $r = Invoke-Srg @('x', 'C:\NoSuchDir_SafeRG_9f3')
    Test 'T20 错误路径 exit=2' { if ($r.Code -ne 2) { throw "code=$($r.Code)（应为 2）" } }

    # T21 Regex 模式
    $r = Invoke-Srg @('--regex', 'user\.name\[0\]', $root)
    Test 'T21 Regex 模式' { if (-not ($r.Code -eq 0 -and $r.Out -match 'regexchars\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Srg @('--regex', 'foo\d+', $root)
    Test 'T22 Regex foo\d+' { if (-not ($r.Code -eq 0 -and $r.Out -match 'foo123\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T23 大小写：默认区分；-i 不区分；regex 默认也区分
    $r = Invoke-Srg @('helloworld', $root)
    Test 'T23 默认区分大小写' { if ($r.Code -ne 1) { throw "code=$($r.Code)（应为 1）" } }
    $r = Invoke-Srg @('--ignore-case', 'helloworld', $root)
    Test 'T24 --ignore-case' { if (-not ($r.Code -eq 0)) { throw "code=$($r.Code)" } }
    $r = Invoke-Srg @('--case-sensitive', 'HelloWorld', $root)
    Test 'T25 --case-sensitive' { if (-not ($r.Code -eq 0)) { throw "code=$($r.Code)" } }
    $r = Invoke-Srg @('--regex', 'helloworld', $root)
    Test 'T26 Regex 默认区分大小写' { if ($r.Code -ne 1) { throw "code=$($r.Code)（应为 1）" } }
    $r = Invoke-Srg @('--regex', '--ignore-case', 'helloworld', $root)
    Test 'T27 Regex + -i' { if (-not ($r.Code -eq 0)) { throw "code=$($r.Code)" } }

    # T28 结果截断
    $r = Invoke-Srg @('--max-results', '5', 'truncword', $root)
    $matchLines = ([regex]::Matches($r.Out, ':truncword')).Count
    Test 'T28 --max-results 截断' { if (-not ($matchLines -eq 5 -and $r.Out -match 'Results truncated')) { throw "匹配行=$matchLines（应为5） notice=$( $r.Out -match 'Results truncated' )" } }

    # T29 隐藏文件
    $r = Invoke-Srg @('hiddentext', $root)
    Test 'T29 默认忽略隐藏' { if ($r.Code -ne 1) { throw "code=$($r.Code)（应为 1）" } }
    $r = Invoke-Srg @('--hidden', 'hiddentext', $root)
    Test 'T30 --hidden 搜索隐藏' { if (-not ($r.Code -eq 0 -and $r.Out -match 'h\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T31/T32 Glob
    $r = Invoke-Srg @('globtext', $root, '--glob', '*.java')
    Test 'T31 --glob 包含' { if (-not ($r.Code -eq 0 -and $r.Out -match 'a\.java' -and $r.Out -notmatch 'b\.cs')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Srg @('globtext', $root, '--glob', '!*.cs')
    Test 'T32 --glob 排除' { if (-not ($r.Code -eq 0 -and $r.Out -match 'a\.java' -and $r.Out -notmatch 'b\.cs')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T33 上下文
    $r = Invoke-Srg @('--context', '1', 'needle', $root)
    Test 'T33 --context' { if (-not ($r.Code -eq 0 -and $r.Out -match 'ctx line2' -and $r.Out -match 'ctx line4')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T34 Emoji
    $r = Invoke-Srg @('🚀', $root)
    Test 'T34 Emoji' { if (-not ($r.Code -eq 0 -and $r.Out -match 'emoji\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T35 混合特殊字符（含 $ ` " ' | & ; 等）
    $r = Invoke-Srg -Stdin $mixed @($root)
    Test 'T35 混合特殊字符 STDIN' { if (-not ($r.Code -eq 0 -and $r.Out -match 'mixed\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T36/T37 编码：BOM 文件 / UTF-16 文件
    $r = Invoke-Srg @('BOM中文', $root)
    Test 'T36 UTF-8 BOM 文件' { if (-not ($r.Code -eq 0 -and $r.Out -match 'bom\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }
    $r = Invoke-Srg @('unicode中文', $root)
    Test 'T37 UTF-16 文件' { if (-not ($r.Code -eq 0 -and $r.Out -match 'utf16\.txt')) { throw "code=$($r.Code) out=$(Out-Snippet $r.Out)" } }

    # T38 --help / --version
    $r = Invoke-Srg @('--help')
    Test 'T38 --help' { if (-not ($r.Code -eq 0 -and $r.Out -match 'SafeRG')) { throw "code=$($r.Code)" } }
    $r = Invoke-Srg @('--version')
    Test 'T39 --version' { if (-not ($r.Code -eq 0 -and $r.Out -match 'SafeRG')) { throw "code=$($r.Code)" } }

    # T40 字节级 UTF-8 输出（绕过 PowerShell 解码，验证 SafeRG 输出本身是合法 UTF-8）
    $binFile = Join-Path $root 'out.bin'
    $cmdExe = $env:ComSpec  # 显式使用系统 cmd.exe，避免 PATH 中被 msys 等 shim 劫持
    & $cmdExe /c "`"$script:Srg`" 交易完成 `"$root`" > `"$binFile`"" 2>&1 | Out-Null
    $bytes = [System.IO.File]::ReadAllBytes($binFile)
    $decoded = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    Test 'T40 字节级 UTF-8 输出' { if ($decoded -notmatch '交易完成' -or $decoded -notmatch 'cn\.txt') { throw "解码后: $(Out-Snippet $decoded)" } }

    # T41 新 PowerShell 会话 PATH 解析 srg（模拟全新终端）
    $savedPath = $env:Path
    try {
        $userP = [Environment]::GetEnvironmentVariable('Path', 'User')
        $machineP = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $env:Path = $userP + ';' + $machineP
        $out = (& srg --version 2>&1 | ForEach-Object { $_.ToString() }) -join ' '
        Test 'T41 新 PS 会话解析 srg' { if (-not ($LASTEXITCODE -eq 0 -and $out -match 'SafeRG')) { throw "out=$(Out-Snippet $out)" } }
        $cmdOut = (& $cmdExe /c "where srg && srg --version" 2>&1 | ForEach-Object { $_.ToString() }) -join ' '
        Test 'T42 CMD 中 srg 可用' { if (-not ($cmdOut -match 'srg\.exe' -and $cmdOut -match 'SafeRG')) { throw "out=$(Out-Snippet $cmdOut)" } }
    } finally { $env:Path = $savedPath }

    # T43 单文件独立运行（只复制 srg.exe 到全新目录，验证无外部依赖）
    $alone = Join-Path $env:TEMP ("srg-alone-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $alone | Out-Null
    $aloneCode = 1; $aloneOut = ''
    try {
        $aloneExe = Join-Path $alone 'srg.exe'
        Copy-Item $script:Srg $aloneExe
        $aloneOut = (& $aloneExe --version 2>&1 | ForEach-Object { $_.ToString() }) -join ' '
        $aloneCode = $LASTEXITCODE
    } finally { Remove-Item $alone -Recurse -Force -ErrorAction SilentlyContinue }
    Test 'T43 单文件独立运行' { if (-not ($aloneCode -eq 0 -and $aloneOut -match 'SafeRG')) { throw "code=$aloneCode out=$(Out-Snippet $aloneOut)" } }

    # ---- T44-T47 疑似正则提示（防静默假阴性）----
    # 这里必须把 stderr 单独重定向：Invoke-Srg 用 2>&1 合并了两个流，无法断言
    # "提示只出现在 stderr、stdout 保持干净"。
    $rxFile = Join-Path $root 'pipe.txt'   # 夹具内容: 'foo | bar'
    function Invoke-SrgSplit([string[]]$SrgArgs) {
        $e = Join-Path $root ("err-" + [guid]::NewGuid().ToString('N') + '.txt')
        $o = & $script:Srg @SrgArgs 2>$e
        $r = [pscustomobject]@{
            Code = $LASTEXITCODE
            Out  = (($o | ForEach-Object { $_.ToString() }) -join "`n")
            Err  = (Get-Content $e -Raw -ErrorAction SilentlyContinue)
        }
        Remove-Item $e -Force -ErrorAction SilentlyContinue
        return $r
    }
    $r44 = Invoke-SrgSplit @('aaa|bbb', $rxFile)               # 无匹配 + 含 |   -> 应提示
    $r45 = Invoke-SrgSplit @('foo | bar', $rxFile)             # 字面量命中      -> 不提示
    $r46 = Invoke-SrgSplit @('zzz(absent)', $rxFile)           # 裸括号，非强特征 -> 不提示
    $r47 = Invoke-SrgSplit @('--regex', 'zzz|absent', $rxFile) # --regex 模式    -> 不提示

    Test 'T44 无匹配+含| 触发提示且 stdout 干净' {
        if ($r44.Code -ne 1) { throw "期望 exit 1，实际 $($r44.Code)" }
        if ($r44.Out.Trim().Length -ne 0) { throw "stdout 不应有内容: $(Out-Snippet $r44.Out)" }
        if ($r44.Err -notmatch 'regex metacharacters') { throw "stderr 未出现提示: $(Out-Snippet $r44.Err)" }
    }
    Test 'T45 字面量命中时不提示' {
        if ($r45.Code -ne 0) { throw "期望 exit 0，实际 $($r45.Code)" }
        if ($r45.Err -match 'regex metacharacters') { throw "命中时不应提示: $(Out-Snippet $r45.Err)" }
    }
    Test 'T46 裸括号不触发提示（只认强特征）' {
        if ($r46.Code -ne 1) { throw "期望 exit 1，实际 $($r46.Code)" }
        if ($r46.Err -match 'regex metacharacters') { throw "裸括号不应触发: $(Out-Snippet $r46.Err)" }
    }
    Test 'T47 --regex 模式不提示' {
        if ($r47.Err -match 'regex metacharacters') { throw "--regex 模式不应提示: $(Out-Snippet $r47.Err)" }
    }
}
finally { & $cleanup }

# ==================== 汇总 ====================
Write-Host ""
Write-Host "========== SafeRG 测试结果 =========="
$fails = 0; $skips = 0
foreach ($r in $results) {
    if ($r.Status -eq 'FAIL') { $fails++ }
    if ($r.Status -eq 'SKIP') { $skips++ }
    $marker = switch ($r.Status) { 'PASS' { '[PASS]' } 'FAIL' { '[FAIL]' } 'SKIP' { '[SKIP]' } }
    $line = "{0} {1}" -f $marker, $r.Name
    if ($r.Detail) { $line += "  -> $($r.Detail)" }
    Write-Host $line
}
$passes = $results.Count - $fails - $skips
Write-Host ""
Write-Host ("总计: {0} PASS / {1} FAIL / {2} SKIP" -f $passes, $fails, $skips)
if ($fails -gt 0) { Write-Host "存在失败项！" } else { Write-Host "全部通过 ✓" }
exit $fails
