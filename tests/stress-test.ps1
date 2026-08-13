# SafeRG 综合压力测试（按 76 节验收规格）
# 实际创建数据 → 实际执行 srg → 观察 ExitCode/输出 → 汇总 FAIL
# 用法: pwsh -NoProfile -File tests\stress-test.ps1

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$script:Srg = Join-Path $env:LOCALAPPDATA 'Programs\SafeRG\bin\srg.exe'
if (-not (Test-Path $script:Srg)) { throw "未找到 srg.exe: $script:Srg" }

# ============ §1/§2 环境记录 + 隔离目录 ============
$script:EnvInfo = [ordered]@{
    PS          = $PSVersionTable.PSVersion.ToString()
    SrgPath     = $script:Srg
    RgPath      = (Get-Command rg).Source
    SrgVersion  = (& $script:Srg --version 2>&1 | Select-Object -First 1)
    RgVersion   = (rg --version | Select-Object -First 1)
}
$root = Join-Path $env:TEMP 'SafeRG-Stress-Test'
if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Path $root -Force | Out-Null

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
function Assert([bool]$Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }

function Invoke-Srg {
    param([string[]]$SrgArgs = @(), [string]$Stdin = '')
    # 用 $PSBoundParameters 区分"未传 -Stdin"与"传了空字符串"（空字符串也要走 --stdin）
    if ($PSBoundParameters.ContainsKey('Stdin')) {
        $out = $Stdin | & $script:Srg '--stdin' @SrgArgs 2>&1
    } else {
        $out = & $script:Srg @SrgArgs 2>&1
    }
    $code = $LASTEXITCODE
    [pscustomobject]@{ Code = $code; Out = (($out | ForEach-Object { $_.ToString() }) -join "`n") }
}
function Out-Snippet([string]$s) { if ($s.Length -le 300) { return $s } return $s.Substring(0, 300) + '…' }
function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllBytes($Path, [System.Text.UTF8Encoding]::new($false).GetBytes($Text))
}
function Assert-Match([string]$Name, $r, [string]$FilePattern) {
    Test $Name { Assert ($r.Code -eq 0) "code=$($r.Code)"; Assert ($r.Out -match $FilePattern) "未命中 $FilePattern out=$(Out-Snippet $r.Out)" }
}

try {
    # ============ §3 基础搜索 ============
    $basic = @('hello world','SafeRG test','SecondhandItem','SecondhandItemService','hello again')
    Write-Utf8 (Join-Path $root 'basic.txt') ($basic -join "`n")
    $r = Invoke-Srg @('SecondhandItem', $root)
    Test 'S03 基础搜索 SecondhandItem' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'basic\.txt') '文件名错误'
        Assert ($r.Out -match ':3:') '行号 3 缺失'
        Assert ($r.Out -match ':4:') '行号 4 缺失'
        Assert ($r.Out -notmatch '浜') '出现乱码'
    }

    # ============ §4 完全无匹配 ============
    $r = Invoke-Srg @('THIS_TEXT_DOES_NOT_EXIST_927361', $root)
    Test 'S04 无匹配 exit=1' { Assert ($r.Code -eq 1) "code=$($r.Code)（应为 1，不能是 2）" }

    # ============ §5 中文 UTF-8 ============
    $cn = @('用户确认交易','交易已经完成','这是中文搜索测试','你好，世界','嵌入式 Linux 开发','思维导图生成成功')
    Write-Utf8 (Join-Path $root '中文测试.txt') ($cn -join "`n")
    foreach ($q in @('交易已经完成','你好，世界','嵌入式 Linux','思维导图生成成功')) {
        $r = Invoke-Srg @($q, $root)
        Assert-Match "S05 中文 [$q]" $r '中文测试\.txt'
        Assert ($r.Out -notmatch '浜ゆ槗|浣犲ソ|�') "乱码: $(Out-Snippet $r.Out)"
    }

    # ============ §6 Emoji / Unicode ============
    $emoji = @('任务完成 ✅','发生错误 ❌','Rocket 🚀','Temperature: 25℃','箭头 → ← ↑ ↓','中文「括号」','α β γ π Ω')
    Write-Utf8 (Join-Path $root 'emoji.txt') ($emoji -join "`n")
    foreach ($q in @('✅','❌','🚀','℃','→','Ω')) {
        $r = Invoke-Srg @($q, $root)
        Assert-Match "S06 Unicode [$q]" $r 'emoji\.txt'
    }

    # ============ §7 PowerShell $ 对抗（STDIN 安全路径） ============
    $psSpec = @('$user','$env:PATH','${HOME}','$value = "$user"','$user.name','$user["name"]','$(Get-Date)')
    Write-Utf8 (Join-Path $root 'powershell-special.txt') ($psSpec -join "`n")
    foreach ($q in @('$user','$env:PATH','${HOME}','$value = "$user"','$user["name"]','$(Get-Date)')) {
        $r = Invoke-Srg -Stdin $q @($root)
        Assert-Match "S07 `$ 对抗 [$q]" $r 'powershell-special\.txt'
    }

    # ============ §8 单双引号 ============
    $quotes = @('"name": "张三"',"'hello world'",'"I''m SafeRG"','user["name"]',"map['key']",'"hello ''world''"',"'hello ""world""'")
    Write-Utf8 (Join-Path $root 'quotes.txt') (($quotes | ForEach-Object { $_ -replace '""', '"' }) -join "`n")
    $quotes = @('"name": "张三"',"'hello world'",'"I''m SafeRG"','user["name"]',"map['key']")
    foreach ($q in $quotes) {
        $r = Invoke-Srg -Stdin $q @($root)
        Assert-Match "S08 引号 [$q]" $r 'quotes\.txt'
    }

    # ============ §9 反引号 ============
    $bt = @('`','Write-Host `"$value`"','Use `rg` to search.')
    Write-Utf8 (Join-Path $root 'backtick.txt') ($bt -join "`n")
    foreach ($q in @('`','Write-Host `"$value`"','Use `rg` to search.')) {
        $r = Invoke-Srg -Stdin $q @($root)
        Assert-Match "S09 反引号 [$q]" $r 'backtick\.txt'
    }

    # ============ §10 管道符 ============
    $pipes = @('foo | bar','Get-Process | Where-Object','a||b','value | ConvertTo-Json')
    Write-Utf8 (Join-Path $root 'pipes.txt') ($pipes -join "`n")
    foreach ($q in $pipes) {
        $r = Invoke-Srg -Stdin $q @($root)
        Assert-Match "S10 管道符 [$q]" $r 'pipes\.txt'
    }

    # ============ §11 危险 Shell 字符 ============
    $danger = @('foo & bar','foo && bar','foo ; bar','> output.txt','>> output.txt','< input.txt','2>&1','*','?','!','#','@','%','^')
    Write-Utf8 (Join-Path $root 'danger.txt') ($danger -join "`n")
    foreach ($q in $danger) {
        $r = Invoke-Srg -Stdin $q @($root)
        Assert-Match "S11 危险字符 [$q]" $r 'danger\.txt'
    }
    Test 'S11b 无重定向副作用' { Assert (-not (Test-Path (Join-Path $root 'output.txt'))) '生成了 output.txt（发生了重定向！）' }

    # ============ §12 正则元字符 Literal ============
    $meta = @('.','*','+','?','^','$','[]','[0]','[a-z]','()','(foo)','{}','{1,3}','\','\d+','.*','foo.*','user.name','userXname','user[0]','foo(bar)','foo123bar')
    $metaFile = Join-Path $root 'meta.txt'
    Write-Utf8 $metaFile ($meta -join "`n")
    foreach ($q in $meta) {
        $r = Invoke-Srg @($q, $metaFile)
        Test "S12 Literal [$q]" { Assert ($r.Code -eq 0) "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    }
    $r = Invoke-Srg @('foo.*', $metaFile)
    Test 'S12b foo.* 不得匹配 foo123bar' { Assert ($r.Out -notmatch 'foo123bar') 'Literal 被当正则！' }
    $r = Invoke-Srg @('user.name', $metaFile)
    Test 'S12c user.name 不得匹配 userXname' { Assert ($r.Out -notmatch 'userXname') '. 被当任意字符！' }

    # ============ §13 显式 Regex ============
    Write-Utf8 (Join-Path $root 'regex.txt') "foo123bar`nfooXYZbar"
    $r = Invoke-Srg @('--regex', 'foo.*bar', (Join-Path $root 'regex.txt'))
    Test 'S13 Regex foo.*bar 两行都匹配' { Assert ($r.Code -eq 0) "code=$($r.Code)"; Assert ($r.Out -match 'foo123bar' -and $r.Out -match 'fooXYZbar') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('foo.*bar', (Join-Path $root 'regex.txt'))
    Test 'S13b 默认 Literal 不得匹配 foo123bar' { Assert ($r.Code -eq 1) "code=$($r.Code)（应为 1）" }

    # ============ §14 以 - 开头的 Query（-- 分隔机制） ============
    $dash = @('please use --help first','run with --version','value is -hidden','value is -n','flag -i works','flag -F works','argument --glob')
    Write-Utf8 (Join-Path $root 'dash.txt') ($dash -join "`n")
    foreach ($q in @('--help','--version','-hidden','-n','-i','-F','--glob')) {
        $r = Invoke-Srg @('--', $q, $root)
        Assert-Match "S14 dash query [$q]（-- 分隔）" $r 'dash\.txt'
    }
    $r = Invoke-Srg @('-hidden', $root)
    Test 'S14b 无 -- 时 -hidden 报错 exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2：未知选项）" }

    # ============ §15 空格 ============
    $spaces = @('hello world','hello     world',' leading space','trailing space ','    four spaces')
    Write-Utf8 (Join-Path $root 'spaces.txt') ($spaces -join "`n")
    $r = Invoke-Srg -Stdin 'hello world' @($root)
    Test 'S15 hello world 精确（不多不少空格）' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match ':1:') '应命中行 1'
        Assert ($r.Out -notmatch 'hello     world') '空格数量被改变！'
    }
    foreach ($q in @('hello     world',' leading space','trailing space ','    four spaces')) {
        $r = Invoke-Srg -Stdin $q @($root)
        Assert-Match "S15b 空格 [$q]" $r 'spaces\.txt'
    }

    # ============ §16 TAB ============
    $tabFile = Join-Path $root 'tab.txt'
    Write-Utf8 $tabFile "hello`tworld"
    $r = Invoke-Srg -Stdin "hello`tworld" @($root)
    Assert-Match 'S16 TAB（STDIN）' $r 'tab\.txt'
    Write-Utf8 (Join-Path $root 'tabquery.txt') "hello`tworld"
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'tabquery.txt'), $root)
    Assert-Match 'S16b TAB（query-file）' $r 'tab\.txt'

    # ============ §17 多行搜索 ============
    $java = @('public void login() {','    String username = "张三";','    System.out.println("登录成功");','}')
    Write-Utf8 (Join-Path $root 'multiline.java') ($java -join "`n")
    $q3 = @('public void login() {','    String username = "张三";','    System.out.println("登录成功");') -join "`n"
    $r = Invoke-Srg -Stdin $q3 @($root)
    Assert-Match 'S17 完整三行' $r 'multiline\.java'
    $q2 = @('String username = "张三";','    System.out.println("登录成功");') -join "`n"
    $r = Invoke-Srg -Stdin $q2 @($root)
    Assert-Match 'S17b 中间两行' $r 'multiline\.java'

    # ============ §18 CRLF 与 LF ============
    Write-Utf8 (Join-Path $root 'lf.txt') ($java -join "`n")
    Write-Utf8 (Join-Path $root 'crlf.txt') ($java -join "`r`n")
    $r = Invoke-Srg -Stdin $q3 @($root)
    Test 'S18 LF + CRLF 双文件命中' { Assert ($r.Out -match 'lf\.txt' -and $r.Out -match 'crlf\.txt') "out=$(Out-Snippet $r.Out)" }

    # ============ §19 中文路径 ============
    $cnProj = Join-Path $root '测试项目\源代码'
    New-Item -ItemType Directory -Path $cnProj -Force | Out-Null
    Write-Utf8 (Join-Path $cnProj '用户服务.java') '用户登录成功'
    $r = Invoke-Srg @('用户登录成功', $cnProj)
    Assert-Match 'S19 中文路径' $r '用户服务\.java'

    # ============ §20 带空格路径 ============
    $spProj = Join-Path $root 'Test Project With Spaces\source files'
    New-Item -ItemType Directory -Path $spProj -Force | Out-Null
    Write-Utf8 (Join-Path $spProj 'hello world.txt') 'space path content'
    $r = Invoke-Srg @('space path content', $spProj)
    Assert-Match 'S20 空格路径' $r 'hello world\.txt'

    # ============ §21 复杂 Windows 路径字符 ============
    foreach ($d in @('Project (2026)','Project [Test]','Project-Alpha','Project_测试')) {
        $dir = Join-Path $root $d
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Utf8 (Join-Path $dir 'f.txt') 'COMPLEX_PATH_MARK'
    }
    $r = Invoke-Srg @('COMPLEX_PATH_MARK', $root)
    Test 'S21 复杂路径字符' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        foreach ($d in @('Project (2026)','Project [Test]','Project-Alpha','Project_测试')) {
            Assert ($r.Out -match [regex]::Escape($d)) "缺少 $d"
        }
    }

    # ============ §22 深层目录 ============
    $deep = Join-Path $root 'level1\level2\level3\level4\level5\level6\level7'
    New-Item -ItemType Directory -Path $deep -Force | Out-Null
    Write-Utf8 (Join-Path $deep 'target.txt') 'DEEP_TARGET'
    $r = Invoke-Srg @('DEEP_TARGET', $root)
    Assert-Match 'S22 深层目录 7 层' $r 'target\.txt'

    # ============ §23 Glob ============
    foreach ($ext in @('java','js','ts','cpp','txt')) {
        Write-Utf8 (Join-Path $root "Test.$ext") 'UNIQUE_GLOB_TEST'
    }
    $r = Invoke-Srg @('UNIQUE_GLOB_TEST', $root, '--glob', '*.java')
    Test 'S23 --glob *.java 只返回 java' { Assert ($r.Code -eq 0); Assert ($r.Out -match 'Test\.java'); Assert ($r.Out -notmatch 'Test\.(js|ts|cpp|txt)') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('UNIQUE_GLOB_TEST', $root, '--glob', '*.js')
    Test 'S23b --glob *.js 只返回 js' { Assert ($r.Code -eq 0); Assert ($r.Out -match 'Test\.js'); Assert ($r.Out -notmatch 'Test\.(java|ts|cpp|txt)') "out=$(Out-Snippet $r.Out)" }

    # ============ §24 排除 Glob ============
    # 注：rg 的 glob 对【绝对路径】搜索根不生效（rg 自身语义），相对路径 "." 才生效——SafeRG 透传与 rg 一致
    foreach ($d in @('src','node_modules','build')) {
        $dir = Join-Path $root $d
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Utf8 (Join-Path $dir 'target.txt') 'IGNORE_TEST_9988'
    }
    Push-Location $root
    try {
        $r = Invoke-Srg @('IGNORE_TEST_9988', '.', '--glob', '!node_modules/**')
    } finally { Pop-Location }
    Test 'S24 排除 !node_modules/**' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'src[\\/]target') "缺少 src: $(Out-Snippet $r.Out)"
        Assert ($r.Out -match 'build[\\/]target') "缺少 build: $(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch 'node_modules') 'node_modules 未被排除！'
    }

    # ============ §25 .gitignore ============
    $git = Join-Path $root 'gitproj'
    New-Item -ItemType Directory -Path (Join-Path $git 'ignored') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $git 'normal') -Force | Out-Null
    Write-Utf8 (Join-Path $git '.gitignore') "ignored/`n*.generated.txt"
    Write-Utf8 (Join-Path $git 'ignored\secret.txt') 'GITIGNORE_TEST'
    Write-Utf8 (Join-Path $git 'normal\normal.txt') 'GITIGNORE_TEST'
    Write-Utf8 (Join-Path $git 'abc.generated.txt') 'GITIGNORE_TEST'
    $r = Invoke-Srg @('GITIGNORE_TEST', $git)
    Test 'S25 .gitignore 生效' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'normal') "应命中 normal: $(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch 'ignored') '.gitignore 的 ignored/ 失效！'
        Assert ($r.Out -notmatch 'generated') '.gitignore 的 *.generated.txt 失效！'
    }

    # ============ §26 隐藏文件 ============
    $hidDir = Join-Path $root '.hidden-dir'
    New-Item -ItemType Directory -Path $hidDir -Force | Out-Null
    Write-Utf8 (Join-Path $hidDir '.hidden-test-file') 'HIDDEN_TEST'
    $r = Invoke-Srg @('HIDDEN_TEST', $root)
    Test 'S26 默认不搜隐藏' { Assert ($r.Code -eq 1) "code=$($r.Code)（应为 1）" }
    $r = Invoke-Srg @('--hidden', 'HIDDEN_TEST', $root)
    Assert-Match 'S26b --hidden 搜索隐藏' $r 'hidden-test-file'

    # ============ §27 结果数量保护 ============
    $many = 1..500 | ForEach-Object { "MATCH_LIMIT_TEST line $_" }
    Write-Utf8 (Join-Path $root 'many.txt') ($many -join "`n")
    $r = Invoke-Srg @('MATCH_LIMIT_TEST', (Join-Path $root 'many.txt'))
    $mCount = ([regex]::Matches($r.Out, ':MATCH_LIMIT_TEST')).Count
    Test 'S27 结果截断 200' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($mCount -eq 200) "匹配行=$mCount（应为 200）"
        Assert ($r.Out -match 'Results truncated: showing first 200 matches.') '缺少截断提示'
    }

    # ============ §28 超长单行 10000+（query-file） ============
    $rnd = [System.Random]::new(42)
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
    $sb = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt 10000; $i++) { $null = $sb.Append($chars[$rnd.Next($chars.Length)]) }
    $q28 = 'LONG28_PREFIX_' + $sb.ToString() + '_LONG28_SUFFIX'
    Write-Utf8 (Join-Path $root 'long28.txt') $q28
    Write-Utf8 (Join-Path $root 'long28q.txt') $q28
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'long28q.txt'), $root)
    Assert-Match 'S28 10000+ 单行 query-file' $r 'long28\.txt'

    # ============ §29 50000 字符 Query ============
    $sb2 = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt 50000; $i++) { $null = $sb2.Append($chars[$rnd.Next($chars.Length)]) }
    $q29 = 'LONG29_PREFIX_' + $sb2.ToString() + '_LONG29_SUFFIX'
    Write-Utf8 (Join-Path $root 'long29.txt') $q29
    Write-Utf8 (Join-Path $root 'long29q.txt') $q29
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'long29q.txt'), $root)
    Assert-Match 'S29 50000 字符 Long Query' $r 'long29\.txt'

    # ============ §30 Long Query 假阳性 ============
    $mid = 1..62 | ForEach-Object { ('MID_SEGMENT_ROW_' + '{0:d2}' -f $_) + ('x' * 60) }
    $q30 = @('LQ30_HEAD', 'LQ30_MIDDLE', 'LQ30_TAIL') + $mid
    $q30full = $q30 -join "`n"
    # A：含全部 anchor 行但顺序不同（完整文本不存在）
    Write-Utf8 (Join-Path $root 'fake30.txt') (($mid + @('LQ30_HEAD','LQ30_MIDDLE','LQ30_TAIL')) -join "`n")
    # B：真正完整
    Write-Utf8 (Join-Path $root 'real30.txt') $q30full
    Write-Utf8 (Join-Path $root 'q30.txt') $q30full
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'q30.txt'), $root)
    Test 'S30 Long Query 假阳性（只返回 B）' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'real30\.txt') '未命中真实文件'
        Assert ($r.Out -notmatch 'fake30\.txt') '假阳性：A 被误判为完整匹配！'
    }

    # ============ §31 Long Query 开头相同 ============
    $common31 = 1..625 | ForEach-Object { ('ROW_COMMON_' + '{0:d3}' -f $_) + ('y' * 68) }
    $a31 = ($common31 + @('TAIL_AAA')) -join "`n"
    $b31 = ($common31 + @('TAIL_BBB')) -join "`n"
    Write-Utf8 (Join-Path $root 'a31.txt') $a31
    Write-Utf8 (Join-Path $root 'b31.txt') $b31
    Write-Utf8 (Join-Path $root 'q31.txt') $a31
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'q31.txt'), $root)
    Test 'S31 开头相同（只返回 A）' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'a31\.txt') '未命中 A'
        Assert ($r.Out -notmatch 'b31\.txt') 'B 被误判！'
    }

    # ============ §32 Long Query 结尾相同 ============
    $a32 = (@('HEAD_AAA') + $common31) -join "`n"
    $b32 = (@('HEAD_BBB') + $common31) -join "`n"
    Write-Utf8 (Join-Path $root 'a32.txt') $a32
    Write-Utf8 (Join-Path $root 'b32.txt') $b32
    Write-Utf8 (Join-Path $root 'q32.txt') $a32
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'q32.txt'), $root)
    Test 'S32 结尾相同（只返回 A）' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'a32\.txt') '未命中 A'
        Assert ($r.Out -notmatch 'b32\.txt') 'B 被误判！'
    }

    # ============ §33 多字节 Unicode 长文本 20000+ ============
    $blocks = @(
        ('中文' * 2500),
        ('日本語' * 1500),
        ('한국어' * 1500),
        ('🚀' * 1000),
        ('✅' * 1000),
        ('Ω' * 1000),
        ('→' * 1000)
    )
    $q33 = 'UNI33_HEAD_' + ($blocks -join '') + '_UNI33_TAIL'
    Write-Utf8 (Join-Path $root 'uni33.txt') $q33
    Write-Utf8 (Join-Path $root 'q33.txt') $q33
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'q33.txt'), $root)
    Test 'S33 多字节 Unicode 长文本' {
        Assert ($r.Code -eq 0) "code=$($r.Code) out=$(Out-Snippet $r.Out)"
        Assert ($r.Out -match 'uni33\.txt') '未命中'
        Assert ($r.Out -notmatch '\uFFFD') '出现非法 Unicode（U+FFFD 替换符）'
    }

    # ============ §34 JSON ============
    $json = @(
        '{',
        '  "name": "张三",',
        '  "price": 99.8,',
        '  "message": "交易已经完成",',
        '  "path": "C:\\Users\\MR\\Desktop",',
        '  "variable": "$user",',
        '  "regex": "foo.*bar"',
        '}'
    )
    Write-Utf8 (Join-Path $root 'data.json') ($json -join "`n")
    foreach ($q in @('"name": "张三"','C:\\Users\\MR\\Desktop','"$user"','"foo.*bar"')) {
        $r = Invoke-Srg -Stdin $q @($root)
        Assert-Match "S34 JSON [$q]" $r 'data\.json'
    }

    # ============ §35 XML / HTML ============
    Write-Utf8 (Join-Path $root 'page.html') '<div class="user-card" data-name="张三">'
    $r = Invoke-Srg -Stdin '<div class="user-card" data-name="张三">' @($root)
    Assert-Match 'S35 HTML 整标签' $r 'page\.html'

    # ============ §36 C/C++ 宏 ============
    $cMacro = '#define RTC_SET_U8(member, value) (*(volatile unsigned char *)&rtcdate.member = (unsigned char)(value))'
    Write-Utf8 (Join-Path $root 'macro.c') $cMacro
    $r = Invoke-Srg -Stdin $cMacro @($root)
    Assert-Match 'S36 C 宏（# ( ) * & .）' $r 'macro\.c'

    # ============ §37 JavaScript ============
    $jsLine = 'const value = user["name"] ?? "$unknown";'
    Write-Utf8 (Join-Path $root 'app.js') $jsLine
    $r = Invoke-Srg -Stdin $jsLine @($root)
    Assert-Match 'S37 JavaScript ?? "$"' $r 'app\.js'

    # ============ §38 PowerShell 代码 ============
    $psCode = '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()'
    Write-Utf8 (Join-Path $root 'setup.ps1') $psCode
    $r = Invoke-Srg -Stdin $psCode @($root)
    Assert-Match 'S38 PowerShell 代码' $r 'setup\.ps1'

    # ============ §39 反斜杠 ============
    $bs = @('C:\Tools\SafeRG\bin','\\server\share\folder','\d+\w+')
    Write-Utf8 (Join-Path $root 'backslash.txt') ($bs -join "`n")
    foreach ($q in $bs) {
        $r = Invoke-Srg -Stdin $q @($root)
        Assert-Match "S39 反斜杠 [$q]" $r 'backslash\.txt'
    }

    # ============ §40 连续反斜杠 ============
    $bsSeq = @('\','\\','\\\','\\\\')
    $bsFile = Join-Path $root 'backslash-seq.txt'
    Write-Utf8 $bsFile ($bsSeq -join "`n")
    foreach ($q in $bsSeq) {
        $r = Invoke-Srg -Stdin $q @($bsFile)
        Test "S40 连续反斜杠 [$q]" { Assert ($r.Code -eq 0) "code=$($r.Code) out=$(Out-Snippet $r.Out)" }
    }
    $r = Invoke-Srg -Stdin '\\' @($bsFile)
    $n2 = ([regex]::Matches($r.Out, ':\d+:\d+:')).Count
    $r = Invoke-Srg -Stdin '\\\' @($bsFile)
    $n3 = ([regex]::Matches($r.Out, ':\d+:\d+:')).Count
    $r = Invoke-Srg -Stdin '\\\\' @($bsFile)
    $n4 = ([regex]::Matches($r.Out, ':\d+:\d+:')).Count
    Test 'S40b 反斜杠数量严格区分' {
        Assert ($n2 -eq 3) "\\\\ 命中 $n2 行（应为 3：\\、\\\、\\\\）"
        Assert ($n3 -eq 2) "\\\ 命中 $n3 行（应为 2：\\\、\\\\）"
        Assert ($n4 -eq 1) "\\\\ 命中 $n4 行（应为 1：\\\\）"
    }

    # ============ §41 空 Query ============
    $r = Invoke-Srg @('', $root)
    Test 'S41 空 Query 参数 exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）"; Assert ($r.Out -match '缺少搜索内容') "提示: $(Out-Snippet $r.Out)" }
    $r = Invoke-Srg -Stdin '' @($root)
    Test 'S41b 空 STDIN exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）" }

    # ============ §42 纯换行 Query ============
    $r = Invoke-Srg -Stdin "`n`n" @($root)
    Test 'S42 纯换行 exit=2（不搜索整个项目）' { Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）" }

    # ============ §43 超大结果文件 5MB ============
    $sb5 = [System.Text.StringBuilder]::new()
    for ($i = 1; $i -le 100000; $i++) {
        if ($i -eq 1) { $null = $sb5.AppendLine('BIG_FILE_START_MARK') }
        elseif ($i -eq 50000) { $null = $sb5.AppendLine('BIG_FILE_MID_MARK') }
        elseif ($i -eq 100000) { $null = $sb5.AppendLine('BIG_FILE_END_MARK') }
        else { $null = $sb5.AppendLine('padding line') }
    }
    Write-Utf8 (Join-Path $root 'big5mb.txt') $sb5.ToString()
    foreach ($q in @('BIG_FILE_START_MARK','BIG_FILE_MID_MARK','BIG_FILE_END_MARK')) {
        $r = Invoke-Srg @($q, $root)
        Assert-Match "S43 5MB [$q]" $r 'big5mb\.txt'
    }

    # ============ §44 二进制文件 ============
    # rg 语义：目录遍历时默认跳过二进制；显式指定文件时搜索（匹配则提示，不输出内容）
    $rnd7 = [System.Random]::new(7)
    $bin1 = New-Object byte[] 100000; $rnd7.NextBytes($bin1)
    $bin2 = New-Object byte[] 100000; $rnd7.NextBytes($bin2)
    $marker = [System.Text.Encoding]::ASCII.GetBytes('BINARY_ASCII_MARKER')
    [System.IO.File]::WriteAllBytes((Join-Path $root 'blob.bin'), [byte[]]($bin1 + $marker + $bin2))
    $r = Invoke-Srg @('BINARY_ASCII_MARKER', (Join-Path $root 'blob.bin'))
    Test 'S44 二进制：显式文件匹配且不输出垃圾' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'binary file matches') "缺少二进制提示: $(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch 'BINARY_ASCII_MARKER') '二进制内容被输出！'
    }
    $r = Invoke-Srg @('BINARY_ASCII_MARKER', $root)
    Test 'S44b 目录遍历默认跳过二进制' { Assert ($r.Code -eq 1) "code=$($r.Code)（应跳过二进制，与 rg 一致）" }

    # ============ §45 并存的 rg ============
    $rgPath = (Get-Command rg).Source
    $rgVer = rg --version | Select-Object -First 1
    Test 'S45 rg 仍是原始 ripgrep' {
        Assert ($rgPath -like '*chocolatey*' -or $rgVer -match '^ripgrep') "rgPath=$rgPath ver=$rgVer"
        Assert ($rgVer -match '^ripgrep') 'rg 已被替换！'
        Assert ((Get-Command rg).Source -ne (Get-Command srg -ErrorAction SilentlyContinue).Source) 'rg 指向了 srg！'
    }

    # ============ §46 Shell 无关性检查（源码） ============
    $badLines = foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot '..\src') -Filter '*.cs') {
        foreach ($line in Get-Content $f.FullName) {
            $code = $line -replace '//.*$', ''
            if ($code -match 'Invoke-Expression|\biex\b|cmd\s+/c|powershell\s+-Command|pwsh\s+-Command') { $line.Trim() }
        }
    }
    Test 'S46 源码无 Invoke-Expression/iex/cmd /c' { Assert ($badLines.Count -eq 0) "发现: $($badLines -join ' | ')" }

    # ============ §47 命令注入对抗 ============
    $injections = @(
        '"; Remove-Item C:\DO_NOT_DELETE -Recurse; "'
        '$(Get-Process)'
        '`whoami`'
        '& calc.exe'
        '| Stop-Computer'
        '; echo HACKED'
    )
    Write-Utf8 (Join-Path $root 'inject.txt') ($injections -join "`n")
    foreach ($q in $injections) {
        $r = Invoke-Srg -Stdin $q @($root)
        Assert-Match "S47 注入对抗 [$q]" $r 'inject\.txt'
    }
    Test 'S47b 无副作用（未删除文件/未启动 calc）' {
        Assert (-not (Test-Path 'C:\DO_NOT_DELETE')) 'DO_NOT_DELETE 目录被删除了！'
        Assert (-not (Get-Process calc -ErrorAction SilentlyContinue)) 'calc.exe 被启动了！'
    }

    # ============ §48 文件名特殊字符 ============
    foreach ($fn in @('test [1].txt','test (final).txt','hello-world.txt','foo.bar.txt','中文 文件.txt')) {
        Write-Utf8 (Join-Path $root $fn) 'FILENAME_SPECIAL_MARK'
    }
    $r = Invoke-Srg @('FILENAME_SPECIAL_MARK', $root)
    Test 'S48 文件名特殊字符' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        foreach ($fn in @('test [1].txt','test (final).txt','hello-world.txt','foo.bar.txt','中文 文件.txt')) {
            Assert ($r.Out -match [regex]::Escape($fn)) "缺少 $fn"
        }
    }

    # ============ §49 Case Sensitivity ============
    Write-Utf8 (Join-Path $root 'case.txt') "SafeRG`nsaferg`nSAFERG`nSafeRg"
    $r = Invoke-Srg @('--case-sensitive', 'SafeRG', (Join-Path $root 'case.txt'))
    Test 'S49 --case-sensitive 只匹配 SafeRG' { Assert ($r.Code -eq 0); Assert ([regex]::Matches($r.Out, ':1:').Count -ge 1); Assert ($r.Out -notmatch ':2:') "out=$(Out-Snippet $r.Out)" }
    $r = Invoke-Srg @('--ignore-case', 'saferg', (Join-Path $root 'case.txt'))
    Test 'S49b --ignore-case 匹配全部 4 行' { Assert ($r.Code -eq 0); Assert ([regex]::Matches($r.Out, ':[1234]:').Count -ge 4) "out=$(Out-Snippet $r.Out)" }

    # ============ §50 Context ============
    Write-Utf8 (Join-Path $root 'ctx6.txt') "line1`nline2`nTARGET_CONTEXT_LINE`nline4`nline5`nline6"
    $r = Invoke-Srg @('--context', '2', 'TARGET_CONTEXT_LINE', $root)
    Test 'S50 --context 2 上下文正确' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'line1' -and $r.Out -match 'line2' -and $r.Out -match 'line4' -and $r.Out -match 'line5') "上下文行缺失: $(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch 'line6') '上下文超出范围！'
    }

    # ============ §51 列号和行号 ============
    Write-Utf8 (Join-Path $root 'col.txt') 'aaaa TARGET'
    $r = Invoke-Srg @('TARGET', (Join-Path $root 'col.txt'))
    Test 'S51 path:line:col:text 准确' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        $m = [regex]::Match($r.Out, ':(\d+):(\d+):')
        Assert $m.Success "输出格式不对: $(Out-Snippet $r.Out)"
        Assert ($m.Groups[1].Value -eq '1') "行号应为 1，实际 $($m.Groups[1].Value)"
        Assert ($m.Groups[2].Value -eq '6') "列号应为 6（TARGET 从第 6 列开始），实际 $($m.Groups[2].Value)"
    }

    # ============ §52 STDIN Query 综合 ============
    $mix = "中文混合 `$dollar `"quote`" 'single' `| pipe & amp \ backslash`n第二行 ✅ emoji"
    Write-Utf8 (Join-Path $root 'stdin-mix.txt') $mix
    $r = Invoke-Srg -Stdin $mix @($root)
    Assert-Match 'S52 STDIN 综合（含换行）' $r 'stdin-mix\.txt'

    # ============ §53 Query File 复杂 ============
    Write-Utf8 (Join-Path $root 'query.txt') $jsLine
    $r = Invoke-Srg @('--query-file', (Join-Path $root 'query.txt'), $root)
    Assert-Match 'S53 Query File 复杂内容' $r 'app\.js'

    # ============ §54 STDIN 与 Query 参数冲突 ============
    $r = Invoke-Srg @('plainquery', '--stdin', $root)
    Test 'S54 参数+--stdin 冲突报错 exit=2' { Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）"; Assert ($r.Out -match '--stdin') "提示: $(Out-Snippet $r.Out)" }

    # ============ §55 Query File 不存在 ============
    $r = Invoke-Srg @('--query-file', 'Z:\THIS_FILE_DOES_NOT_EXIST', $root)
    Test 'S55 Query File 不存在 exit=2' {
        Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）"
        Assert ($r.Out -match '查询文件不存在') "提示: $(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch 'Stack trace|at SafeRG') '输出了 stack trace！'
    }

    # ============ §56 搜索目录不存在 ============
    $r = Invoke-Srg @('x', 'Z:\NO_SUCH_DIR_9281')
    Test 'S56 目录不存在 exit=2 简洁错误' {
        Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2）"
        Assert ($r.Out -notmatch 'Stack trace|at SafeRG') '输出了 stack trace！'
    }

    # ============ §57 权限错误 ============
    $deniedFile = Join-Path $root 'denied.txt'
    Write-Utf8 $deniedFile 'DENIED_TEST_MARK'
    $who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $denyWorks = $false
    try {
        & icacls $deniedFile /deny "${who}:(R)" 2>&1 | Out-Null
        try { $null = [System.IO.File]::OpenRead($deniedFile); $denyWorks = $false }
        catch { $denyWorks = $true }
        if ($denyWorks) {
            $r = Invoke-Srg @('DENIED_TEST_MARK', $root)
            Test 'S57 权限拒绝不 crash' { Assert ($r.Code -eq 2) "code=$($r.Code)（应为 2，rg 报权限错误）" }
        } else {
            Skip 'S57 权限错误' '当前为管理员，ACL deny 不生效，无法构造'
        }
    } finally {
        & icacls $deniedFile /remove:d "$who" 2>&1 | Out-Null
    }

    # ============ §58 Ctrl+C（用 Stop-Process 模拟终止） ============
    $beforeRg = @(Get-Process rg -ErrorAction SilentlyContinue).Count
    $bigDir = Join-Path $root 'big'
    New-Item -ItemType Directory $bigDir | Out-Null
    $sbBig = [System.Text.StringBuilder]::new()
    for ($i = 0; $i -lt 50000; $i++) { $null = $sbBig.AppendLine("common id line $i") }
    Write-Utf8 (Join-Path $bigDir 'huge.txt') $sbBig.ToString()
    $p = Start-Process -FilePath $script:Srg -ArgumentList @('id', $bigDir) -RedirectStandardOutput (Join-Path $root 'ctrl.out') -RedirectStandardError (Join-Path $root 'ctrl.err') -PassThru -NoNewWindow
    Start-Sleep -Milliseconds 150
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $afterRg = @(Get-Process rg -ErrorAction SilentlyContinue).Count
    Test 'S58 终止后无残留 rg 子进程' { Assert (($afterRg - $beforeRg) -le 1) "残留 rg 进程: $($afterRg - $beforeRg)" }

    # ============ §59 临时文件清理 ============
    $tmpBefore = @(Get-ChildItem $env:TEMP -Filter 'safe-rg-*.tmp' -ErrorAction SilentlyContinue).Count
    $null = Invoke-Srg -Stdin 'foo | bar' @($root)
    $null = Invoke-Srg @('--query-file', (Join-Path $root 'long29q.txt'), $root)
    $null = Invoke-Srg @('--query-file', (Join-Path $root 'q33.txt'), $root)
    $tmpAfter = @(Get-ChildItem $env:TEMP -Filter 'safe-rg-*.tmp' -ErrorAction SilentlyContinue).Count
    Test 'S59 无临时文件残留' { Assert ($tmpAfter -le $tmpBefore) "残留: $($tmpAfter - $tmpBefore) 个" }

    # ============ §60 重复执行 100 次 ============
    $badCodes = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt 100; $i++) {
        $null = & $script:Srg 'REPEAT_MARK' $root 2>$null
        if ($LASTEXITCODE -ne 1) { $badCodes++ }
    }
    $sw.Stop()
    Test 'S60 重复 100 次稳定' { Assert ($badCodes -eq 0) "$badCodes 次退出码异常（应全为 1，无匹配）" }
    $rgAfter100 = @(Get-Process rg -ErrorAction SilentlyContinue).Count
    Test 'S60b 100 次后无残留进程' { Assert (($rgAfter100 - $beforeRg) -le 1) "残留 rg: $($rgAfter100 - $beforeRg)" }

    # ============ §61 并发调用 10 个 ============
    for ($i = 1; $i -le 10; $i++) { Write-Utf8 (Join-Path $root "con$i.txt") "CONCURRENT_MARK_$i" }
    $procs = for ($i = 1; $i -le 10; $i++) {
        Start-Process -FilePath $script:Srg -ArgumentList @("CONCURRENT_MARK_$i", $root) `
            -RedirectStandardOutput (Join-Path $root "conc-$i.out") -RedirectStandardError (Join-Path $root "conc-$i.err") -PassThru -NoNewWindow
    }
    $procs | Wait-Process
    $okConc = 0
    for ($i = 1; $i -le 10; $i++) {
        $c = Get-Content (Join-Path $root "conc-$i.out") -Raw -ErrorAction SilentlyContinue
        if ($c -match "con$i\.txt") { $okConc++ }
    }
    Test 'S61 并发 10 个全部正确' { Assert ($okConc -eq 10) "成功 $okConc/10" }

    # ============ §62 Agent 超常见词保护 ============
    foreach ($word in @('id','get','class')) {
        $lines = 1..500 | ForEach-Object { "$word common token $_" }
        Write-Utf8 (Join-Path $root "common-$word.txt") ($lines -join "`n")
        $r = Invoke-Srg @($word, (Join-Path $root "common-$word.txt"))
        $cnt = ([regex]::Matches($r.Out, ":$word common")).Count
        Test "S62 常见词 [$word] 截断 200" {
            Assert ($r.Code -eq 0) "code=$($r.Code)"
            Assert ($cnt -eq 200) "匹配行=$cnt（应为 200）"
            Assert ($r.Out -match 'Results truncated') '缺少截断提示'
        }
    }

    # ============ §63 Agent 错误 Query .* ============
    Write-Utf8 (Join-Path $root 'star-dot.txt') 'contains .* literally'
    $r = Invoke-Srg @('.*', $root)
    Test 'S63 .* 字面搜索（不匹配全库）' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'star-dot\.txt') '未按字面命中'
        $hitLines = ([regex]::Matches($r.Out, ':\d+:\d+:')).Count
        Assert ($hitLines -le 10) ".* 命中 $hitLines 行（全库数百行——被当正则了！）"
    }

    # ============ §64/65/66 Agent 场景 ============
    $s64 = 'if (status == TradeStatus.TRADING && userId != null) {'
    Write-Utf8 (Join-Path $root 'trade.java') $s64
    $r = Invoke-Srg -Stdin $s64 @($root)
    Assert-Match 'S64 代码片段' $r 'trade\.java'
    $s65 = '{"status":"TRADING","userId":123}'
    Write-Utf8 (Join-Path $root 'trade.json') $s65
    $r = Invoke-Srg -Stdin $s65 @($root)
    Assert-Match 'S65 JSON 单行' $r 'trade\.json'
    $s66 = 'https://api.example.com/v1/users?id=123&name=张三'
    Write-Utf8 (Join-Path $root 'url.txt') $s66
    $r = Invoke-Srg -Stdin $s66 @($root)
    Assert-Match 'S66 URL ? & = : /' $r 'url\.txt'

    # ============ §67 性能：1000 小文件 ============
    $perfDir = Join-Path $root 'perf1000'
    New-Item -ItemType Directory $perfDir | Out-Null
    for ($i = 1; $i -le 1000; $i++) {
        if ($i % 20 -eq 0) { Write-Utf8 (Join-Path $perfDir "f$i.txt") "PERF_TARGET_$i some content" }
        else { Write-Utf8 (Join-Path $perfDir "f$i.txt") 'ordinary filler content' }
    }
    $swRg = [System.Diagnostics.Stopwatch]::StartNew()
    $null = rg 'PERF_TARGET' $perfDir 2>$null
    $swRg.Stop()
    $swSrg = [System.Diagnostics.Stopwatch]::StartNew()
    $null = & $script:Srg 'PERF_TARGET' $perfDir 2>$null
    $swSrg.Stop()
    Test 'S67 1000 文件性能' {
        Assert ($swSrg.ElapsedMilliseconds -lt 3000) "srg 耗时 $($swSrg.ElapsedMilliseconds)ms（应 <3000ms）"
        Assert ($swSrg.ElapsedMilliseconds -lt ($swRg.ElapsedMilliseconds * 10 + 200)) "srg $($swSrg.ElapsedMilliseconds)ms vs rg $($swRg.ElapsedMilliseconds)ms，开销离谱"
    }

    # ============ §68 Long Query 性能 ============
    $swLQ = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-Srg @('--query-file', (Join-Path $root 'long29q.txt'), $root)
    $swLQ.Stop()
    $swLQ2 = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-Srg @('--query-file', (Join-Path $root 'long28q.txt'), $root)
    $swLQ2.Stop()
    Test 'S68 Long Query 性能' {
        Assert ($swLQ.ElapsedMilliseconds -lt 5000) "50000 字符耗时 $($swLQ.ElapsedMilliseconds)ms"
        Assert ($swLQ2.ElapsedMilliseconds -lt 5000) "10000 字符耗时 $($swLQ2.ElapsedMilliseconds)ms"
    }

    # ============ §69 Help ============
    $r = Invoke-Srg @('--help')
    Test 'S69 Help 关键选项齐全' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        foreach ($kw in @('Literal','--regex','--stdin','--query-file','--glob','--hidden','--ignore-case','--case-sensitive','--context','--max-results')) {
            Assert ($r.Out -match [regex]::Escape($kw)) "缺少 $kw"
        }
    }

    # ============ §70 最终 Agent 模拟 ============
    $r = Invoke-Srg -Stdin $jsLine @($root)
    Test 'S70 Agent 模拟：一次调用找到目标' {
        Assert ($r.Code -eq 0) "code=$($r.Code)"
        Assert ($r.Out -match 'app\.js') "out=$(Out-Snippet $r.Out)"
        Assert ($r.Out -notmatch 'PowerShell quoting|error') '发生 quoting 错误'
    }
}
finally {
    # 保留测试环境用于分析
    Write-Host ""
    Write-Host "测试数据保留在: $root"
}

# ============ 汇总 ============
Write-Host ""
Write-Host "========== SafeRG Stress Test 结果 =========="
Write-Host ("Version:    {0}" -f $script:EnvInfo.SrgVersion)
Write-Host ("Install:    {0}" -f $script:EnvInfo.SrgPath)
Write-Host ("rg Path:    {0}  ({1})" -f $script:EnvInfo.RgPath, $script:EnvInfo.RgVersion)
Write-Host ("PowerShell: {0}" -f $script:EnvInfo.PS)
Write-Host ""
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
Write-Host ("Tests Passed: {0}   Tests Failed: {1}   Skipped: {2}" -f $passes, $fails, $skips)
exit $fails
