# SafeRG 1.3.0 Agent UX Regression（Suite E）
# 7 个 Agent 工作流 + 组合测试 + 错误参数 + legacy 降噪 + JSON 契约
# 用法: pwsh -NoProfile -File tests\agent-ux-regression.ps1

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }

$script:Srg = Join-Path $env:LOCALAPPDATA 'Programs\SafeRG\bin\srg.exe'
if (-not (Test-Path $script:Srg)) { throw "未找到 srg.exe: $script:Srg" }

$root = Join-Path $env:TEMP ("SafeRG-UX-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Name, [string]$Status, [string]$Detail = '') { $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail }) }
function Pass([string]$Name) { Add-Result $Name 'PASS' }
function Fail([string]$Name, [string]$Detail) { Add-Result $Name 'FAIL' $Detail }
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
    Write-Utf8 (Join-Path $root 'UserService.java') "user_123 SecondhandItem`nuser_456 other`nuser_789 SecondhandItemService"
    Write-Utf8 (Join-Path $root 'app.js') 'user_111 in js'
    Write-Utf8 (Join-Path $root 'build.txt') 'SecondhandItem in build'
    Write-Utf8 (Join-Path $root 'case.txt') "SecondhandItem`nsecondhanditem`nSecondhandItemService"
    Write-Utf8 (Join-Path $root 'x.vue') 'vue content SecondhandItem'
    Write-Utf8 (Join-Path $root 'complex.java') 'if (status == TradeStatus.TRADING && userId != null) {'
    Write-Utf8 (Join-Path $root 'foo.txt') "foo( bar )`nfoo(x)`nplain foo"
    # Long Query 夹具
    $lq = '// UX_LQ_HEAD_' + ('z' * 5000) + '_UX_LQ_TAIL'
    Write-Utf8 (Join-Path $root 'lq_real.txt') $lq
    Write-Utf8 (Join-Path $root 'lq_bait.txt') ('// UX_LQ_HEAD_' + ('z' * 200) + ' 只有锚点片段，没有完整文本')
    Write-Utf8 (Join-Path $root 'lq_q.txt') $lq
    # ignored 夹具
    New-Item -ItemType Directory -Path (Join-Path $root 'ignored') -Force | Out-Null
    Write-Utf8 (Join-Path $root '.gitignore') 'ignored/'
    Write-Utf8 (Join-Path $root 'ignored\secret.txt') 'TOKEN_IGNORED_MARK'
    Write-Utf8 (Join-Path $root 'normal.txt') 'TOKEN_VISIBLE_MARK'
    # legacy 夹具
    [System.IO.File]::WriteAllBytes((Join-Path $root 'gbk.txt'), [System.Text.Encoding]::GetEncoding(936).GetBytes('GBK中文目标文本交易完成'))
    Write-Utf8 (Join-Path $root 'utf8plain.txt') '纯UTF8项目内容，没有目标'

    # ===== U01-U07: Agent 工作流场景 =====
    $r = Invoke-Srg @('-l', 'SecondhandItem', $root)
    Test 'U01 场景1 srg -l 文件列表' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'UserService\.java') '缺少 java'
        Assert ($r.Out -match 'build\.txt') '缺少 build.txt'
        Assert ($r.Out -notmatch ':\d+:\d+:') '出现行号（-l 应只输出路径）'
        Assert (([regex]::Matches($r.Out, 'UserService\.java')).Count -eq 1) '文件重复输出'
    }
    $r = Invoke-Srg @('SecondhandItem', $root, '-t', 'java')
    Test 'U02 场景2 srg -t java' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'UserService\.java') '缺 java 文件'
        Assert ($r.Out -notmatch 'app\.js|build\.txt|x\.vue') '非 java 文件混入'
    }
    $r = Invoke-Srg @('--regex', '-o', 'user_[0-9]+', $root)
    Test 'U03 场景3 srg --regex -o 提取片段' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'user_123') '缺 user_123'
        Assert ($r.Out -match 'user_789') '缺 user_789'
        Assert ($r.Out -match ':1:1:user_123') '片段行缺 path:line:col 前缀'
        Assert ($r.Out -notmatch 'SecondhandItem') '整行混入'
    }
    $r = Invoke-Srg @('-S', 'secondhanditem', (Join-Path $root 'case.txt'))
    Test 'U04 场景4 srg -S 智能大小写（全小写忽略大小写）' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert (([regex]::Matches($r.Out, ':SecondhandItem')).Count -ge 1) '未忽略大小写'
    }
    $r = Invoke-Srg @('TOKEN_IGNORED_MARK', $root, '--no-ignore')
    Test 'U05 场景5 srg --no-ignore 搜索忽略文件' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'ignored[\\/]secret\.txt') 'ignored 文件未搜到'
    }
    $r = Invoke-Srg -Stdin 'if (status == TradeStatus.TRADING && userId != null) {' @($root)
    Test 'U06 场景6 stdin 复杂代码片段' { Assert ($r.Code -eq 0 -and $r.Out -match 'complex\.java') "code=$($r.Code)" }
    $r = Invoke-Srg @('--json', '--require-complete', 'foo(', $root)
    Test 'U07 场景7 --json --require-complete' {
        Assert ($r.Code -eq 0) "code=$($r.Code)（未截断应 0）"
        Assert ($r.Out -match '"type":"saferg-summary","complete":true') 'summary 未表达 complete'
    }

    # ===== U08-U12: -l 组合 =====
    $r = Invoke-Srg @('-l', 'SecondhandItem', $root, '--glob', '*.java')
    Test 'U08 -l + glob' { Assert ($r.Code -eq 0 -and $r.Out -match 'UserService\.java' -and $r.Out -notmatch 'build\.txt') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('-l', 'SecondhandItem', $root, '-t', 'java')
    Test 'U09 -l + type' { Assert ($r.Code -eq 0 -and $r.Out -match 'UserService\.java' -and $r.Out -notmatch 'app\.js') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('-l', '--regex', 'user_[0-9]+', $root)
    Test 'U10 -l + regex' { Assert ($r.Code -eq 0 -and $r.Out -match 'UserService\.java' -and $r.Out -match 'app\.js') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('-l', '交易完成', $root)
    Test 'U11 -l + legacy 补搜' { Assert ($r.Code -eq 0 -and $r.Out -match 'gbk\.txt') "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('-l', '--query-file', (Join-Path $root 'lq_q.txt'), $root)
    Test 'U12 -l + Long Query（全文验证后才输出文件）' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'lq_real\.txt') '真实文件未输出'
        Assert ($r.Out -notmatch 'lq_bait\.txt') 'anchor 诱饵被输出（未全文验证）！'
        Assert ($r.Out -notmatch ':\d+:\d+:') '-l 输出含行号'
    }

    # ===== U13/U14: -o 组合 =====
    $r = Invoke-Srg @('--regex', '-o', '--max-results', '1', 'user_[0-9]+', $root)
    Test 'U13 -o + max-results（按 match 计数）' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert (([regex]::Matches($r.Out, ':user_')).Count -eq 1) "match 数错误: $(Out-Snippet $r.Out)"
        Assert ($r.Out -match 'Results truncated') '缺少截断提示'
    }
    $r = Invoke-Srg @('--regex', '-o', '-C1', 'user_[0-9]+', $root)
    Test 'U14 -o + context 透传不报错' { Assert ($r.Code -eq 0) "code=$($r.Code)" }
    $r = Invoke-Srg @('-o', '--query-file', (Join-Path $root 'lq_q.txt'), $root)
    Test 'U14b -o + Long Query 明确拒绝' { Assert ($r.Code -eq 2 -and $r.Out -match '不兼容') "code=$($r.Code) out=$(Out-Snippet $r.Out)" }

    # ===== U15: -t 组合 =====
    $r = Invoke-Srg @('SecondhandItem', $root, '-t', 'java', '--glob', '!*Service*')
    Test 'U15 -t + glob' { Assert ($r.Code -eq 1) "code=$($r.Code)（应被 glob 排除）" }
    New-Item -ItemType Directory -Path (Join-Path $root '.hid') -Force | Out-Null
    Write-Utf8 (Join-Path $root '.hid\h.java') 'SecondhandItem hidden java'
    $r = Invoke-Srg @('SecondhandItem', $root, '-t', 'java')
    Test 'U15b -t 默认不搜隐藏' { Assert ($r.Out -notmatch '\.hid') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('SecondhandItem', $root, '-t', 'java', '--hidden')
    Test 'U15c -t + hidden' { Assert ($r.Out -match '\.hid[\\/]h\.java') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('TOKEN_VISIBLE_MARK', $root, '-t', 'txt', '--no-ignore')
    Test 'U15d -t + no-ignore' { Assert ($r.Code -eq 0 -and $r.Out -match 'normal\.txt') "out=$(Out-Snippet $r.Out)" }

    # ===== U16: -S 冲突 =====
    $r = Invoke-Srg @('-S', '-i', 'x', $root)
    Test 'U16 -S + -i 冲突报错' { Assert ($r.Code -eq 2 -and $r.Out -match '冲突') "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('-S', '--case-sensitive', 'x', $root)
    Test 'U16b -S + --case-sensitive 冲突报错' { Assert ($r.Code -eq 2 -and $r.Out -match '冲突') "code=$($r.Code)" }
    $r = Invoke-Srg @('-S', 'SecondhandItem', (Join-Path $root 'case.txt'))
    Test 'U16c -S 含大写 → 区分大小写' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match ':1:1:SecondhandItem') '应匹配大写行'
        Assert ($r.Out -notmatch ':2:1:secondhanditem') '未区分大小写（小写行被匹配）'
    }

    # ===== U17: 错误参数 =====
    $r = Invoke-Srg @('-t')
    Test 'U17 -t 无值 exit=2' { Assert ($r.Code -eq 2 -and $r.Out -match '缺少参数值') "code=$($r.Code)" }
    $r = Invoke-Srg @('-t', 'DOES_NOT_EXIST', 'x', $root)
    Test 'U17b 未知 type 清晰错误' { Assert ($r.Code -eq 2 -and $r.Out -match 'unrecognized') "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('--type-add', 'novalue', 'x', $root)
    Test 'U17c --type-add 格式错误' { Assert ($r.Code -eq 2 -and $r.Out -match 'name:glob') "code=$($r.Code)" }
    $r = Invoke-Srg @('--type-add', 'x:*.txt; calc', 'TOKEN', $root)
    Test 'U17d --type-add 注入值作为单参数（不执行）' {
        Assert ($r.Code -in 0, 1) "code=$($r.Code)（独立 argv 传递，值被当单个参数）"
        Assert (-not (Get-Process calc -ErrorAction SilentlyContinue)) 'calc 被启动！'
    }
    $r = Invoke-Srg @('--no-column', '--json', 'x', $root)
    Test 'U17e --no-column + JSON 拒绝' { Assert ($r.Code -eq 2 -and $r.Out -match '仅用于文本模式') "code=$($r.Code)" }
    $r = Invoke-Srg @('--files')
    Test 'U17f --files fallback 提示' { Assert ($r.Code -eq 2 -and $r.Out -match 'rg --files') "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('-c', 'x', $root)
    Test 'U17g -c fallback 提示' { Assert ($r.Code -eq 2 -and $r.Out -match '原生 rg') "code=$($r.Code)" }
    $r = Invoke-Srg @('--pcre2', 'x', $root)
    Test 'U17h --pcre2 fallback 提示' { Assert ($r.Code -eq 2 -and $r.Out -match 'rg --pcre2') "code=$($r.Code)" }

    # ===== U18: --no-column 输出 =====
    $r = Invoke-Srg @('--no-column', 'SecondhandItem', (Join-Path $root 'build.txt'))
    Test 'U18 --no-column path:line:text' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match '^C:/.*build\.txt:1:') "格式: $(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch ':\d+:\d+:') '仍含列号'
    }

    # ===== U19: JSON 契约一致性 =====
    $r = Invoke-Srg @('--json', '-l', 'SecondhandItem', $root)
    Test 'U19 -l + --json 明确拒绝（不静默降级）' {
        Assert ($r.Code -eq 2) "code=$($r.Code)（rg 的 -l 优先于 --json，SafeRG 明确拒绝而非静默降级）"
        Assert ($r.Out -match '--json 与 -l') "提示: $(Out-Snippet $r.Out)"
    }
    $rText = Invoke-Srg @('--regex', '-o', 'user_[0-9]+', $root)
    $rJson = Invoke-Srg @('--json', '--regex', '-o', 'user_[0-9]+', $root)
    Test 'U19b -o JSON 与文本 match 数一致' {
        $tCount = ([regex]::Matches($rText.Out, ':user_')).Count
        $jCount = ([regex]::Matches($rJson.Out, '"type":"match"')).Count
        Assert ($tCount -eq $jCount) "text=$tCount json=$jCount"
    }

    # ===== U20: legacy 降噪 =====
    $r = Invoke-Srg @('不存在的目标', (Join-Path $root 'utf8plain.txt'))
    Test 'U20 纯 UTF-8 无匹配 → 安静 exit 1' {
        Assert ($r.Code -eq 1) "code=$($r.Code)"
        Assert ($r.Out -notmatch 'legacy|encoding|Warning') "出现噪音: $(Out-Snippet $r.Out)"
    }
    $r = Invoke-Srg @('不存在的目标', $root)
    Test 'U20b 含 GBK 文件无匹配 → 一行 warning' {
        Assert ($r.Code -eq 1) "code=$($r.Code)"
        Assert ($r.Out -match 'Search may be incomplete') '缺风险提示'
        Assert (([regex]::Matches($r.Out, 'Search may be incomplete')).Count -eq 1) 'warning 超过一行'
    }
    $r = Invoke-Srg @('--debug', '不存在的目标', $root)
    Test 'U20c --debug 含详细 legacy 信息' { Assert ($r.Out -match 'debug: \d+ 个疑似 legacy') "out=$(Out-Snippet $r.Out)" }

    # ===== U21: 完整性边界（§三十四：199/200/201/1000） =====
    foreach ($n in @(199, 200, 201, 1000)) {
        $lines = 1..$n | ForEach-Object { "COMPLETE_BOUNDARY_$_" }
        Write-Utf8 (Join-Path $root "boundary$n.txt") ($lines -join "`n")
        $r = Invoke-Srg @('COMPLETE_BOUNDARY', (Join-Path $root "boundary$n.txt"))
        if ($n -le 200) {
            Test "U21 ${n} matches → complete（无截断）" {
                Assert ($r.Code -eq 0) "code=$($r.Code)"
                Assert ($r.Out -notmatch 'Results truncated') "出现截断提示: $(Out-Snippet $r.Out)"
                Assert (([regex]::Matches($r.Out, ':COMPLETE_BOUNDARY')).Count -eq $n) "match 数错误"
            }
        } else {
            Test "U21 ${n} matches → truncated" {
                Assert ($r.Code -eq 0) "code=$($r.Code)"
                Assert ($r.Out -match 'Results truncated') '缺截断提示'
                Assert (([regex]::Matches($r.Out, ':COMPLETE_BOUNDARY')).Count -eq 200) '应显示 200'
            }
        }
        $r = Invoke-Srg @('--json', 'COMPLETE_BOUNDARY', (Join-Path $root "boundary$n.txt"))
        if ($n -le 200) {
            Test "U21b JSON ${n} matches → complete" { Assert ($r.Out -match '"type":"saferg-summary","complete":true') 'summary 未表达 complete' }
        } else {
            Test "U21b JSON ${n} matches → truncated" { Assert ($r.Out -match '"type":"saferg-summary","complete":false' -and $r.Out -match '"truncated":true') 'summary 未表达 truncated' }
        }
    }
}
finally {
    Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========== SafeRG Agent UX Regression (Suite E) =========="
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
Write-Host ("Suite E: {0} PASS / {1} FAIL" -f $passes, $fails)
exit $fails
