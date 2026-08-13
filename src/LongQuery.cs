using System.Text;

namespace SafeRG;

/// <summary>
/// Long Query Mode：查询超过 4000 字符时，不把整段文本塞进命令行。
///
/// 流程：
///   超长查询 → 提取 1~3 个高辨识度 anchor（非空、长度适中的行/token）
///   → rg -F -l 逐 anchor 找候选文件（取交集）
///   → SafeRG 亲自读取候选文件，规范化换行（\r\n → \n）后验证完整查询是否存在
///   → 输出真正匹配的位置（全文二次验证，杜绝 anchor-only / 前缀 / 后缀诱饵）。
///
/// 隐私：默认不在 stderr 输出查询/anchor 内容（--debug 时才会输出，且提示可能暴露查询片段）。
/// </summary>
public static class LongQuery
{
    public static (int Code, bool Truncated) Search(Options o, string query, string[] paths)
    {
        List<string> anchors = PickAnchors(query);
        if (anchors.Count == 0)
            throw new SafeRgException("无法从查询中提取有效的 anchor（没有 8~300 字符的非空行）。");

        Console.Error.WriteLine(o.Debug
            ? $"[SafeRG] Long query mode (debug: {anchors.Count} anchors: {string.Join(" | ", anchors.Select(a => a.Length > 60 ? a[..60] + "…" : a))})"
            : $"[SafeRG] Long query mode: {anchors.Count} anchors.");

        // ---- 第一步：anchor 找候选文件（交集 = 同时包含所有 anchor）----
        // 部分路径 IO/权限错误时**保留已获得的候选**（partial results），错误状态记入 hadErrors，
        // 绝不因一个不可读目录丢弃全部正确结果。
        var candidates = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        bool first = true;
        bool hadErrors = false;
        foreach (string anchor in anchors)
        {
            (List<string> files, bool err) = RgRunner.AnchorFiles(o, anchor, paths);
            hadErrors |= err;
            if (first) { candidates.UnionWith(files); first = false; }
            else candidates.IntersectWith(files);
            if (candidates.Count == 0) break;
        }
        if (candidates.Count == 0)
        {
            Console.Error.WriteLine($"[SafeRG] Long query mode: 0 处完整匹配。");
            return (hadErrors ? 2 : 1, false); // 无匹配；若发生过 IO 错误则保留 exit 2 错误状态
        }

        if (candidates.Count > Program.MaxCandidates)
            throw new SafeRgException($"候选文件过多（{candidates.Count} 个），anchor 区分度不足。请缩短查询或换用更独特的文本。");

        // ---- 第二步：逐文件验证完整查询（换行规范化后比较）----
        StringComparison cmp = o.CaseInsensitive == true ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

        int total = 0;
        bool capped = false;
        foreach (string file in candidates.OrderBy(f => f, StringComparer.Ordinal))
        {
            if (o.MaxResults > 0 && total >= o.MaxResults) { capped = true; break; }
            try
            {
                if (new FileInfo(file).Length > 64L * 1024 * 1024)
                {
                    Console.Error.WriteLine($"[SafeRG] 跳过超大文件（>64MB）: {file}");
                    continue;
                }
            }
            catch { /* 路径异常交给下面读取逻辑处理 */ }

            string content;
            try { content = TextIO.ReadFileText(file); }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[SafeRG] 跳过无法读取的文件 {file}: {ex.Message}");
                continue;
            }
            string norm = content.Replace("\r\n", "\n"); // CRLF → LF，与查询对齐

            int start = 0;
            while (true)
            {
                if (o.MaxResults > 0 && total >= o.MaxResults) { capped = true; break; }
                int idx = norm.IndexOf(query, start, cmp);
                if (idx < 0) break;
                total++;
                PrintMatch(o, file, norm, idx);
                start = idx + Math.Max(1, query.Length);
            }
        }

        if (capped)
        {
            if (o.JsonMode)
                Console.Error.WriteLine("[SafeRG] Results truncated."); // JSON 模式下截断信息由 summary 表达
            else
                Console.Error.WriteLine($"[SafeRG] Results truncated: showing first {o.MaxResults} matches.");
        }
        if (o.JsonMode)
        {
            // JSON 模式**始终**输出 summary（complete / truncated / had_errors / matches_shown）
            bool complete = !capped && !hadErrors;
            Console.Out.WriteLine(
                $"{{\"type\":\"saferg-summary\",\"complete\":{BoolJson(complete)},\"truncated\":{BoolJson(capped)},\"had_errors\":{BoolJson(hadErrors)},\"matches_shown\":{total}}}");
        }
        Console.Error.WriteLine($"[SafeRG] Long query mode: {total} 处完整匹配（{candidates.Count} 个候选文件）。");
        // exit 语义：有匹配且无错误 → 0；无匹配且无错误 → 1；发生过 IO/权限错误 → 2（保留已输出的结果）
        int code = total > 0 ? 0 : 1;
        if (hadErrors) code = 2;
        return (code, capped);
    }

    static string BoolJson(bool b) => b ? "true" : "false";

    /// <summary>输出匹配位置：文本模式 path:line:col:首行；JSON 模式结构化事件。列号按 UTF-8 字节（与 rg --column 一致）。</summary>
    static void PrintMatch(Options o, string file, string norm, int idx)
    {
        int lineStart = norm.LastIndexOf('\n', Math.Max(0, idx - 1)) + 1; // 匹配所在行起点
        int line = 1;
        for (int i = 0; i < lineStart; i++)
            if (norm[i] == '\n') line++;

        string prefix = norm[lineStart..idx];
        int colBytes = Encoding.UTF8.GetByteCount(prefix) + 1;

        int end = norm.IndexOf('\n', idx);
        string firstLine = end < 0 ? norm[idx..] : norm[idx..end];
        if (firstLine.Length > 300) firstLine = firstLine[..SafeCut(firstLine, 300)] + "…"; // 定位行截断（不切坏 surrogate）

        if (o.JsonMode)
        {
            Console.Out.WriteLine(
                $"{{\"type\":\"match\",\"path\":{JsonEscape(file)},\"line\":{line},\"column\":{colBytes},\"text\":{JsonEscape(firstLine)}}}");
        }
        else
        {
            Console.WriteLine($"{file}:{line}:{colBytes}:{firstLine}");
        }
    }

    static string JsonEscape(string s)
    {
        var sb = new StringBuilder(s.Length + 8);
        sb.Append('"');
        foreach (char ch in s)
        {
            switch (ch)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (ch < 0x20) sb.Append($"\\u{(int)ch:x4}");
                    else sb.Append(ch);
                    break;
            }
        }
        sb.Append('"');
        return sb.ToString();
    }

    /// <summary>
    /// 提取 anchor：多行查询取长度 8~300 的最长 3 个不同非空行；
    /// 单行查询取最长 token（8~300），否则取中间 100 字符窗口（窗口边界不切坏 surrogate pair）。
    /// </summary>
    static List<string> PickAnchors(string query)
    {
        var chosen = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        if (query.Contains('\n'))
        {
            foreach (string raw in query.Split('\n'))
            {
                string t = raw.Trim();
                if (t.Length < 8 || t.Length > 300) continue;
                if (t.All(char.IsWhiteSpace)) continue;
                if (seen.Add(t)) chosen.Add(t);
            }
            chosen = chosen.OrderByDescending(t => t.Length).Take(3).ToList();
        }
        else
        {
            string? token = query.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
                                .Where(t => t.Length >= 8 && t.Length <= 300)
                                .OrderByDescending(t => t.Length)
                                .FirstOrDefault();
            if (token != null) chosen.Add(token);
            else if (query.Length > 200) chosen.Add(MiddleWindow(query));
        }

        // 兜底：多行但每行都太短时，取整体中间窗口
        if (chosen.Count == 0 && query.Length > 200)
            chosen.Add(MiddleWindow(query));
        return chosen;
    }

    /// <summary>安全截断：若截断点落在 surrogate pair 中间则前移一位，保证结果合法。</summary>
    static int SafeCut(string s, int len)
    {
        if (len >= s.Length) return s.Length;
        if (len > 0 && char.IsHighSurrogate(s[len - 1]) && len < s.Length && char.IsLowSurrogate(s[len]))
            return len - 1;
        return len;
    }

    /// <summary>取中间 100 字符窗口，起点若落在 surrogate pair 中间则前移一位，保证窗口是合法 UTF-16。</summary>
    static string MiddleWindow(string s)
    {
        int start = Math.Max(0, s.Length / 2 - 50);
        if (start > 0 && char.IsLowSurrogate(s[start]) && char.IsHighSurrogate(s[start - 1]))
            start--;
        int len = Math.Min(100, s.Length - start);
        if (start + len < s.Length && char.IsHighSurrogate(s[start + len - 1]))
            len++;
        return s.Substring(start, len);
    }
}
