namespace SafeRG;

public enum QuerySourceKind { Positional, Stdin, QueryFile }

/// <summary>SafeRG 命令行选项（手写解析，不依赖第三方框架；白名单式支持常用 rg 参数）。</summary>
public sealed class Options
{
    public bool Help;
    public bool Version;
    public bool RegexMode;              // --regex：显式正则模式（默认关）
    public bool Hidden;                 // --hidden
    public bool? CaseInsensitive;       // true = -i/--ignore-case，false = --case-sensitive，null = 默认
    public bool? SmartCase;             // -S/--smart-case：全小写 query 忽略大小写（rg 语义）；与 -i/--case-sensitive 冲突报错
    public bool NoIgnore;               // --no-ignore：不尊重 .gitignore/.git/info/exclude/全局 ignore（透传 rg）
    public List<string> Globs = new();  // --glob，可重复
    public List<string> Types = new();  // -t/--type，可重复（透传 rg，格式白名单校验）
    public List<string> TypeAdds = new(); // --type-add name:glob（透传 rg，格式白名单校验）
    public int? Context;                // -C/--context（含 -CN 紧凑形式）
    public int MaxResults = Program.DefaultMaxResults; // --max-results，0 = 不限制
    public QuerySourceKind Source = QuerySourceKind.Positional;
    public string? QueryFile;
    public string? PositionalQuery;     // 第一个位置参数 = 查询
    public string? QueryText;           // --query <文本>：显式查询（与位置参数互斥）
    public List<string> Paths = new();  // 其余位置参数 = 搜索路径

    // ---- 1.2.0 ----
    public bool JsonMode;               // --json：Agent 机器可读输出
    public string? Encoding;            // --encoding <name>；"auto" = 自动补搜
    public int MaxLineLength = Program.DefaultMaxLineLength; // --max-line-length，0 = 不限制
    public bool RequireComplete;        // --require-complete：截断时 exit 3
    public bool Debug;                  // --debug：输出调试信息（可能暴露查询片段）
    public bool TextMode;               // --text：强制按文本搜索
    public bool InvertMatch;            // -v：反转匹配（透传 rg -v）
    public bool FixedStrings;           // -F：默认 Literal 下 no-op；--regex 时透传 rg -F

    // ---- 1.3.0（Agent UX）----
    public bool FilesWithMatches;       // -l/--files-with-matches：只输出文件列表
    public bool OnlyMatching;           // -o/--only-matching：只输出匹配片段
    public bool NoColumn;               // --no-column：输出 path:line:text（仅文本模式；JSON 拒绝）

    public Options Clone()
    {
        var c = new Options
        {
            Help = Help, Version = Version, RegexMode = RegexMode, Hidden = Hidden,
            CaseInsensitive = CaseInsensitive, SmartCase = SmartCase, NoIgnore = NoIgnore,
            Context = Context, MaxResults = MaxResults, Source = Source, QueryFile = QueryFile,
            PositionalQuery = PositionalQuery, QueryText = QueryText, JsonMode = JsonMode,
            Encoding = Encoding, MaxLineLength = MaxLineLength, RequireComplete = RequireComplete,
            Debug = Debug, TextMode = TextMode, InvertMatch = InvertMatch, FixedStrings = FixedStrings,
            FilesWithMatches = FilesWithMatches, OnlyMatching = OnlyMatching, NoColumn = NoColumn,
        };
        c.Globs.AddRange(Globs);
        c.Types.AddRange(Types);
        c.TypeAdds.AddRange(TypeAdds);
        c.Paths.AddRange(Paths);
        return c;
    }

    /// <summary>已知但故意不支持的常见 rg 功能 → 明确 fallback 提示（替代笼统的"未知选项"）。</summary>
    static readonly Dictionary<string, string> KnownUnsupported = new()
    {
        ["--files"] = "--files 是文件枚举操作，不属于 SafeRG 的内容搜索定位。请使用原生 rg：rg --files [路径]",
        ["-c"] = "-c/--count 是计数操作。请使用原生 rg（SafeRG 专注于内容搜索）",
        ["--count"] = "-c/--count 是计数操作。请使用原生 rg（SafeRG 专注于内容搜索）",
        ["--color"] = "--color 输出着色不适合 Agent 解析。请使用原生 rg：rg --color auto",
        ["--heading"] = "--heading 分组标题输出请使用原生 rg",
        ["--pretty"] = "--pretty 输出请使用原生 rg",
        ["--sort"] = "--sort 排序输出请使用原生 rg",
        ["-r"] = "--replace 文本替换请使用原生 rg",
        ["--replace"] = "--replace 文本替换请使用原生 rg",
        ["--pcre2"] = "PCRE2 正则请使用原生 rg：rg --pcre2",
        ["--no-messages"] = "--no-messages 请使用原生 rg",
        ["-e"] = "-e/--regexp 多 pattern 请使用原生 rg（SafeRG 每次一个查询）",
        ["--regexp"] = "-e/--regexp 多 pattern 请使用原生 rg（SafeRG 每次一个查询）",
        ["--max-count"] = "SafeRG 使用 --max-results 控制结果上限（语义为全局上限，比 rg 的每文件 -m 更强）",
        ["--files-without-match"] = "--files-without-match 请使用原生 rg",
        ["-L"] = "--follow 跟随符号链接请使用原生 rg",
        ["--follow"] = "--follow 跟随符号链接请使用原生 rg",
    };

    public static Options Parse(string[] args)
    {
        var o = new Options();
        bool positionalOnly = false; // "--" 之后全部按位置参数处理

        void AddPositional(string v)
        {
            // --query 模式下位置参数都是搜索路径（与 --stdin/--query-file 一致）
            if (o.Source == QuerySourceKind.Positional && o.PositionalQuery == null && o.QueryText == null)
                o.PositionalQuery = v;
            else
                o.Paths.Add(v);
        }

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            if (positionalOnly) { AddPositional(a); continue; }
            if (a == "--") { positionalOnly = true; continue; }

            // -CN 紧凑形式（-C0/-C1/-C10 → --context N）；-C-1 / -Cabc / -C999999999999 友好报错
            if (a.Length > 2 && a[0] == '-' && a[1] == 'C')
            {
                string cv = a[2..];
                if (int.TryParse(cv, out int ctx) && ctx >= 0) { o.Context = ctx; continue; }
                throw new SafeRgException($"--context 需要非负整数，收到: {a}");
            }
            // -tjava 紧凑形式（rg 兼容）
            if (a.Length > 2 && a[0] == '-' && a[1] == 't')
            {
                o.Types.Add(ValidateType(a[2..]));
                continue;
            }

            string name = a;
            string? inline = null;
            if (a.StartsWith("--", StringComparison.Ordinal))
            {
                int eq = a.IndexOf('=');
                if (eq > 0) { name = a[..eq]; inline = a[(eq + 1)..]; }
            }

            // 取选项值：支持 "--opt value" 与 "--opt=value" 两种写法
            string Next()
            {
                if (inline != null) { string v = inline; inline = null; return v; }
                if (i + 1 >= args.Length) throw new SafeRgException($"选项 {name} 缺少参数值。");
                return args[++i];
            }

            switch (name)
            {
                case "-h": case "--help": o.Help = true; break;
                case "--version": o.Version = true; break;
                case "--stdin":
                    if (o.Source == QuerySourceKind.QueryFile) throw new SafeRgException("--stdin 与 --query-file 只能使用一种。");
                    o.Source = QuerySourceKind.Stdin; break;
                case "--regex": o.RegexMode = true; break;
                case "--hidden": o.Hidden = true; break;
                case "--no-ignore": o.NoIgnore = true; break;
                case "-i": case "--ignore-case":
                    if (o.CaseInsensitive == false) throw new SafeRgException("--ignore-case 与 --case-sensitive 冲突。");
                    if (o.SmartCase == true) throw new SafeRgException("--ignore-case 与 --smart-case 冲突：显式大小写选项优先级明确，请二选一。");
                    o.CaseInsensitive = true; break;
                case "--case-sensitive":
                    if (o.CaseInsensitive == true) throw new SafeRgException("--case-sensitive 与 --ignore-case 冲突。");
                    if (o.SmartCase == true) throw new SafeRgException("--case-sensitive 与 --smart-case 冲突：显式大小写选项优先级明确，请二选一。");
                    o.CaseInsensitive = false; break;
                case "-S": case "--smart-case":
                    if (o.CaseInsensitive != null) throw new SafeRgException("--smart-case 与 --ignore-case/--case-sensitive 冲突：请二选一。");
                    o.SmartCase = true; break;
                case "--query-file":
                    if (o.Source == QuerySourceKind.Stdin) throw new SafeRgException("--query-file 与 --stdin 只能使用一种。");
                    o.Source = QuerySourceKind.QueryFile; o.QueryFile = Next(); break;
                case "--query":
                    if (o.QueryText != null) throw new SafeRgException("--query 只能指定一次。");
                    o.QueryText = Next(); break;
                case "-g": case "--glob": o.Globs.Add(Next()); break;
                case "-t": case "--type": o.Types.Add(ValidateType(Next())); break;
                case "--type-add": o.TypeAdds.Add(ValidateTypeAdd(Next())); break;
                case "-l": case "--files-with-matches": o.FilesWithMatches = true; break;
                case "-o": case "--only-matching": o.OnlyMatching = true; break;
                case "--no-column": o.NoColumn = true; break;
                case "-C": case "--context":
                    if (!int.TryParse(Next(), out int c) || c < 0)
                        throw new SafeRgException($"--context 需要非负整数。");
                    o.Context = c; break;
                case "--max-results":
                    if (!int.TryParse(Next(), out int m) || m < 0)
                        throw new SafeRgException("--max-results 需要非负整数（0 = 不限制）。");
                    o.MaxResults = m; break;
                case "--max-line-length":
                    if (!int.TryParse(Next(), out int ml) || ml < 0)
                        throw new SafeRgException("--max-line-length 需要非负整数（0 = 不限制）。");
                    o.MaxLineLength = ml; break;
                case "--encoding": o.Encoding = Next(); break;
                case "--json": o.JsonMode = true; break;
                case "--require-complete": o.RequireComplete = true; break;
                case "--debug": o.Debug = true; break;
                case "--text": o.TextMode = true; break;
                case "-v": o.InvertMatch = true; break;
                case "-n": break;                 // 兼容 no-op：SafeRG 始终输出行号
                case "-F": o.FixedStrings = true; break; // 默认 Literal 下 no-op；--regex 时透传 rg -F
                default:
                    if (KnownUnsupported.TryGetValue(name, out string? hint))
                        throw new SafeRgException(hint);
                    if (a.StartsWith("-", StringComparison.Ordinal) && a != "-")
                        throw new SafeRgException($"未知选项: {a}（--help 查看帮助；如需搜索以 - 开头的文本，可用 srg --query \"-文本\" 或 srg -- \"-文本\"）");
                    AddPositional(a); break;
            }
        }

        if (!o.Help && !o.Version)
        {
            if (o.Source != QuerySourceKind.Positional && o.PositionalQuery != null)
                throw new SafeRgException("--stdin/--query-file 模式下位置参数都是搜索路径；查询内容请通过 STDIN 或文件提供。");
            if (o.QueryText != null)
            {
                if (o.PositionalQuery != null)
                    throw new SafeRgException("--query 与位置参数查询不能同时使用。");
                if (o.Source != QuerySourceKind.Positional)
                    throw new SafeRgException("--query 与 --stdin/--query-file 只能使用一种查询来源。");
            }
            if (o.NoColumn && o.JsonMode)
                throw new SafeRgException("--no-column 仅用于文本模式；JSON 模式始终包含结构化列信息。");
            if (o.JsonMode && o.FilesWithMatches)
                throw new SafeRgException("--json 与 -l 组合在 rg 中输出非 JSON（-l 优先），语义不明确。请使用文本模式 srg -l，或 --json 全量输出后自行提取路径。");
        }

        return o;
    }

    /// <summary>type 名白名单：仅字母数字 _ . -（防注入；未知 type 由 rg 给出清晰错误）。</summary>
    static string ValidateType(string v)
    {
        if (v.Length == 0 || v.Length > 64) throw new SafeRgException("--type 需要非空类型名（如 java / js / py）。");
        foreach (char ch in v)
            if (!(char.IsAsciiLetterOrDigit(ch) || ch is '_' or '.' or '-'))
                throw new SafeRgException($"--type 类型名包含非法字符: {v}");
        return v;
    }

    /// <summary>--type-add 格式白名单：name:glob（name 字母数字，整体无控制字符；防注入，透传独立 argv）。</summary>
    static string ValidateTypeAdd(string v)
    {
        int colon = v.IndexOf(':');
        if (colon <= 0 || colon == v.Length - 1)
            throw new SafeRgException("--type-add 需要 name:glob 格式（如 \"vue:*.vue\"）。");
        foreach (char ch in v)
            if (char.IsControl(ch))
                throw new SafeRgException("--type-add 包含控制字符，已拒绝。");
        ValidateType(v[..colon]); // name 部分复用 type 白名单
        return v;
    }
}
