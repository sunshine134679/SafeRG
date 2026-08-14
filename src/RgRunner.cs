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
    static bool? _sortSupported;      // rg >= 12 才支持 --sort（截断确定性依赖）

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

    /// <summary>rg 是否支持 --sort（12.0+）。截断结果确定性（1.3.2）依赖排序输出。</summary>
    public static bool HasSortSupport
    {
        get
        {
            if (_sortSupported == null)
            {
                Version? v = GetRgVersion(_rgPath!);
                _sortSupported = v != null && v >= new Version(12, 0);
            }
            return _sortSupported.Value;
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
            psi.ArgumentList.Add("-n");                                     // 显式行号（rg 单文件 + --no-column 时默认不显示行号）
            if (!o.NoColumn) psi.ArgumentList.Add("--column");              // path:line:col:text（默认；--no-column → path:line:text）
            psi.ArgumentList.Add("--with-filename");                        // 单文件搜索也输出路径前缀（保证输出契约稳定）
        }
        psi.ArgumentList.Add("--path-separator"); psi.ArgumentList.Add("/"); // 输出路径分隔符统一为 /（rg 对目录搜索根会用平台分隔符拼接）
        // 输出按路径确定性排序（rg >= 12）：截断结果的文件集与行数分布不再依赖
        // rg 并行遍历目录的随机顺序（BUG-R3-06/R4-06 根因；1.3.2）
        if (HasSortSupport) { psi.ArgumentList.Add("--sort"); psi.ArgumentList.Add("path"); }
        if (literal || o.FixedStrings) psi.ArgumentList.Add("-F");          // 字面量（默认）；--regex 下的 -F 透传
        if (multiline) psi.ArgumentList.Add("-U");
        if (o.CaseInsensitive == true) psi.ArgumentList.Add("-i");
        else if (o.CaseInsensitive == false || (!literal && o.SmartCase != true)) psi.ArgumentList.Add("--case-sensitive");
        // 注：Regex 模式默认区分大小写（关闭 rg 的 smart-case）；-S/--smart-case 显式时透传给 rg 处理
        if (o.SmartCase == true) psi.ArgumentList.Add("-S");
        if (o.InvertMatch) psi.ArgumentList.Add("-v");
        if (o.Hidden) psi.ArgumentList.Add("--hidden");
        if (o.NoIgnore) psi.ArgumentList.Add("--no-ignore");
        if (o.TextMode) psi.ArgumentList.Add("--text");
        if (o.FilesWithMatches) psi.ArgumentList.Add("-l");
        if (o.OnlyMatching) psi.ArgumentList.Add("-o");
        foreach (string t in o.Types) { psi.ArgumentList.Add("-t"); psi.ArgumentList.Add(t); }
        foreach (string ta in o.TypeAdds) { psi.ArgumentList.Add("--type-add"); psi.ArgumentList.Add(ta); }
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

        // text 模式 + 有限结果：截断保全路径（rg 并行遍历目录使输出顺序不稳定 ->
        // 流式硬截断会让"哪些文件被截掉"随机，Agent 可能误判缺失文件无匹配；
        // 1.3.1 起缓冲截断，保证结果包含全部匹配文件，文件集稳定）
        if (!o.JsonMode && !o.FilesWithMatches && o.MaxResults > 0)
        {
            var safe = RunTruncationSafe(proc, o);
            errTask.Wait();
            return safe;
        }

        bool truncated = false;
        int matchCount = 0;
        string? line;
        while ((line = proc.StandardOutput.ReadLine()) != null)
        {
            // 截断只在读到"第 N+1 个 match 行"时触发；context 行始终输出（属于已输出的 match）
            // -l 模式每行 = 一个文件（rg 输出路径列表，无 line:col 结构）
            bool isMatch = o.FilesWithMatches ? true : IsMatchLine(line, o.JsonMode, o.NoColumn);
            if (isMatch && o.MaxResults > 0 && matchCount >= o.MaxResults) { truncated = true; break; }
            line = o.JsonMode ? line : ProcessOutputLine(line, o.MaxLineLength, o.NoColumn); // 超长行保护（仅文本模式）
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
    /// text 模式 + --max-results 的截断保全路径：
    /// 缓冲前 N 个 match 行；溢出后继续消费流（-m N+1 保证每文件最多 N+1 行，消费有界），
    /// 为每个"新出现的文件"保留首行；流结束时用"行数 &gt; 1 的文件"的最后一行腾位，
    /// 保证截断结果包含所有匹配文件（文件集稳定，不随 rg 遍历顺序变化）。
    /// </summary>
    static (int Code, bool Truncated) RunTruncationSafe(Process proc, Options o)
    {
        var buffer = new List<string>();
        var fileCounts = new Dictionary<string, int>(StringComparer.Ordinal);
        var pendingFiles = new HashSet<string>(StringComparer.Ordinal);
        var pendingFirst = new List<(string Line, string File)>();
        int matchCount = 0;
        bool truncated = false;

        string? line;
        while ((line = proc.StandardOutput.ReadLine()) != null)
        {
            if (!IsMatchLine(line, jsonMode: false, o.NoColumn))
            {
                if (!truncated) buffer.Add(line); // 溢出后的 context 行随其 match 丢弃
                continue;
            }
            string file = ExtractFile(line, o.NoColumn);
            if (matchCount >= o.MaxResults)
            {
                truncated = true;
                if (!fileCounts.ContainsKey(file) && pendingFiles.Add(file))
                    pendingFirst.Add((line, file)); // 新文件首行：保全
                continue;
            }
            matchCount++;
            fileCounts[file] = fileCounts.TryGetValue(file, out int c) ? c + 1 : 1;
            buffer.Add(line);
        }

        // 为每个新文件首行腾位：移除"行数 > 1 的文件"的最后一个 match 行（及跟随的 context），
        // 保持其余行原顺序；每文件只剩 1 行时放弃插入（维持 ≤ N 行输出契约）
        foreach ((string pLine, string pFile) in pendingFirst)
        {
            int victim = -1;
            for (int i = buffer.Count - 1; i >= 0; i--)
            {
                if (!IsMatchLine(buffer[i], jsonMode: false, o.NoColumn)) continue;
                if (fileCounts[ExtractFile(buffer[i], o.NoColumn)] > 1) { victim = i; break; }
            }
            if (victim < 0) break;
            fileCounts[ExtractFile(buffer[victim], o.NoColumn)]--;
            int end = victim + 1;
            while (end < buffer.Count && !IsMatchLine(buffer[end], jsonMode: false, o.NoColumn)) end++;
            buffer.RemoveRange(victim, end - victim);
            buffer.Add(pLine);
            fileCounts[pFile] = 1;
        }

        foreach (string b in buffer) Console.Out.WriteLine(b);
        if (truncated)
            Console.Error.WriteLine($"[SafeRG] Results truncated: showing first {o.MaxResults} matches.");
        proc.WaitForExit();
        return (truncated ? 0 : proc.ExitCode, truncated);
    }

    /// <summary>从 match 行提取文件路径（path:line:col:text 或 --no-column 的 path:line:text）。</summary>
    static string ExtractFile(string line, bool noColumn)
    {
        int colon = line.LastIndexOf(':');            // text 段前的冒号
        int prev = line.LastIndexOf(':', colon - 1);  // line 段前的冒号
        int start = noColumn ? prev : line.LastIndexOf(':', prev - 1);
        return line[..start];
    }

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
        if (o.SmartCase == true) psi.ArgumentList.Add("-S");
        if (o.Hidden) psi.ArgumentList.Add("--hidden");
        if (o.NoIgnore) psi.ArgumentList.Add("--no-ignore");
        foreach (string t in o.Types) { psi.ArgumentList.Add("-t"); psi.ArgumentList.Add(t); }
        foreach (string ta in o.TypeAdds) { psi.ArgumentList.Add("--type-add"); psi.ArgumentList.Add(ta); }
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

    /// <summary>
    /// rg --files 文件枚举（应用与搜索相同的过滤：hidden/no-ignore/type/type-add/glob），
    /// 用于 legacy 风险探测（DetectLegacyRisk）。
    /// </summary>
    public static List<string> ListFiles(Options o, string[] paths)
    {
        var psi = NewPsi();
        psi.ArgumentList.Add("--color"); psi.ArgumentList.Add("never");
        psi.ArgumentList.Add("--path-separator"); psi.ArgumentList.Add("/");
        psi.ArgumentList.Add("--files");
        if (o.Hidden) psi.ArgumentList.Add("--hidden");
        if (o.NoIgnore) psi.ArgumentList.Add("--no-ignore");
        foreach (string t in o.Types) { psi.ArgumentList.Add("-t"); psi.ArgumentList.Add(t); }
        foreach (string ta in o.TypeAdds) { psi.ArgumentList.Add("--type-add"); psi.ArgumentList.Add(ta); }
        foreach (string g in o.Globs) { psi.ArgumentList.Add("-g"); psi.ArgumentList.Add(g); }
        psi.ArgumentList.Add("--");
        foreach (string p in paths) psi.ArgumentList.Add(p);

        using var proc = new Process { StartInfo = psi };
        proc.Start();

        var files = new List<string>();
        string? line;
        while ((line = proc.StandardOutput.ReadLine()) != null)
            if (line.Length > 0) files.Add(line);
        ForwardStderr(proc.StandardError);
        proc.WaitForExit();
        return files;
    }

    // ---- 输出识别 ----

    /// <summary>文本模式 match 行完整解析（含 text 段），用于超长行截断。</summary>
    static readonly Regex MatchLineFullRe = new(@"^(.+):(\d+):(\d+):(.*)$");
    static readonly Regex MatchLineNoColFullRe = new(@"^(.+):(\d+):(.*)$");

    /// <summary>文本模式 context 行：path-line-text。</summary>
    static readonly Regex ContextLineRe = new(@"^(.+)-(\d+)-(.*)$");

    /// <summary>
    /// 文本模式 match 行识别（手写，无正则开销——Fast Path 核心）：
    /// 结构 path:line:col:text（默认）或 path:line:text（--no-column），
    /// 从右往左验证倒数第二/第三个冒号段是数字（与原正则 ^(.+):(\d+):(\d+): 语义等价）。
    /// </summary>
    static bool IsMatchLine(string line, bool jsonMode, bool noColumn)
    {
        if (jsonMode) return line.Contains("\"type\":\"match\"", StringComparison.Ordinal);
        int colon = line.LastIndexOf(':');
        if (colon < 0) return false;
        int prev = line.LastIndexOf(':', colon - 1);
        if (prev < 0) return false;
        if (!IsDigits(line, prev + 1, colon - prev - 1)) return false;
        if (!noColumn)
        {
            int prev2 = line.LastIndexOf(':', prev - 1);
            if (prev2 < 0) return false;
            if (!IsDigits(line, prev2 + 1, prev - prev2 - 1)) return false;
        }
        return true;
    }

    static bool IsDigits(string s, int start, int len)
    {
        if (len <= 0) return false;
        for (int i = start; i < start + len; i++)
            if (s[i] < '0' || s[i] > '9') return false;
        return true;
    }

    /// <summary>
    /// 超长行保护（--max-line-length）：match 行以匹配位置为中心截取窗口（保留匹配本身），
    /// --no-column 时无列信息 → 行首截断；context 行行首截断；均带明确省略标记。
    /// 不改变 path:line[:col] 前缀。
    /// </summary>
    static string ProcessOutputLine(string line, int maxLen, bool noColumn)
    {
        if (maxLen <= 0 || line.Length <= maxLen + 64) return line; // 快速路径
        Match m = noColumn ? MatchLineNoColFullRe.Match(line) : MatchLineFullRe.Match(line);
        if (m.Success)
        {
            string text = noColumn ? m.Groups[3].Value : m.Groups[4].Value;
            if (text.Length <= maxLen) return line;
            if (noColumn)
            {
                return $"{m.Groups[1].Value}:{m.Groups[2].Value}:{text[..maxLen]} [... {text.Length - maxLen} chars omitted ...]";
            }
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
