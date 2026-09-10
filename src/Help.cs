namespace SafeRG;

public static class Help
{
    public static void Print()
    {
        string rgPath = RgRunner.FindRg() ?? "未找到（请安装 ripgrep）";
        Console.WriteLine($"SafeRG {Program.Version} — ripgrep 的安全包装，专为 AI Agent 设计");
        Console.WriteLine($"ripgrep: {rgPath}");
        Console.WriteLine();
        Console.WriteLine("用法:");
        Console.WriteLine("  srg <查询> [路径...]             纯文本（字面量）搜索，默认不解释正则");
        Console.WriteLine("  srg --query <文本> [路径...]     显式指定查询（查询以 - 开头时最可靠）");
        Console.WriteLine("  <内容> | srg --stdin [路径...]   从 STDIN 读取完整查询（特殊字符/多行推荐）");
        Console.WriteLine("  srg --query-file 文件 [路径...]  从文件读取查询（超长文本推荐）");
        Console.WriteLine();
        Console.WriteLine("选项:");
        Console.WriteLine("  --regex             正则模式（默认关闭；默认等价于 rg -F 字面量模式）");
        Console.WriteLine("  --stdin             从 STDIN 读取查询文本");
        Console.WriteLine("  --query-file 文件   从文件读取查询文本（UTF-8 / UTF-16 / GBK 均可）");
        Console.WriteLine("  --query <文本>      显式提供查询（查询以 - 开头时无需 -- 分隔）");
        Console.WriteLine("  -i, --ignore-case   忽略大小写（遵循 rg 的 Unicode case-folding 语义）");
        Console.WriteLine("  --case-sensitive    区分大小写（默认；Regex 模式默认也区分，不做 smart-case）");
        Console.WriteLine("  -S, --smart-case    智能大小写（query 全小写→忽略大小写；含大写→区分；与 -i/--case-sensitive 互斥）");
        Console.WriteLine("  -l, --files-with-matches  只输出包含匹配的文件列表（Long Query 下全文验证后才输出）");
        Console.WriteLine("  -o, --only-matching 只输出匹配片段（保持 path:line:col 前缀；与 Long Query Mode 不兼容）");
        Console.WriteLine("  -t, --type 类型     按语言类型过滤，可重复（java/js/ts/py/c/cpp/rust/json 等，透传 rg 定义）");
        Console.WriteLine("  --type-add 定义     自定义类型（name:glob 格式，如 \"vue:*.vue\"；独立 argv 传递，防注入）");
        Console.WriteLine("  --hidden            搜索隐藏文件/目录");
        Console.WriteLine("  --no-ignore         搜索 .gitignore 等忽略规则排除的文件（与 --hidden 相互独立）");
        Console.WriteLine("  -g, --glob 模式     文件过滤，可重复。可靠写法：--glob \"!**/node_modules/**\"");
        Console.WriteLine("  -C, --context N     显示匹配行前后 N 行上下文（也支持 -C0 / -C1 / -C10 紧凑形式）");
        Console.WriteLine("  --max-results N     结果上限（默认 200；0 = 不限制）。全局上限：跨所有文件累计，达到即截断并在 stderr 提示（--require-complete 下 exit 3）");
        Console.WriteLine("  --max-line-length N 匹配行输出最大长度（默认 8192 字符，0 = 不限制）");
        Console.WriteLine("  --no-column         输出 path:line:text（去掉列号；仅文本模式，JSON 模式拒绝）");
        Console.WriteLine("  --require-complete  结果被截断时返回 exit 3（默认截断仍返回 0）");
        Console.WriteLine("  --encoding 编码     显式指定文件编码透传 rg（gbk / shift-jis / windows-1252 / utf-16le / utf-16be / auto 等）");
        Console.WriteLine("  --json              Agent 机器可读输出（rg --json 事件流 + 恒输出 saferg-summary 事件）");
        Console.WriteLine("  --text              强制按文本搜索二进制文件（透传 rg --text）");
        Console.WriteLine("  -v                  反转匹配（透传 rg -v；与 Long Query Mode 不兼容）");
        Console.WriteLine("  -n                  rg 兼容 no-op（SafeRG 始终输出行号）");
        Console.WriteLine("  -F                  rg 兼容（SafeRG 默认 Literal；与 --regex 同用时透传 rg -F）");
        Console.WriteLine("  --debug             输出调试信息（可能暴露查询片段）");
        Console.WriteLine("  -h, --help          显示本帮助");
        Console.WriteLine("  --version           显示版本");
        Console.WriteLine();
        Console.WriteLine("行为:");
        Console.WriteLine("  * 默认 Literal 模式：$、\"、'、|、&、;、()、[]、{}、.*+? 等一律按字面搜索");
        Console.WriteLine("  * 查询以 - 开头时：srg --query \"-文本\" path  或  srg -- \"-文本\" path");
        Console.WriteLine("  * 查询含换行时自动启用多行搜索（rg -U），兼容 LF / CRLF 文件");
        Console.WriteLine("  * 查询超过 4000 字符自动进入 Long Query Mode：anchor 定位 + 全文二次验证");
        Console.WriteLine("  * 输出契约：match 行 path:line:col:text；context 行 path-line-text");
        Console.WriteLine("    路径分隔符统一为 /（如 C:/Users/.../file.cs:10:2:text）");
        Console.WriteLine("  * 无匹配且查询含明显正则元字符（|、.*、^…$、\\d 等）时，输出一行 stderr 提示，建议改用 --regex（防静默假阴性）");
        Console.WriteLine("  * 无匹配且查询含非 ASCII 时，自动尝试 GBK/UTF-16 补搜并给出提示；补搜全 miss 时仅在真的检测到非 UTF-8 文本文件才告警（纯 UTF-8 项目保持安静；不猜测 CP1252/SJIS）");
        Console.WriteLine("  * 二进制文件：目录搜索默认跳过（避免向 Agent 输出二进制垃圾）；显式指定文件时提示 binary file matches");
        Console.WriteLine("    如需强制按文本搜索二进制内容，使用 --text");
        Console.WriteLine("  * 所有 [SafeRG] 提示输出到 stderr，stdout 只有搜索结果");
        Console.WriteLine("  * Exit Code：0=搜索完成且有匹配；1=无匹配；2=搜索/参数/IO 错误——注意 exit 2 不保证 stdout 为空，");
        Console.WriteLine("    已确认的部分匹配仍会输出（partial results）；3=结果被截断（仅 --require-complete 时）");
        Console.WriteLine();
        Console.WriteLine("SafeRG 专注于 Agent 安全的文本搜索，白名单式支持常用 rg 选项。");
        Console.WriteLine("如需 --files / --type 之外的 -c/--count / --color / --heading / --pretty / --sort / -r/--replace /");
        Console.WriteLine("--pcre2 / --no-messages / -e/--regexp / --max-count / --files-without-match / -L/--follow 等高级功能，");
        Console.WriteLine("请直接使用原生 rg（两者并存，互不影响）。");
        Console.WriteLine();
        Console.WriteLine("示例:");
        Console.WriteLine("  srg \"SecondhandItem\" .");
        Console.WriteLine("  $query | srg --stdin .");
        Console.WriteLine("  srg --query-file query.txt .");
        Console.WriteLine("  srg --regex \"foo.*bar\" .");
        Console.WriteLine("  srg --query \"--help\" .");
        Console.WriteLine("  srg \"hello\" . --glob \"!**/node_modules/**\" --context 3");
        Console.WriteLine("  srg --encoding gbk \"交易完成\" .");
        Console.WriteLine("  srg --json \"foo\" .");
    }

    public static void PrintVersion()
    {
        Console.WriteLine($"SafeRG {Program.Version} (win-x64 single-file)");
        Console.WriteLine($"ripgrep: {RgRunner.FindRg() ?? "未找到"}");
    }
}
