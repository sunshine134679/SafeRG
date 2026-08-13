using System.Text;

namespace SafeRG;

/// <summary>查询文本来源：位置参数 / --query / STDIN / 查询文件。</summary>
public static class QueryReader
{
    public static string Read(Options o)
    {
        string query;
        switch (o.Source)
        {
            case QuerySourceKind.Positional:
                // --query 与位置参数二选一（Parse 已校验互斥），缺省时统一为 ""（由 Main 统一拒绝空查询）
                query = o.PositionalQuery ?? o.QueryText ?? "";
                break;
            case QuerySourceKind.Stdin:
                query = TextIO.DecodeText(ReadStdinBytes());
                break;
            case QuerySourceKind.QueryFile:
                if (!File.Exists(o.QueryFile!))
                    throw new SafeRgException($"查询文件不存在: {o.QueryFile}");
                query = TextIO.DecodeText(File.ReadAllBytes(o.QueryFile!));
                break;
            default:
                throw new SafeRgException("内部错误: 未知查询来源。");
        }
        return Normalize(query);
    }

    static byte[] ReadStdinBytes()
    {
        using var stdin = Console.OpenStandardInput();
        using var ms = new MemoryStream();
        stdin.CopyTo(ms);
        return ms.ToArray();
    }

    /// <summary>换行统一为 \n（兼容 CRLF 输入），并去掉末尾换行（PowerShell 管道会自动附加一个）。</summary>
    static string Normalize(string s)
    {
        s = s.Replace("\r\n", "\n").Replace("\r", "\n");
        return s.TrimEnd('\n');
    }
}
