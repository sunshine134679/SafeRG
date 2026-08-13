namespace SafeRG;

public enum QuerySourceKind { Positional, Stdin, QueryFile }

/// <summary>SafeRG 命令行选项（手写解析，不依赖第三方框架）。</summary>
public sealed class Options
{
    public bool Help;
    public bool Version;
    public bool RegexMode;              // --regex：显式正则模式（默认关）
    public bool Hidden;                 // --hidden
    public bool? CaseInsensitive;       // true = -i/--ignore-case，false = --case-sensitive，null = 默认
    public List<string> Globs = new();  // --glob，可重复
    public int? Context;                // -C/--context
    public int MaxResults = Program.DefaultMaxResults; // --max-results，0 = 不限制
    public QuerySourceKind Source = QuerySourceKind.Positional;
    public string? QueryFile;
    public string? PositionalQuery;     // 第一个位置参数 = 查询
    public string? QueryText;           // --query <文本>：显式查询（与位置参数互斥）
    public List<string> Paths = new();  // 其余位置参数 = 搜索路径

    // ---- 1.1.0 新增 ----
    public bool JsonMode;               // --json：Agent 机器可读输出（透传 rg --json + 截断标记）
    public string? Encoding;            // --encoding <name>：透传 rg（gbk/utf-16le/...）；"auto" = 自动补搜
    public int MaxLineLength = Program.DefaultMaxLineLength; // --max-line-length，0 = 不限制
    public bool RequireComplete;        // --require-complete：截断时返回 exit 3
    public bool Debug;                  // --debug：输出调试信息（可能暴露查询片段）
    public bool TextMode;               // --text：强制按文本搜索（透传 rg --text）
    public bool InvertMatch;            // -v：反转匹配（透传 rg -v，语义与 rg 一致）
    public bool FixedStrings;           // -F：默认 Literal 下的兼容 no-op；与 --regex 同用时透传 rg -F

    public Options Clone()
    {
        var c = new Options
        {
            Help = Help, Version = Version, RegexMode = RegexMode, Hidden = Hidden,
            CaseInsensitive = CaseInsensitive, Context = Context, MaxResults = MaxResults,
            Source = Source, QueryFile = QueryFile, PositionalQuery = PositionalQuery,
            QueryText = QueryText, JsonMode = JsonMode, Encoding = Encoding,
            MaxLineLength = MaxLineLength, RequireComplete = RequireComplete,
            Debug = Debug, TextMode = TextMode, InvertMatch = InvertMatch, FixedStrings = FixedStrings,
        };
        c.Globs.AddRange(Globs);
        c.Paths.AddRange(Paths);
        return c;
    }

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
                case "-i": case "--ignore-case":
                    if (o.CaseInsensitive == false) throw new SafeRgException("--ignore-case 与 --case-sensitive 冲突。");
                    o.CaseInsensitive = true; break;
                case "--case-sensitive":
                    if (o.CaseInsensitive == true) throw new SafeRgException("--case-sensitive 与 --ignore-case 冲突。");
                    o.CaseInsensitive = false; break;
                case "--query-file":
                    if (o.Source == QuerySourceKind.Stdin) throw new SafeRgException("--query-file 与 --stdin 只能使用一种。");
                    o.Source = QuerySourceKind.QueryFile; o.QueryFile = Next(); break;
                case "--query":
                    if (o.QueryText != null) throw new SafeRgException("--query 只能指定一次。");
                    o.QueryText = Next(); break;
                case "-g": case "--glob": o.Globs.Add(Next()); break;
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
                // ---- 1.1.0 新选项 ----
                case "--json": o.JsonMode = true; break;
                case "--require-complete": o.RequireComplete = true; break;
                case "--debug": o.Debug = true; break;
                case "--text": o.TextMode = true; break;
                case "-v": o.InvertMatch = true; break;
                case "-n": break;                 // 兼容 no-op：SafeRG 始终输出行号
                case "-F": o.FixedStrings = true; break; // 默认 Literal 下为 no-op；--regex 时透传 rg -F
                default:
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
        }

        return o;
    }
}
