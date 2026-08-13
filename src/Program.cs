using System.Text;

namespace SafeRG;

/// <summary>
/// SafeRG 入口：ripgrep 的安全包装，专为 AI Agent 设计。
///
/// 核心安全原则：
/// 1. 默认 Literal（字面量）模式，绝不把用户输入解释为正则；
/// 2. 搜索内容始终作为独立参数通过 ProcessStartInfo.ArgumentList 传给 rg.exe，
///    绝不拼接命令行字符串，绝不使用 Invoke-Expression / cmd /c；
/// 3. 内部全程 UTF-8，兼容中文/日文/韩文/Emoji；
/// 4. 结构：Parse → Validate Query → Execute（Query 缺失统一 exit 2，绝不 NRE）。
/// </summary>
public static class Program
{
    public const string Version = "1.2.0";

    /// <summary>超过该长度的查询自动进入 Long Query Mode（anchor 定位 + 全文验证）。</summary>
    public const int LongQueryThreshold = 4000;

    /// <summary>Windows 命令行上限约 32767 字符，直接传参时保留安全余量。</summary>
    public const int CommandLineSafeLimit = 28000;

    /// <summary>结果数量默认上限，防止数万行输出灌爆 AI 上下文。</summary>
    public const int DefaultMaxResults = 200;

    /// <summary>Long Query Mode 候选文件上限，超过则提示改用更独特的查询。</summary>
    public const int MaxCandidates = 300;

    /// <summary>匹配行输出默认最大长度（防 1MB 单行灌爆上下文）；0 = 不限制。</summary>
    public const int DefaultMaxLineLength = 8192;

    public static int Main(string[] args)
    {
        // 全程 UTF-8：SafeRG 自身输入输出统一 UTF-8，避免中文乱码
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.InputEncoding = new UTF8Encoding(false);
        try { Encoding.RegisterProvider(CodePagesEncodingProvider.Instance); } catch { /* 平台不支持时忽略，回退 UTF-8 */ }

        try
        {
            Options opt = Options.Parse(args);
            if (opt.Help) { Help.Print(); return 0; }
            if (opt.Version) { Help.PrintVersion(); return 0; }

            string rgPath = RgRunner.FindRg()
                ?? throw new SafeRgException(
                    "未找到 ripgrep (rg.exe)。请先安装：winget install BurntSushi.ripgrep.MSVC  或  scoop install ripgrep");
            RgRunner.Init(rgPath);

            // ---- Validate Query：所有"参数解析完成但 Query 不存在"的路径统一到此 ----
            string query = QueryReader.Read(opt); // 位置参数 / --query / STDIN / 查询文件
            if (query.Length == 0)
                throw new SafeRgException(
                    "缺少搜索内容（Query）。用法：srg <查询> [路径...]；或 <内容> | srg --stdin [路径...]；或 srg --query <文本> [路径...]（--help 查看帮助）");

            // ---- Validate Target / 路径统一输出格式：一律使用 / 分隔（rg 输出跟随传入的搜索根格式）----
            string[] paths = opt.Paths.Count > 0
                ? opt.Paths.Select(NormalizePath).ToArray()
                : new[] { "." };

            (int code, bool truncated) = Dispatch(opt, query, paths);
            if (code == 0 && truncated && opt.RequireComplete)
                return 3; // --require-complete：结果被截断 → 专用非成功状态
            return code;
        }
        catch (SafeRgException ex)
        {
            Console.Error.WriteLine($"[SafeRG] {ex.Message}");
            return 2;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[SafeRG] 内部错误: {ex.Message}");
            return 2;
        }
    }

    /// <summary>搜索路径统一为 / 分隔（Windows 盘符形式 C:/...），保证输出 path 格式稳定。</summary>
    static string NormalizePath(string p) => p.Replace('\\', '/');

    static bool ContainsNonAscii(string s)
    {
        foreach (char ch in s)
            if (ch > 127) return true;
        return false;
    }

    /// <summary>策略层：根据查询内容与模式自动选择最安全的搜索方式。返回 (exitCode, 是否截断)。</summary>
    static (int Code, bool Truncated) Dispatch(Options o, string query, string[] paths)
    {
        // ---- 模式间冲突校验 ----
        if (o.InvertMatch && query.Length > LongQueryThreshold)
            throw new SafeRgException("-v（反转匹配）与 Long Query Mode 不兼容。");

        (int Code, bool Truncated) result;
        if (o.RegexMode)
        {
            // 正则模式：查询原样交给 rg；过长无法安全传递时明确报错
            if (query.Length > CommandLineSafeLimit)
                throw new SafeRgException($"正则查询过长（{query.Length} 字符），超过 Windows 命令行安全上限。请拆分正则或改用字面量模式（默认）。");
            Console.Error.WriteLine("[SafeRG] Regex mode");
            result = RgRunner.Run(o, query, literal: false, multiline: query.Contains('\n'), paths);
        }
        else if (query.Length > LongQueryThreshold)
        {
            result = LongQuery.Search(o, query, paths); // 超长：anchor + 全文验证
        }
        else if (query.Contains('\n'))
        {
            Console.Error.WriteLine("[SafeRG] Multiline mode");
            if (RgRunner.HasMultilineSupport)
                // 逐行转义后以 \r?\n 连接，兼容 LF 与 CRLF 文件
                result = RgRunner.Run(o, MultilineLiteral.BuildPattern(query), literal: false, multiline: true, paths);
            else
                result = LongQuery.Search(o, query, paths); // rg 太老（<13）不支持 -U：退化为 anchor + 验证
        }
        else
        {
            result = RgRunner.Run(o, query, literal: true, multiline: false, paths);
        }

        // ---- Legacy 编码防静默假阴性 ----
        // 无匹配 + 查询含非 ASCII + 未显式指定编码（--encoding auto 也触发）：自动尝试 GBK / UTF-16 补搜
        bool legacyEnabled = o.Encoding == null || o.Encoding == "auto";
        if (result.Code == 1 && !result.Truncated && legacyEnabled
            && !o.JsonMode && !o.RegexMode && !o.InvertMatch && ContainsNonAscii(query)
            && !query.Contains('\n') && query.Length <= LongQueryThreshold)
        {
            return LegacyProbe(o, query, paths);
        }
        if (result.Code == 1 && legacyEnabled && !o.JsonMode && ContainsNonAscii(query))
            PrintLegacyHint(); // 多行/正则/长查询无法可靠补搜：至少给出明确提示
        return result;
    }

    /// <summary>legacy 编码提示（不额外扫描，零成本防"静默假阴性"）。列表与实际实现一致，不宣传未实现的编码。</summary>
    static void PrintLegacyHint()
    {
        Console.Error.WriteLine(
            "[SafeRG] Warning: 无匹配。若项目中存在非 UTF-8 / legacy 编码文件（GBK、Shift-JIS、Windows-1252、无 BOM 的 UTF-16 等），结果可能不完整。可用 --encoding auto（自动尝试 gbk / utf-16le / utf-16be），或显式 --encoding gbk / shift-jis / windows-1252 / utf-16le / utf-16be 后重试。");
    }

    /// <summary>
    /// Legacy 编码补搜：依次用 GBK / UTF-16LE / UTF-16BE 重新搜索，**收集所有编码的真命中**（不短路——
    /// 目录可能同时含多种 legacy 编码文件）。命中文件需通过严格 UTF-8 校验（非 UTF-8 才算真命中，
    /// 过滤 GBK 解码 UTF-8 文件的假匹配）。补搜强制 --text：UTF-16 no BOM 文件原始字节含 NUL，
    /// 目录遍历时 rg 会按二进制跳过，--text 才能按指定编码解码搜索。
    /// </summary>
    static (int Code, bool Truncated) LegacyProbe(Options o, string query, string[] paths)
    {
        bool anyReal = false;
        foreach (string enc in new[] { "gbk", "utf-16le", "utf-16be" })
        {
            Options eo = o.Clone();
            eo.Encoding = enc;
            eo.TextMode = true; // 关键：UTF-16 no BOM 文件含 NUL，目录遍历需 --text 才不被当二进制跳过
            (List<string> files, _) = RgRunner.AnchorFiles(eo, query, paths); // -F -l 候选
            if (files.Count == 0) continue;
            var real = new List<string>();
            foreach (string f in files)
            {
                try { if (!TextIO.IsStrictUtf8(File.ReadAllBytes(f))) real.Add(f); }
                catch { /* 读取失败跳过 */ }
            }
            if (real.Count == 0) continue; // 全是合法 UTF-8 → 该编码解码为假匹配，忽略
            anyReal = true;
            Console.Error.WriteLine($"[SafeRG] Warning: {real.Count} 个文件为 {enc} 编码（非 UTF-8），已按该编码命中。");
            _ = RgRunner.Run(eo, query, literal: true, multiline: false, paths); // 输出该编码的匹配；继续检查下一编码
        }
        if (anyReal) return (0, false);
        PrintLegacyHint();
        return (1, false);
    }
}
