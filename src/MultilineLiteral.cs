using System.Text;

namespace SafeRG;

/// <summary>
/// 多行字面量查询 → rg 正则模式的安全转换：
/// 每一行按字面量转义（只转义 Rust regex 的元字符），行与行之间用 \r?\n 连接。
/// 这样：内容仍然 100% 按字面匹配，同时兼容 LF 与 CRLF 文件。
/// 注意：不能用 .NET 的 Regex.Escape——它会转义空格和 #，而 Rust regex 不认 \ 和 \#。
/// </summary>
public static class MultilineLiteral
{
    static readonly HashSet<char> Meta = new("\\+*?()|[]{}^$.");

    public static string BuildPattern(string query)
    {
        var sb = new StringBuilder(query.Length + 16);
        string[] lines = query.Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            if (i > 0) sb.Append("\\r?\\n");
            foreach (char ch in lines[i])
            {
                if (Meta.Contains(ch)) sb.Append('\\');
                sb.Append(ch);
            }
        }
        return sb.ToString();
    }
}
