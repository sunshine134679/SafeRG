using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;

namespace SafeRG;

/// <summary>
/// ripgrep 启动器：所有搜索内容都通过 ProcessStartInfo.ArgumentList 作为独立参数传递。
/// 绝不拼接命令行字符串，绝不经过 cmd /c 或 Invoke-Expression，杜绝二次解释。
///
/// 结果识别策略（1.1.0）：
/// - 文本模式：rg 原生输出（--with-filename 保证恒为 path:line:col:text），
///   match 行按 path:line:col: 前缀计数（context 行是 path-N- 前缀，不计入结果上限）；
/// - JSON 模式（--json）：透传 rg --json 结构化事件，按 "type":"match" 精确计数
///   （多行匹配计 1 个、match/context/binary 明确区分），截断时附加 saferg-summary 事件。
/// </summary>
public static class RgRunner
{
    static string? _rgPath;
    static bool? _multilineSupported; // rg >= 13 才支持 -U 多行

    public static string? FindRg()
    {
        string? pathEnv = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(pathEnv)) return null;
        foreach (string raw in pathEnv.Split(';'))
        {
            string dir = raw.Trim().Trim('"');
            if (dir.Length == 0) continue;
            try
            {
                string cand = Path.Combine(dir, "rg.exe");
                if (File.Exists(cand)) return cand;
            }
            catch { /* 路径非法则跳过 */ }
        }
        return null;
    }

    public static void Init(string rgPath) => _rgPath = rgPath;

    /// <summary>rg 是否支持 -U 多行（13.0+）。懒加载并缓存，避免每次调用都启动子进程。</summary>
    public static bool HasMultilineSupport
    {
        get
        {
            if (_multilineSupported == null)
            {
                Version? v = GetRgVersion(_rgPath!);
                _multilineSupported = v != null && v >= new Version(13, 0);
            }
            return _multilineSupported.Value;
        }
    }

    static Version? GetRgVersion(string rgPath)
    {
        try
        {
            var psi = new ProcessStartInfo(rgPath)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            psi.ArgumentList.Add("--version");
            using var p = Process.Start(psi)!;
            string first = p.StandardOutput.ReadLine() ?? "";
            p.WaitForExit();
            Match m = Regex.Match(first, @"(\d+)\.(\d+)");
            if (m.Success) return new Version(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value));
        }
        catch { /* 版本探测失败时按不支持处理 */ }
        return null;
    }

    static ProcessStartInfo NewPsi()
    {
        var psi = new ProcessStartInfo(_rgPath!)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        // 子进程输出按 UTF-8 解码（Windows 默认会用控制台代码页，必须显式指定）
        psi.StandardOutputEncoding = new UTF8Encoding(false);
        psi.StandardErrorEncoding = new UTF8Encoding(false);
        return psi;
    }

    static void AddCommonSearchFlags(ProcessStartInfo psi, Options o, bool literal, bool multiline, string pattern, string[] paths)
    {
        if (o.JsonMode) psi.ArgumentList.Add("--json");
        else
        {
            psi.ArgumentList.Add("--color"); psi.ArgumentList.Add("never"); // AI 输出不要 ANSI 颜色
            psi.ArgumentList.Add("--no-heading");
            psi.ArgumentList.Add("--column");                               // path:line:col:text
            psi.ArgumentList.Add("--with-filename");                        // 单文件搜索也输出路径前缀（保证输出契约稳定）
        }
        psi.ArgumentList.Add("--path-separator"); psi.ArgumentList.Add("/"); // 输出路径分隔符统一为 /（rg 对目录搜索根会用平台分隔符拼接）
        if (literal || o.FixedStrings) psi.ArgumentList.Add("-F");          // 字面量（默认）；--regex 下的 -F 透传
        if (multiline) psi.ArgumentList.Add("-U");
        if (o.CaseInsensitive == true) psi.ArgumentList.Add("-i");
        else if (o.CaseInsensitive == false || !literal) psi.ArgumentList.Add("--case-sensitive");
        // 注：Regex 模式默认也区分大小写（关闭 rg 的 smart-case），行为可预测
        if (o.InvertMatch) psi.ArgumentList.Add("-v");
        if (o.Hidden) psi.ArgumentList.Add("--hidden");
        if (o.TextMode) psi.ArgumentList.Add("--text");
        if (o.Encoding is string enc && enc != "auto")
        {
            psi.ArgumentList.Add("--encoding");
            psi.ArgumentList.Add(enc);
        }
        foreach (string g in o.Globs) { psi.ArgumentList.Add("-g"); psi.ArgumentList.Add(g); }
        if (o.Context is int c) { psi.ArgumentList.Add("-C"); psi.ArgumentList.Add(c.ToString()); }
        if (o.MaxResults > 0)
        {
            // 提前终止优化：rg 每文件最多输出 N+1 个匹配，减少全仓扫描开销。
            // N+1 是关键：SafeRG 需要读到第 N+1 个 match 才能确认"还有更多"（truncated 检测），
            // 否则恰好 N 个匹配时无法区分 complete / truncated（--require-complete / JSON summary 依赖此）。
            // 第 N 个匹配的 after-context 由 rg 在 N+1 个匹配内完整输出，不会丢失。
            psi.ArgumentList.Add("-m");
            psi.ArgumentList.Add((o.MaxResults + 1).ToString());
        }
        psi.ArgumentList.Add("--"); // 之后全部按位置参数，防止查询以 - 开头被当作选项
        psi.ArgumentList.Add(pattern);
        foreach (string p in paths) psi.ArgumentList.Add(p);
    }

    /// <summary>
    /// 主搜索：流式转发 rg 输出，达到 --max-results 时截断并终止 rg。
    /// 返回 (rg exit code, 是否截断)；exit code 语义与 rg 一致（0=匹配，1=无匹配，2=错误）。
    /// </summary>
    public static (int Code, bool Truncated) Run(Options o, string pattern, bool literal, bool multiline, string[] paths)
    {
        var psi = NewPsi();
        AddCommonSearchFlags(psi, o, literal, multiline, pattern, paths);

        using var proc = new Process { StartInfo = psi };
        try { proc.Start(); }
        catch (Exception ex) { throw new SafeRgException($"无法启动 rg: {ex.Message}"); }

        // stderr 在后台线程经统一翻译器转发，防止管道填满导致 rg 阻塞；同时标记是否出现 rg 错误
        bool stderrHadErrors = false;
        var errTask = Task.Run(() => { stderrHadErrors = ForwardStderr(proc.StandardError); });

        bool truncated = false;
        int matchCount = 0;
        string? line;
        while ((line = proc.StandardOutput.ReadLine()) != null)
        {
            // 截断只在读到"第 N+1 个 match 行"时触发；context 行始终输出（属于已输出的 match）
            bool isMatch = IsMatchLine(line, o.JsonMode);
            if (isMatch && o.MaxResults > 0 && matchCount >= o.MaxResults) { truncated = true; break; }
            line = o.JsonMode ? line : ProcessOutputLine(line, o.MaxLineLength); // 超长行保护（仅文本模式）
            Console.Out.WriteLine(line);
            if (isMatch) matchCount++;
        }

        if (truncated)
        {
            if (o.JsonMode)
                Console.Error.WriteLine("[SafeRG] Results truncated."); // JSON 模式下截断信息由 summary 表达（stderr 辅助）
            else
                Console.Error.WriteLine($"[SafeRG] Results truncated: showing first {o.MaxResults} matches.");
            try { proc.Kill(entireProcessTree: true); } catch { /* 进程可能已退出 */ }
        }
        proc.WaitForExit();
        errTask.Wait();

        if (o.JsonMode)
        {
            // JSON 模式**始终**输出 summary（Agent 无需"没有 summary = 完整"的隐式约定）
            bool hadErrors = stderrHadErrors || (!truncated && proc.ExitCode == 2);
            bool complete = !truncated && !hadErrors;
            Console.Out.WriteLine(
                $"{{\"type\":\"saferg-summary\",\"complete\":{BoolJson(complete)},\"truncated\":{BoolJson(truncated)},\"had_errors\":{BoolJson(hadErrors)},\"matches_shown\":{matchCount}}}");
        }
        return (truncated ? 0 : proc.ExitCode, truncated);
    }

    static string BoolJson(bool b) => b ? "true" : "false";

    /// <summary>
    /// Long Query Mode 第一步：rg -F -l 查找包含 anchor 的文件（候选集）。
    /// 返回 (候选文件, 是否发生 IO/权限错误)：
    /// rg exit 2（部分路径不可读等）时**保留已获得的候选**（partial results），
    /// 错误状态由调用方综合到最终 exit code，绝不丢弃正确结果。
    /// </summary>
    public static (List<string> Files, bool HadErrors) AnchorFiles(Options o, string anchor, string[] paths)
    {
        var psi = NewPsi();
        psi.ArgumentList.Add("--color"); psi.ArgumentList.Add("never");
        psi.ArgumentList.Add("--path-separator"); psi.ArgumentList.Add("/");
        psi.ArgumentList.Add("-l");
        psi.ArgumentList.Add("-F");
        if (o.CaseInsensitive == true) psi.ArgumentList.Add("-i");
        if (o.Hidden) psi.ArgumentList.Add("--hidden");
        if (o.Encoding is string enc && enc != "auto")
        {
            psi.ArgumentList.Add("--encoding");
            psi.ArgumentList.Add(enc);
        }
        foreach (string g in o.Globs) { psi.ArgumentList.Add("-g"); psi.ArgumentList.Add(g); }
        psi.ArgumentList.Add("--");
        psi.ArgumentList.Add(anchor);
        foreach (string p in paths) psi.ArgumentList.Add(p);

        using var proc = new Process { StartInfo = psi };
        proc.Start();

        var files = new List<string>();
        string? line;
        while ((line = proc.StandardOutput.ReadLine()) != null)
            if (line.Length > 0) files.Add(line);
        ForwardStderr(proc.StandardError);
        proc.WaitForExit();

        // exit 1 = 无命中（空列表，正常）；exit 2 = 部分路径 IO/权限错误（候选保留，不中止）
        return (files, proc.ExitCode == 2);
    }

    // ---- 输出识别 ----

    /// <summary>文本模式 match 行：path:line:col:text（--with-filename 保证单文件也有路径）。
    /// 注意：不使用 RegexOptions.Compiled（NativeAOT 不支持 Compiled 正则）。</summary>
    static readonly Regex MatchLineRe = new(@"^(.+):(\d+):(\d+):");

    /// <summary>完整 match 行（含 text 段），用于超长行截断（注意：MatchLineRe 只有 3 个 group）。</summary>
    static readonly Regex MatchLineFullRe = new(@"^(.+):(\d+):(\d+):(.*)$");

    /// <summary>文本模式 context 行：path-line-text。</summary>
    static readonly Regex ContextLineRe = new(@"^(.+)-(\d+)-(.*)$");

    static bool IsMatchLine(string line, bool jsonMode)
    {
        if (jsonMode) return line.Contains("\"type\":\"match\"", StringComparison.Ordinal);
        return MatchLineRe.IsMatch(line);
    }

    /// <summary>
    /// 超长行保护（--max-line-length）：match 行以匹配位置为中心截取窗口（保留匹配本身），
    /// context 行从行首截断，均带明确省略标记。不改变 path:line:col 前缀。
    /// </summary>
    static string ProcessOutputLine(string line, int maxLen)
    {
        if (maxLen <= 0 || line.Length <= maxLen + 64) return line; // 快速路径
        Match m = MatchLineFullRe.Match(line);
        if (m.Success)
        {
            string text = m.Groups[4].Value;
            if (text.Length <= maxLen) return line;
            int col = int.Parse(m.Groups[3].Value);        // 匹配起始字节列（1-based）
            int matchChar = CharIndexAtByte(text, col - 1); // 字节列 → 字符索引
            int half = maxLen / 2;
            int start = Math.Max(0, matchChar - half);
            int end = Math.Min(text.Length, start + maxLen);
            if (end - start < maxLen) start = Math.Max(0, end - maxLen);
            string head = start > 0 ? $"[... {start} chars omitted ...] " : "";
            string tail = end < text.Length ? $" [... {text.Length - end} chars omitted ...]" : "";
            return $"{m.Groups[1].Value}:{m.Groups[2].Value}:{m.Groups[3].Value}:{head}{text[start..end]}{tail}";
        }
        Match c = ContextLineRe.Match(line);
        if (c.Success && c.Groups[3].Value.Length > maxLen)
        {
            return $"{c.Groups[1].Value}-{c.Groups[2].Value}-{c.Groups[3].Value[..maxLen]} [... {c.Groups[3].Value.Length - maxLen} chars omitted ...]";
        }
        return line;
    }

    /// <summary>UTF-8 字节列（rg --column 语义，1-based）→ 字符串字符索引。</summary>
    static int CharIndexAtByte(string s, int byteIndex)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(s);
        if (byteIndex >= bytes.Length) return s.Length;
        int acc = 0;
        for (int i = 0; i < s.Length; i++)
        {
            if (acc >= byteIndex) return i;
            acc += Encoding.UTF8.GetByteCount(s, i, 1);
        }
        return s.Length;
    }

    /// <summary>
    /// rg stderr 统一翻译器：
    /// - regex parse error 块净化为单行（不显示内部转义后的 pattern）；
    /// - --pcre2 建议替换为 SafeRG 明确说明（SafeRG 不支持 --pcre2）；
    /// - 其他 rg 错误统一 [SafeRG] 前缀（路径分隔符规范化为 /）；
    /// - 普通提示（binary file matches 等）原样转发。
    /// 返回是否出现过 rg 错误（供 JSON summary 的 had_errors 使用）。
    /// </summary>
    static bool ForwardStderr(StreamReader r)
    {
        bool inRegexError = false;
        bool sawError = false;
        string? line;
        while ((line = r.ReadLine()) != null)
        {
            if (inRegexError)
            {
                if (line.StartsWith("error:", StringComparison.Ordinal))
                {
                    Console.Error.WriteLine($"[SafeRG] Regex error: {line}");
                    sawError = true;
                    inRegexError = false;
                }
                // pattern 显示行与 ^ 定位行跳过（净化内部转义包装）
                continue;
            }
            if (line.Contains("regex parse error", StringComparison.Ordinal)) { inRegexError = true; sawError = true; continue; }
            if (line.Contains("--pcre2", StringComparison.Ordinal))
            {
                Console.Error.WriteLine("[SafeRG] 提示：该正则特性需要 PCRE2；SafeRG 不支持 --pcre2（需要时可改用原生 rg）。");
                continue;
            }
            if (line.StartsWith("rg: ", StringComparison.Ordinal))
            {
                sawError = true;
                Console.Error.WriteLine($"[SafeRG] rg: {line[4..].Replace('\\', '/')}");
                continue;
            }
            Console.Error.WriteLine(line);
        }
        return sawError;
    }
}
