# SafeRG 1.1.0 Release Regression（双黑盒审计回归套件 / Suite C）
# 覆盖：No-query NRE、flag-only、empty-query 一致性、GBK/BOM-less UTF-16、
#       max-results+context、truncation 可检测、路径格式契约、--help/--version 字面查询、
#       -n/-F/-v 策略、1MB 单行、regex 错误净化、Long Query 隐私、binary、glob 示例、
#       --query、--encoding、--json、注入回归、Long Query near miss。
# 用法: pwsh -NoProfile -File tests\release-regression.ps1

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }

$script:Srg = Join-Path $env:LOCALAPPDATA 'Programs\SafeRG\bin\srg.exe'
if (-not (Test-Path $script:Srg)) { throw "未找到 srg.exe: $script:Srg" }

$root = Join-Path $env:TEMP ("SafeRG-RelReg-" + [guid]::NewGuid().ToString('N'))
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

try {
    # ===== 夹具 =====
    Write-Utf8 (Join-Path $root 'basic.txt') "hello world`nSecondhandItem`nfoo123bar`nuser.name[0]"
    Write-Utf8 (Join-Path $root 'dash.txt') "please use --help first`nrun with --version`nvalue is -n`nflag -F works"
    Write-Utf8 (Join-Path $root 'case.txt') "SafeRG`nsaferg`nSAFERG`nSafeRg"
    Write-Utf8 (Join-Path $root 'inject.txt') '$(Get-Process) | whoami & calc.exe ; echo HACKED `whoami` > file "x" [y] {z} \'
    Write-Utf8 (Join-Path $root 'ctx.txt') "line1`nTARGET_A`nline3`nline4`nTARGET_B`nline6`nline7`nTARGET_C"
    # 1MB 单行
    $longLine = ('X' * 500000) + 'NEEDLE_MARK' + ('Y' * 500000)
    [System.IO.File]::WriteAllBytes((Join-Path $root 'longline.txt'), [System.Text.UTF8Encoding]::new($false).GetBytes($longLine))
    # GBK 文件
    $gbkBytes = [System.Text.Encoding]::GetEncoding(936).GetBytes('这是GBK编码的中文文件，包含交易完成字样')
    [System.IO.File]::WriteAllBytes((Join-Path $root 'gbk.txt'), $gbkBytes)
    # BOM-less UTF-16LE 文件
    [System.IO.File]::WriteAllBytes((Join-Path $root 'utf16nobom.txt'), [System.Text.Encoding]::Unicode.GetBytes('这是无BOM的UTF-16LE中文，包含支付成功字样'))
    # 空 query 文件
    [System.IO.File]::WriteAllBytes((Join-Path $root 'emptyq.txt'), [byte[]]@())
    # Long Query 隐私夹具
    $lq = ('// LQ_PRIVACY_HEAD ' + ('a' * 5000) + '`n// LQ_PRIVACY_TAIL')
    Write-Utf8 (Join-Path $root 'lq.txt') $lq
    Write-Utf8 (Join-Path $root 'lqq.txt') $lq

    # ===== R01/R02: No-query NRE / flag-only =====
    foreach ($args in @(@(), @('--'), @('--regex'), @('-i'), @('--hidden'), @('--case-sensitive'), @('--context','3'), @('--max-results','5'), @('--glob','*.java'), @('--json'), @('-v'))) {
        $r = Invoke-Srg -SrgArgs $args
        Test "R01 no-query [$($args -join ' ')] exit=2 无 NRE" {
            Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）"
            Assert ($r.Out -match '缺少搜索内容') "提示: $(Out-Snippet $r.Out)"
            Assert ($r.Out -notmatch 'Object reference|Stack trace|NullReference') '出现 NRE/stack trace！'
        }
    }
    $r = Invoke-Srg @('--query-file', 'C:\nonexistent')
    Test 'R01b query-file 不存在 exit=2 无 NRE' {
        Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）"
        Assert ($r.Out -match '查询文件不存在') "提示: $(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch 'Object reference|Stack trace|NullReference') '出现 NRE/stack trace！'
    }

    # ===== R03: empty-query 一致性 =====
    $r = Invoke-Srg @('', $root)
    Test 'R03 空 positional exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)" }
    $r = Invoke-Srg -Stdin '' @($root)
    Test 'R03b 空 stdin exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)" }
    $r = Invoke-Srg -Stdin "`n`n" @($root)
    Test 'R03c 纯 LF exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)" }
    $r = Invoke-Srg -Stdin "`r`n`r`n" @($root)
    Test 'R03d 纯 CRLF exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)" }
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'emptyq.txt'), $root)
    Test 'R03e 空 query-file exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)" }
    $r = Invoke-Srg @(' ', $root)
    Test 'R03f 单个空格是合法查询' { Assert ($r.Code -in 0, 1) "code=$($r.Code)（空格是合法 Literal）" }

    # ===== R04: GBK 自动补搜 =====
    $r = Invoke-Srg @('交易完成', $root)
    Test 'R04 GBK 自动补搜命中' {
        Assert ($r.Code -eq 0) "code=$($r.Code) out=$(Out-Snippet $r.Out)"
        Assert ($r.Out -match 'gbk\.txt') '未命中 GBK 文件'
        Assert ($r.Out -match 'legacy 编码') '缺少补搜 warning'
    }
    $r = Invoke-Srg @('--encoding', 'gbk', '交易完成', $root)
    Test 'R04b 显式 --encoding gbk' { Assert ($r.Code -eq 0 -and $r.Out -match 'gbk\.txt') "code=$($r.Code)" }

    # ===== R05: BOM-less UTF-16 补搜 =====
    $r = Invoke-Srg @('支付成功', $root)
    Test 'R05 BOM-less UTF-16 补搜命中' {
        Assert ($r.Code -eq 0) "code=$($r.Code) out=$(Out-Snippet $r.Out)"
        Assert ($r.Out -match 'utf16nobom\.txt') '未命中 UTF-16 文件'
    }

    # ===== R06: max-results + context =====
    $r = Invoke-Srg @('-C', '2', '--max-results', '2', 'TARGET_', (Join-Path $root 'ctx.txt'))
    Test 'R06 -C 2 --max-results 2：2 match + context 保留' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        $matches = ([regex]::Matches($r.Out, ':TARGET_')).Count
        Assert ($matches -eq 2) "match 数=$matches（应为 2）"
        Assert ($r.Out -match 'line1' -and $r.Out -match 'line3' -and $r.Out -match 'line4' -and $r.Out -match 'line6') "context 丢失: $(Out-Snippet $r.Out)"
        Assert ($r.Out -match 'Results truncated') '缺少截断提示'
    }

    # ===== R07: truncation 机器可检测 =====
    $r = Invoke-Srg @('--json', '--max-results', '1', 'TARGET_', (Join-Path $root 'ctx.txt'))
    Test 'R07 --json 截断事件' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match '"type":"saferg-summary"') "缺少 summary 事件: $(Out-Snippet $r.Out)"
        Assert ($r.Out -match '"truncated":true') "缺少截断标志: $(Out-Snippet $r.Out)"
    }
    $r = Invoke-Srg @('--require-complete', '--max-results', '1', 'TARGET_', (Join-Path $root 'ctx.txt'))
    Test 'R07b --require-complete 截断 exit=3' { Assert ($r.Code -eq 3) "code=$($r.Code)（应为 3）" }
    $r = Invoke-Srg @('--max-results', '1', 'TARGET_', (Join-Path $root 'ctx.txt'))
    Test 'R07c 默认截断 exit=0' { Assert ($r.Code -eq 0) "code=$($r.Code)（默认保持 0）" }

    # ===== R08/R09/R23: 路径格式契约 =====
    $r = Invoke-Srg @('SecondhandItem', (Join-Path $root 'basic.txt'))
    Test 'R08 单文件 path:line:col:text' { Assert ($r.Out -match '^C:/.*basic\.txt:\d+:\d+:') "格式: $(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('SecondhandItem', $root)
    Test 'R09 目录路径统一 / 分隔' { Assert ($r.Out -match 'SafeRG-RelReg-[0-9a-f]+/basic\.txt') "路径: $(Out-Snippet $r.Out)"; Assert ($r.Out -notmatch '\\\\') '出现反斜杠' }

    # ===== R10/R11: --help/--version 字面查询 =====
    $r = Invoke-Srg @('--query', '--help', $root)
    Test 'R10 --query "--help" 字面命中' { Assert ($r.Code -eq 0 -and $r.Out -match 'dash\.txt') "code=$($r.Code)" }
    $r = Invoke-Srg @('--', '--version', $root)
    Test 'R10b -- 分隔 "-version" 字面命中' { Assert ($r.Code -eq 0 -and $r.Out -match 'dash\.txt') "code=$($r.Code)" }
    $r = Invoke-Srg @('posquery', '--query', 'x', $root)
    Test 'R11 --query 与位置参数冲突 exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）" }

    # ===== R12/R13: -n / -F 兼容 =====
    $r = Invoke-Srg @('-n', 'SecondhandItem', (Join-Path $root 'basic.txt'))
    Test 'R12 -n no-op 正常输出行号' { Assert ($r.Code -eq 0 -and $r.Out -match ':2:') "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('-F', 'user.name[0]', (Join-Path $root 'basic.txt'))
    Test 'R13 -F 字面搜索' { Assert ($r.Code -eq 0 -and $r.Out -match 'user\.name\[0\]') "code=$($r.Code)" }
    $r = Invoke-Srg @('--regex', '-F', 'foo\d+', (Join-Path $root 'basic.txt'))
    Test 'R13b --regex -F 透传固定字符串（不匹配 foo123bar）' { Assert ($r.Code -eq 1) "code=$($r.Code)（-F 应禁用正则）" }

    # ===== R14: -v 策略（正确实现，非 no-op） =====
    Write-Utf8 (Join-Path $root 'inv.txt') "apple`nbanana`napple"
    $r = Invoke-Srg @('-v', 'apple', (Join-Path $root 'inv.txt'))
    Test 'R14 -v 反转匹配' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'banana') '未输出反转行'
        Assert ([regex]::Matches($r.Out, ':apple').Count -eq 0) 'apple 行不应出现'
    }

    # ===== R15: 1MB 单行 =====
    $r = Invoke-Srg @('NEEDLE_MARK', (Join-Path $root 'longline.txt'))
    Test 'R15 1MB 单行受控输出' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out.Length -lt 20000) "输出 $($r.Out.Length) 字符（应被截断）"
        Assert ($r.Out -match 'chars omitted') '缺少省略标记'
        Assert ($r.Out -match 'NEEDLE_MARK') '匹配内容本身被裁掉！'
        Assert ($r.Out -match ':\d+:\d+:') 'path:line:col 前缀保留'
    }
    $r = Invoke-Srg @('--max-line-length', '0', 'NEEDLE_MARK', (Join-Path $root 'longline.txt'))
    Test 'R15b --max-line-length 0 关闭限制' { Assert ($r.Out.Length -gt 50000) "输出 $($r.Out.Length)（应完整）" }

    # ===== R16: regex 错误净化 =====
    $r = Invoke-Srg @('--regex', '[unclosed', $root)
    Test 'R16 无效 regex 净化' {
        Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）"
        Assert ($r.Out -match 'Regex error') "提示: $(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch '\?:\(') '泄漏内部 (?: 包装！'
    }
    $r = Invoke-Srg -Stdin "foo`nbar`n{bad" @($root)
    Test 'R16b 多行 Literal 报错不泄漏转义 pattern' {
        Assert ($r.Out -notmatch '\\r\?\\n') '泄漏内部转义模式！'
    }

    # ===== R17: Long Query 隐私（只检查 stderr；stdout 的匹配结果自然包含查询文本） =====
    $errFile = Join-Path $root 'lq-err.txt'
    $null = & $script:Srg '--query-file' (Join-Path $root 'lqq.txt') $root 2>$errFile
    $errText = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    Test 'R17 Long Query stderr 不泄漏查询/锚点内容' {
        Assert ($LASTEXITCODE -eq 0) "code=$($LASTEXITCODE)"
        Assert ($errText -notmatch 'LQ_PRIVACY_HEAD') 'stderr 泄漏查询片段！'
        Assert ($errText -notmatch 'aaaaaa') 'stderr 泄漏 anchor 内容！'
    }
    $errFile2 = Join-Path $root 'lq-err2.txt'
    $null = & $script:Srg '--debug' '--query-file' (Join-Path $root 'lqq.txt') $root 2>$errFile2
    $errText2 = Get-Content $errFile2 -Raw -ErrorAction SilentlyContinue
    Test 'R17b --debug 才显示 anchor 信息' { Assert ($errText2 -match 'debug.*anchors') "缺少 debug 输出: $(Out-Snippet $errText2)" }

    # ===== R18: binary 行为 =====
    $rnd = [System.Random]::new(9)
    $b1 = New-Object byte[] 50000; $rnd.NextBytes($b1)
    $b2 = New-Object byte[] 50000; $rnd.NextBytes($b2)
    $mk = [System.Text.Encoding]::ASCII.GetBytes('BIN_MARK_XYZ')
    [System.IO.File]::WriteAllBytes((Join-Path $root 'blob.bin'), [byte[]]($b1 + $mk + $b2))
    $r = Invoke-Srg @('BIN_MARK_XYZ', $root)
    Test 'R18 目录遍历跳过二进制' { Assert ($r.Code -eq 1) "code=$($r.Code)（应跳过，与 rg 一致）" }
    $r = Invoke-Srg @('BIN_MARK_XYZ', (Join-Path $root 'blob.bin'))
    Test 'R18b 显式二进制文件提示且不输出内容' { Assert ($r.Code -eq 0 -and $r.Out -match 'binary file matches' -and $r.Out -notmatch 'BIN_MARK_XYZ') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('--text', 'BIN_MARK_XYZ', (Join-Path $root 'blob.bin'))
    Test 'R18c --text 强制按文本' { Assert ($r.Code -eq 0) "code=$($r.Code) out=$(Out-Snippet $r.Out)" }

    # ===== R19: negative glob（绝对路径搜索根） =====
    foreach ($d in @('src','node_modules')) {
        New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
        Write-Utf8 (Join-Path $root "$d\target.txt") 'NEGGLOB_MARK'
    }
    $r = Invoke-Srg @('NEGGLOB_MARK', $root, '--glob', '!**/node_modules/**')
    Test 'R19 !**/node_modules/** 绝对路径生效' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'src[\\/]target') "缺少 src: $(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch 'node_modules') 'node_modules 未被排除！'
    }

    # ===== R21: --encoding auto =====
    $r = Invoke-Srg @('--encoding', 'auto', '交易完成', $root)
    Test 'R21 --encoding auto 命中 GBK' { Assert ($r.Code -eq 0 -and $r.Out -match 'gbk\.txt') "code=$($r.Code)" }

    # ===== R22: --json 模式 =====
    $r = Invoke-Srg @('--json', 'SecondhandItem', (Join-Path $root 'basic.txt'))
    Test 'R22 --json match 事件' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match '"type":"match"') '缺少 match 事件'
        Assert ($r.Out -match '"line_number":2') '行号字段缺失'
        Assert ($r.Out -match '"path":{"text":"C:/') '路径字段缺失'
    }

    # ===== R24: 注入回归 =====
    foreach ($q in @('$(Get-Process)','| whoami','& calc.exe','; echo HACKED','`whoami`','> file','"x"','[y]','{z}','\')) {
        $r = Invoke-Srg -Stdin $q @($root)
        Test "R24 注入字面 [$q]" { Assert ($r.Code -eq 0 -and $r.Out -match 'inject\.txt') "code=$($r.Code)" }
    }
    Test 'R24b 无副作用' { Assert (-not (Test-Path (Join-Path $root 'file'))) '生成了 file（重定向发生！）' }

    # ===== R25: Long Query near miss =====
    $nearQ = ('NEAR_HEAD_' + ('z' * 6000) + '_NEAR_TAIL')
    Write-Utf8 (Join-Path $root 'near.txt') ($nearQ -replace 'NEAR_TAIL', 'NEAR_TAL')
    Write-Utf8 (Join-Path $root 'near-full.txt') $nearQ
    Write-Utf8 (Join-Path $root 'nearq.txt') $nearQ
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'nearq.txt'), $root)
    Test 'R25 Long Query near miss 只返回完整文件' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'near-full\.txt') '未命中完整文件'
        Assert ($r.Out -notmatch 'near\.txt') 'near miss 假阳性！'
    }
}
finally {
    Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========== SafeRG Release Regression (Suite C) =========="
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
Write-Host ("Suite C: {0} PASS / {1} FAIL" -f $passes, $fails)
exit $fails
